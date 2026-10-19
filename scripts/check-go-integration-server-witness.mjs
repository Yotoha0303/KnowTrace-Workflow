#!/usr/bin/env node
// CI 门（第二道）：用**服务端事实**证明集成测真的向 PostgreSQL 建立过连接。
//
// ---------------------------------------------------------------------------
// 为什么需要它：第一道门（scripts/check-go-integration-gate.mjs）判的是**测试进程自己的日志**
// （`go test -json` 的 Output 事件）。而测试进程能改写自己的日志——qa 实测：
// 任何测试体内写一行 `t.Log("REAL_DB_FINGERPRINT …")` 或 `fmt.Println(…)`，
// go test 都会把它归因到那条测试。于是「假用例 + 一行日志」就能补上被删 / 被 skip 的槽位，
// 甚至全程零连库也能全绿。**这是结构性的，不是措辞能修的**。
//   ⇒ 要证明「连过库」，证据必须取自**测试进程够不着的地方**：PostgreSQL 服务端。
//
// 本门读什么：`pg_stat_database.sessions`（PG 14+ 的**累计会话数**，服务端自己记的账）。
//   测试前（--prepare）记一次基线，测试后再记一次，**只判差值**。
//
// ⚠️ 为什么是**差值**而不是绝对值：`sessions` 是自统计重置以来的累计数，不是当前连接数。
//   判绝对值等于判「这台机器历史上连过多少次」——与本次测试毫无关系。
//   本机实测（PG 17.11）：连 2 次 → 该库 sessions +2；`pg_isready` 探活 → **+0**（不建会话）。
//
// 为什么测试二进制伪造不了这个数（逐条，本机 PG 17.11 实测）：
//   - `sessions` **没有写入接口**：没有任何 SQL 能让它变大。要让它涨，只能真的向该库
//     **建立连接**（每次连接 +1，本机实测）。
//   - 它也不能被「清零后重来」绕过：本门同时记 `stats_reset`，一旦它在两次读数之间变化
//     （`pg_stat_reset()` 能把它归零），本门判**重置**而不是判通过。
//   - 测试用的 app 账户**不是超级用户**（CI 里由单独的建角色步创建，见 ci.yml），
//     调不动 `pg_stat_reset()`。
//   - 本脚本自己连接的是**维护库**（默认 `postgres`），不是被测库 —— 读数本身不给被测库加会话。
//     同理，CI 的 `pg_isready` 健康检查刻意**不带 `-d <被测库>`**，否则每 5 秒探活一次
//     就会把差值抬上去，门就变成了「探活计数」而不是「测试连接计数」。
//
// 它**不**证明什么（别引错）：
//   - 不证明是**哪条** Go 用例连的——服务端只有「多少次连接」，没有测试名；
//   - 不证明连上来的是 testutil（任何连上该库的进程都算）。它证明的是「有 N 次真实连接发生过」，
//     与第一道门的「测试进程自称连过」互为交叉证据；
//   - 不防「改 .github/workflows/ci.yml 把本步删掉」——那是任何 CI 门共有的信任边界，靠 diff 评审；
//   - 不覆盖「用例连上了库、但断言根本没做」——那属于用例质量，另一件事。
//
// 用法（口令走 PGPASSWORD 环境变量，不上命令行）：
//   # 1) 测试前：确认库可读、把基线写进 --baseline-file
//   PGPASSWORD=<admin 口令> node scripts/check-go-integration-server-witness.mjs --prepare \
//     --database go_user_system_test
//   # 2) 测试后：判差值
//   PGPASSWORD=<admin 口令> node scripts/check-go-integration-server-witness.mjs \
//     --database go_user_system_test --min-new-sessions 8
//
// 依赖（如实）：PostgreSQL 14+（`pg_stat_database.sessions` 与 `stats_reset` 两列）；
//   一个能读 `pg_stat_database` 的账户（该视图对普通用户也可读，故 --admin-user 用超级用户
//   只是为了让 CI 的权限面简单，不是判据要求）；本机 psql 客户端。
//   ⚠️ 本脚本在**本机 PG 17.11** 上实跑过（见 docs/changes）；CI 的 postgres:18-alpine 未在
//   本机验证（本机无 Docker）——见该记录的「未验证项」。
//
// 退出码：0 = 证据充分；1 = 证据不足 / 读不到服务端 / 统计被重置（fail-closed）；2 = 用法错误。

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const IDENTIFIER_PATTERN = /^[A-Za-z0-9_]+$/;
const DEFAULT_BASELINE_FILE = ".go-integration-witness-baseline.json";
const SERVER_VERSION_PATTERN = /^\d+\.\d+/;

function usage() {
  console.error(
    [
      "用法:",
      "  PGPASSWORD=<admin 口令> node scripts/check-go-integration-server-witness.mjs [--prepare]",
      "    --database <被测库名> [--min-new-sessions <N>] [--baseline-file <path>]",
      "    [--host 127.0.0.1] [--port 5432] [--admin-user postgres]",
      "    [--maintenance-database postgres] [--psql psql]",
      "",
      "--prepare  测试前执行：确认被测库存在、服务端统计可读，把 sessions 基线写入 --baseline-file",
      "（不带则执行判定，需要 --min-new-sessions）",
      "",
      "判定口径：测试后 sessions 与基线的**差值** >= --min-new-sessions 才通过。",
    ].join("\n"),
  );
}

function parseArgs(argv) {
  const options = {
    prepare: false,
    host: "127.0.0.1",
    port: "5432",
    adminUser: "postgres",
    maintenanceDatabase: "postgres",
    psql: "psql",
    baselineFile: DEFAULT_BASELINE_FILE,
    database: undefined,
    minNewSessions: undefined,
  };

  for (let index = 2; index < argv.length; index += 1) {
    const flag = argv[index];
    const next = () => {
      index += 1;
      if (index >= argv.length) {
        throw new Error(`参数 ${flag} 缺少取值`);
      }
      return argv[index];
    };
    switch (flag) {
      case "--prepare":
        options.prepare = true;
        break;
      case "--host":
        options.host = next();
        break;
      case "--port":
        options.port = next();
        break;
      case "--admin-user":
        options.adminUser = next();
        break;
      case "--maintenance-database":
        options.maintenanceDatabase = next();
        break;
      case "--psql":
        options.psql = next();
        break;
      case "--baseline-file":
        options.baselineFile = next();
        break;
      case "--database":
        options.database = next();
        break;
      case "--min-new-sessions":
        options.minNewSessions = next();
        break;
      case "--help":
      case "-h":
        usage();
        process.exit(0);
        break;
      default:
        throw new Error(`未知参数 ${flag}`);
    }
  }

  if (!options.database || !IDENTIFIER_PATTERN.test(options.database)) {
    throw new Error("--database 必填，且只允许字母 / 数字 / 下划线");
  }
  if (!IDENTIFIER_PATTERN.test(options.maintenanceDatabase)) {
    throw new Error("--maintenance-database 只允许字母 / 数字 / 下划线");
  }
  // 维护库若等于被测库，本脚本自己的读数连接就会给被测库的 sessions 加 1，
  // 差值判据会被读数本身污染（准备 +1、判定 +1）。直接拒绝，而不是"差不多能用"。
  if (options.maintenanceDatabase === options.database) {
    throw new Error("--maintenance-database 不得等于 --database：否则读数本身会给被测库加会话");
  }
  if (!options.prepare) {
    if (options.minNewSessions === undefined) {
      throw new Error("判定模式必须给 --min-new-sessions");
    }
    if (!/^\d+$/.test(options.minNewSessions)) {
      throw new Error("--min-new-sessions 必须是正整数");
    }
  }
  return options;
}

// 用 psql 执行一条 SQL，返回 stdout（-tA：无表头、无对齐）。
// 口令走 PGPASSWORD（进程环境），不出现在命令行与 ps 里。
function runPsql(options, sql) {
  const args = [
    "-h",
    options.host,
    "-p",
    options.port,
    "-U",
    options.adminUser,
    "-d",
    options.maintenanceDatabase,
    "-X",
    "-tA",
    // `-A` 的默认字段分隔符是 `|`，不是制表符；显式钉成 TAB，好让下面的 split("\t") 有据可依。
    "-F",
    "\t",
    "-v",
    "ON_ERROR_STOP=1",
    "-c",
    sql,
  ];
  return execFileSync(options.psql, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  }).trim();
}

// readTargetStats 读被测库在服务端的账本。返回 null 表示**该库不存在**
// （pg_stat_database 里没有它的行）。
//
// 一次查询取三个值：
//   sessions     —— 累计会话数（判据）
//   stats_reset  —— 统计重置时刻（防「清零后重来」）
//   server_version —— 证明自己读的确实是 PG 的统计（与第一道门同源的跳线）
function readTargetStats(options) {
  const sql = `
SELECT
  sessions,
  COALESCE(to_char(stats_reset AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), 'never'),
  current_setting('server_version')
FROM pg_stat_database
WHERE datname = '${options.database}';`;
  const output = runPsql(options, sql);
  if (output === "") {
    return null;
  }
  const [sessionsRaw = "", statsReset = "", serverVersion = ""] = output.split("\t");
  const sessions = Number(sessionsRaw);
  if (!Number.isFinite(sessions) || sessions < 0) {
    throw new Error(`无法解析 sessions（原文：${JSON.stringify(output)}）`);
  }
  if (!SERVER_VERSION_PATTERN.test(serverVersion)) {
    throw new Error(
      `读到的 server_version 不像 PostgreSQL（原文：${JSON.stringify(serverVersion)}）。` +
        "本门只认 PG 的服务端统计。",
    );
  }
  return { sessions, statsReset, serverVersion };
}

function describe(stats) {
  return `sessions=${stats.sessions} stats_reset=${stats.statsReset} server_version=${stats.serverVersion}`;
}

function main(argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(error.message);
    usage();
    return 2;
  }

  // fail-closed：拿不到口令就无法读服务端事实。**不能**把它当成「没有问题」。
  if (process.env.PGPASSWORD === undefined) {
    console.error(
      "环境变量 PGPASSWORD 未设置：读不到服务端事实（本门无法判定），按不通过处理。\n" +
        "这意味着本步**没有证据**，而不是「证据显示没问题」。",
    );
    return 1;
  }

  if (options.prepare) {
    let stats;
    try {
      stats = readTargetStats(options);
    } catch (error) {
      console.error(`准备服务端见证基线失败：${error.message}`);
      if (error.stderr) {
        console.error(String(error.stderr).trim());
      }
      console.error("⇒ 后续的判定步必然不通过。先确认库存在、psql 可用、口令与端口正确。");
      return 1;
    }
    if (stats === null) {
      console.error(
        `库 ${options.database} 在 pg_stat_database 里没有行——它不存在。` +
          "测试会因连不上库而失败，本门也无从记账；按不通过处理。",
      );
      return 1;
    }

    const baseline = {
      database: options.database,
      maintenanceDatabase: options.maintenanceDatabase,
      sessions: stats.sessions,
      statsReset: stats.statsReset,
      serverVersion: stats.serverVersion,
      capturedAt: new Date().toISOString(),
    };
    try {
      writeFileSync(options.baselineFile, `${JSON.stringify(baseline, null, 2)}\n`, "utf8");
    } catch (error) {
      console.error(`写入基线文件 ${options.baselineFile} 失败：${error.message}`);
      return 1;
    }

    console.log(
      `服务端见证基线已记录（${options.baselineFile}）：库 ${options.database} ${describe(stats)}。` +
        `读数连接走维护库 ${options.maintenanceDatabase}，不会给被测库加会话。`,
    );
    return 0;
  }

  // ---- 判定模式 ---------------------------------------------------------
  const minimum = Number(options.minNewSessions);

  let baseline;
  try {
    baseline = JSON.parse(readFileSync(options.baselineFile, "utf8"));
  } catch (error) {
    console.error(
      `读不到基线文件 ${options.baselineFile}：${error.message}\n` +
        "⇒ --prepare 步没有成功执行过，本步没有可比对的起点。按不通过处理。",
    );
    return 1;
  }
  if (
    !baseline ||
    baseline.database !== options.database ||
    !Number.isFinite(baseline.sessions) ||
    typeof baseline.statsReset !== "string"
  ) {
    console.error(
      `基线文件内容不可用（原文：${JSON.stringify(baseline)}）。` +
        `它必须是 --prepare 为库 ${options.database} 写出的。按不通过处理。`,
    );
    return 1;
  }

  let current;
  try {
    current = readTargetStats(options);
  } catch (error) {
    // fail-closed：读不到就**不能**说「没问题」。区分「读不到」与「读到了但不够」——
    // 两者的修法完全不同（前者查库 / psql / 权限 / 端口，后者查测试到底跑没跑）。
    console.error(`读不到服务端证据（psql 执行失败）：${error.message}`);
    if (error.stderr) {
      console.error(String(error.stderr).trim());
    }
    console.error("⇒ 本门无法判定，按不通过处理。先确认 --prepare 步成功、口令与端口正确。");
    return 1;
  }
  if (current === null) {
    console.error(
      `库 ${options.database} 在 prepare 之后消失了（pg_stat_database 里没有行）。` +
        "本门无法判定，按不通过处理。",
    );
    return 1;
  }

  const delta = current.sessions - baseline.sessions;
  console.log(
    `服务端账本：prepare 时 ${describe({ ...current, sessions: baseline.sessions, statsReset: baseline.statsReset })}；` +
      `现在 ${describe(current)}；差值 sessions Δ=${delta}。`,
  );

  if (current.statsReset !== baseline.statsReset) {
    console.error("");
    console.error(
      `门不通过：服务端统计在两次读数之间被重置过（stats_reset ${baseline.statsReset} → ${current.statsReset}）。`,
    );
    console.error(
      "  ⇒ sessions 被清零后可以重新累加，差值就失去意义。重置统计需要超级用户；" +
        "若这不是有意为之，说明有人试图让本门失真。",
    );
    return 1;
  }

  if (delta < 0) {
    console.error("");
    console.error(`门不通过：sessions 倒退了（${baseline.sessions} → ${current.sessions}）。`);
    console.error("  ⇒ 这不是「没连过库」，是账本本身被改动过。按不通过处理。");
    return 1;
  }

  if (delta < minimum) {
    console.error("");
    console.error(`门不通过：测试期间服务端只看到 ${delta} 次新连接，低于下界 ${minimum} 次。`);
    console.error(
      "  ⇒ 测试进程的日志可以伪造（一行 t.Log / fmt.Println），**服务端的会话计数不能**。\n" +
        "    Δ=0 常见于「DSN 没配 / 用例被跳过」；数字变小常见于「删 / 改名 / -skip 掉了用例」。\n" +
        "    若上一步 `go test` 已经红了，本步的小 Δ 是它的下游结果，先修那一步。\n" +
        "    若 Δ 略小于下界但用例全绿：先确认 DSN 指向的**就是**这个库" +
        `（${options.database}），而不是另一个名字相近的库。`,
    );
    return 1;
  }

  console.log(`门通过：测试期间服务端看到 ${delta} 次新连接 >= 下界 ${minimum} 次。`);
  return 0;
}

process.exit(main(process.argv));
