#!/usr/bin/env node
// CI 门（第二道）：用**服务端事实**证明集成测真的向 MySQL 建立过连接。
//
// ---------------------------------------------------------------------------
// 为什么需要它：第一道门（scripts/check-go-integration-gate.mjs）判的是**测试进程自己的日志**
// （`go test -json` 的 Output 事件）。而测试进程能改写自己的日志——qa 实测：
// 任何测试体内写一行 `t.Log("REAL_DB_FINGERPRINT …")` 或 `fmt.Println(…)`，
// go test 都会把它归因到那条测试。于是「假用例 + 一行日志」就能补上被删 / 被 skip 的槽位，
// 甚至全程零连库也能全绿。**这是结构性的，不是措辞能修的**。
//   ⇒ 要证明「连过库」，证据必须取自**测试进程够不着的地方**：MySQL 服务端。
//
// 本门读什么：`mysql.general_log`（MySQL 自己的连接与语句日志）。
//   统计「以**测试账户**连上**测试库**、并在该连接上执行过 `testutil.OpenMySQL` 的真实启动序列
//   （`GET_LOCK` / `DATABASE()` / `VERSION()`）的**不同线程（连接）数**」。
//
// 为什么测试二进制伪造不了这个数：
//   - 测试用的是 app 账户（go_user_system）。本机实测：该账户对
//     performance_schema.events_statements_summary_by_digest 的 SELECT 被拒（ERROR 1142），
//     对 mysql.general_log 同样没有写权限——**它连读都读不到，更写不了**。
//   - 唯一能写 general_log 的是 root；而 root 的连接不满足本门的过滤条件
//     （`user_host` 必须以被测账户名开头）。
//   - 因此「连接数」是服务端记的账，不是测试自报的账。
//
// 它**不**证明什么（别引错）：
//   - 不证明是**哪条** Go 用例连的——服务端只看到连接与语句，没有测试名；
//   - 不防「改 .github/workflows/ci.yml 把本步删掉」——那是任何 CI 门共有的信任边界，靠 diff 评审；
//   - 不覆盖「用例连上了库、但断言根本没做」——那属于用例质量，另一件事。
//
// 前置（测试前、root）：`--prepare` 打开 TABLE 输出、清空、再打开日志。
//   ⚠️ 顺序不可换：先 TRUNCATE 再 ON，否则清理语句自己会被记进去；
//      且 `log_output` 必须含 TABLE（MySQL 默认是 FILE），否则表是空的、本门会误判为「没连过」。
//
// 用法：
//   # 1) 测试前（root 口令走 MYSQL_PWD，不上命令行）
//   MYSQL_PWD=<root 口令> node scripts/check-go-integration-server-witness.mjs --prepare \
//     --database go_user_system_test --user go_user_system
//   # 2) 测试后
//   MYSQL_PWD=<root 口令> node scripts/check-go-integration-server-witness.mjs \
//     --database go_user_system_test --user go_user_system --min-connections 8
//
// 依赖（如实）：MySQL 5.7+ 的 mysql.general_log 表结构（本机在 8.4.8 实测；CI 是 8.0，未在 CI 上复跑）；
//   需要 root（或 SYSTEM_VARIABLES_ADMIN + 对 mysql.general_log 的 SELECT）。
//
// 退出码：0 = 证据充分；1 = 证据不足 / 读不到服务端（fail-closed）；2 = 用法错误。

import { execFileSync } from "node:child_process";

const IDENTIFIER_PATTERN = /^[A-Za-z0-9_]+$/;

function usage() {
  console.error(
    [
      "用法:",
      "  MYSQL_PWD=<root 口令> node scripts/check-go-integration-server-witness.mjs [--prepare]",
      "    --database <测试库名> --user <测试账户> [--min-connections <N>]",
      "    [--host 127.0.0.1] [--port 3306] [--root-user root] [--mysql mysql]",
      "",
      "--prepare  测试前执行：log_output 含 TABLE、清空 mysql.general_log、打开 general_log",
      "（不带则执行判定，需要 --min-connections）",
    ].join("\n"),
  );
}

function parseArgs(argv) {
  const options = {
    prepare: false,
    host: "127.0.0.1",
    port: "3306",
    rootUser: "root",
    mysql: "mysql",
    database: undefined,
    user: undefined,
    minConnections: undefined,
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
      case "--root-user":
        options.rootUser = next();
        break;
      case "--mysql":
        options.mysql = next();
        break;
      case "--database":
        options.database = next();
        break;
      case "--user":
        options.user = next();
        break;
      case "--min-connections":
        options.minConnections = next();
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
  if (!options.user || !IDENTIFIER_PATTERN.test(options.user)) {
    throw new Error("--user 必填，且只允许字母 / 数字 / 下划线");
  }
  if (!options.prepare) {
    if (options.minConnections === undefined) {
      throw new Error("判定模式必须给 --min-connections");
    }
    if (!/^\d+$/.test(options.minConnections)) {
      throw new Error("--min-connections 必须是正整数");
    }
  }
  return options;
}

// 用 mysql CLI 执行一条 SQL，返回 stdout。失败时抛出带 stderr 的错误。
// 口令走 MYSQL_PWD（进程环境），不出现在命令行与 ps 里——与 .github/workflows/ci.yml 的 e2e 步同形。
function runMysql(options, sql) {
  const args = [
    "-h",
    options.host,
    "-P",
    options.port,
    "-u",
    options.rootUser,
    "-N",
    "-B",
    "-e",
    sql,
  ];
  return execFileSync(options.mysql, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  }).trim();
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

  // fail-closed：拿不到 root 口令就无法读服务端事实。**不能**把它当成「没有问题」。
  if (process.env.MYSQL_PWD === undefined) {
    console.error(
      "环境变量 MYSQL_PWD 未设置：读不到服务端事实（本门无法判定），按不通过处理。\n" +
        "这意味着本步**没有证据**，而不是「证据显示没问题」。",
    );
    return 1;
  }

  if (options.prepare) {
    const sql = [
      "SET GLOBAL log_output='TABLE';",
      "SET GLOBAL general_log=OFF;",
      "TRUNCATE TABLE mysql.general_log;",
      "SET GLOBAL general_log=ON;",
      "SELECT @@log_output, @@general_log;",
    ].join("\n");

    let output;
    try {
      output = runMysql(options, sql);
    } catch (error) {
      console.error(`准备服务端见证日志失败：${error.message}`);
      if (error.stderr) {
        console.error(String(error.stderr).trim());
      }
      console.error("⇒ 服务端不会留下任何证据；后续的判定步必然不通过。");
      return 1;
    }

    // 「以为开了、其实没开」是本项目反复踩到的形态（装了 ≠ 生效）。
    // 所以这里**回读**实际值，而不是相信 SET 语句成功。
    const lastLine = output.split(/\r?\n/).filter((line) => line.trim() !== "").pop() || "";
    const [logOutput = "", generalLog = ""] = lastLine.split("\t");
    const tableEnabled = logOutput.split(",").map((part) => part.trim()).includes("TABLE");
    if (!tableEnabled || generalLog.trim() !== "1") {
      console.error(
        `见证日志没有真正打开：log_output=${JSON.stringify(logOutput)} general_log=${JSON.stringify(generalLog)}。` +
          "本门需要 log_output 含 TABLE 且 general_log=ON。",
      );
      return 1;
    }

    console.log(`服务端见证日志已就绪（log_output=${logOutput} general_log=${generalLog}），表已清空。`);
    return 0;
  }

  const minimum = Number(options.minConnections);
  const database = options.database;
  const user = options.user;

  // 一条查询给出四个数。口径（逐条都要成立才算一条「候选连接」）：
  //   Connect 行：user_host 以 `[<被测账户>]` 开头（root 的连接不满足），
  //               且 argument 含 ` on <测试库>`（连的是测试库，不是空库 / 别的库）；
  //   该 thread_id 上：执行过 GET_LOCK（testutil.OpenMySQL 的集成锁）、
  //                   DATABASE()、VERSION()（真实库指纹的两问）。
  // 三者同时成立，说明这条连接走的是 testutil.OpenMySQL 的**真实分支**，而不是 fake driver
  // （fake driver 根本不产生服务端连接）。
  const sql = `
SELECT
  COUNT(*) AS candidate_connections,
  COALESCE(SUM(c.version_hits), 0) AS version_queries,
  COALESCE(SUM(c.database_hits), 0) AS database_queries,
  COALESCE(SUM(c.getlock_hits), 0) AS getlock_queries
FROM (
  SELECT
    g.thread_id,
    (SELECT COUNT(*) FROM mysql.general_log q
       WHERE q.thread_id = g.thread_id AND q.command_type IN ('Query', 'Prepare')
         AND LOCATE('VERSION()', CONVERT(q.argument USING utf8mb4)) > 0) AS version_hits,
    (SELECT COUNT(*) FROM mysql.general_log q
       WHERE q.thread_id = g.thread_id AND q.command_type IN ('Query', 'Prepare')
         AND LOCATE('DATABASE()', CONVERT(q.argument USING utf8mb4)) > 0) AS database_hits,
    (SELECT COUNT(*) FROM mysql.general_log q
       WHERE q.thread_id = g.thread_id AND q.command_type IN ('Query', 'Prepare')
         AND LOCATE('GET_LOCK(', CONVERT(q.argument USING utf8mb4)) > 0) AS getlock_hits
  FROM mysql.general_log g
  WHERE g.command_type = 'Connect'
    AND g.user_host LIKE '[${user}]%'
    AND LOCATE(' on ${database}', CONVERT(g.argument USING utf8mb4)) > 0
) AS c
WHERE c.version_hits > 0 AND c.database_hits > 0 AND c.getlock_hits > 0;`;

  let output;
  try {
    output = runMysql(options, sql);
  } catch (error) {
    // fail-closed：读不到就**不能**说「没问题」。区分「读不到」与「读到了但不够」——
    // 两者的修法完全不同（前者查权限 / general_log 是否打开，后者查测试到底跑没跑）。
    console.error(`读不到服务端证据（mysql 执行失败）：${error.message}`);
    if (error.stderr) {
      console.error(String(error.stderr).trim());
    }
    console.error("⇒ 本门无法判定，按不通过处理。先确认 --prepare 步成功、root 口令与端口正确。");
    return 1;
  }

  const [row = ""] = output.split(/\r?\n/);
  const [connections, versionQueries, databaseQueries, getlockQueries] = row
    .split("\t")
    .map((value) => Number(value));

  if (![connections, versionQueries, databaseQueries, getlockQueries].every(Number.isFinite)) {
    console.error(`无法解析服务端返回（原文：${JSON.stringify(row)}）——本门无法判定，按不通过处理。`);
    return 1;
  }

  console.log(
    `服务端看到：以 ${user} 连上 ${database}、并执行过 OpenMySQL 启动序列的连接 ${connections} 条` +
      `（VERSION() ${versionQueries} 次 / DATABASE() ${databaseQueries} 次 / GET_LOCK ${getlockQueries} 次）。`,
  );

  if (connections < minimum) {
    console.error("");
    console.error(
      `门不通过：服务端只看到 ${connections} 条真实连接，低于下界 ${minimum} 条。`,
    );
    console.error(
      "  ⇒ 测试进程的日志可以伪造（一行 t.Log / fmt.Println），**服务端的连接计数不能**。\n" +
        "    0 条常见于「DSN 没配 / 用例被跳过」；数字变小常见于「删 / 改名 / -skip 掉了用例」。\n" +
        "    若上一步 `go test` 已经红了，本步的 0 是它的下游结果，先修那一步。",
    );
    return 1;
  }

  console.log(`门通过：真实连接 ${connections} 条 >= 下界 ${minimum} 条。`);
  return 0;
}

process.exit(main(process.argv));
