#!/usr/bin/env node
// CI 门：证明 Go 的 MySQL 集成测试**真的执行过**，且执行的是**真实数据库**。
//
// 用法：node scripts/check-go-integration-gate.mjs <go-test.jsonl>
//
// 输入是 `go test ./... -count=1 -json` 的原始输出（一行一个 JSON 事件）。
// 本脚本**不读** `--- PASS:` 文本——那种文本判据有四个可击穿的缝（见下）。
//
// 为什么不用 grep 文本日志（falsifier 对第一版的判定，逐条对应本脚本的一条判据）：
//   A1 只判「非空」→ 删掉 9 条里的 8 条仍绿。本脚本判 `passed >= 8`（真实连库的下界）。
//   A2 无法区分真 MySQL 与 fake driver。本脚本要求出现 REAL_DB_FINGERPRINT 标记。
//   A3 `^--- SKIP:` 锚在行首，抓不到缩进 4 空格的子测试。本脚本按 JSON 的
//      Action=="skip" 计数，与缩进无关。
//   A6 `go test` 对成功的包缓存，`-v` 会回放上次的 PASS。调用方用 `-count=1` 从根上避免；
//      本脚本额外检查 `(cached)` 事件作为纵深防御。
//
// 退出码：0 = 门通过；1 = 门不通过（无法证明它要证明的事）；2 = 用法/输入错误。

import { readFileSync } from "node:fs";

// 真实连 MySQL 的顶层集成用例数的**下界**。
//
// 为什么是 8 而不是 9：testutil/mysql_test.go 的 TestAcquireIntegrationLockSucceeds
// 走的是自注册的 fake driver，**从未连过 MySQL**，它不属于本门要证明的东西。
// 实测（`grep -rn 'func Test.*Integration' services/go-user-system --include=*_test.go`）：
//   dao/user_integration_test.go                     3
//   service/auth_integration_test.go                 2
//   service/user_test.go                             2
//   service/bootstrap_test.go                        1
//   testutil/mysql_test.go 的 TestAcquireIntegrationLockSucceeds（fake）  1 —— 不计
//   ⇒ 真实连库的 = 8
//
// 取舍（已知且接受）：加用例不会红（>= 不是 ==），删到 8 以下才红。
// 不写成「== 用例总数」是因为那个数要跟着仓库变，门会变成「每次加用例都得改门」；
// 也不写成名字白名单，因为白名单会在重命名时静默失效（名字对不上 = 不计入 = 门变松）。
const MIN_REAL_INTEGRATION_PASSES = 8;

const FINGERPRINT_PREFIX = "REAL_DB_FINGERPRINT ";

// 集成用例的识别口径：顶层 + 名字里有 Integration。
// 顶层 = Test 字段不含 "/"；子测试由父用例的 PASS/SKIP 代表，单独计数会重复。
function isTopLevelIntegrationTest(name) {
  return typeof name === "string" && name.length > 0 && !name.includes("/") && name.includes("Integration");
}

// skip 判据的适用范围：**集成用例**（含其子测试），而不是「一切 skip」。
//
// 为什么不能是「一切 skip」：套件里有**故意** skip 的单元测——
// `TestOpenMySQLSkipsWhenDSNIsMissing`（mysql_test.go）先 t.Setenv 清空 DSN 再调 OpenMySQL，
// 它验的正是「没有 DSN 时应 skip」。把它判红等于要求删掉一条合法用例（实测踩到）。
//
// 为什么这样仍然堵得住 A3 / 原始的假绿路径：
//   - 「DSN 配错 → 集成测全 SKIP」：集成测名字含 Integration，照样被抓。
//   - 「把用例包进 t.Run 再 t.Skip」（A3）：子测试名形如 `TestXIntegration/sub`，含 Integration，
//     照样被抓。
//   - 「把集成用例改名去掉 Integration 来绕过 skip 判据」：改名会让判据 ③ 的 PASS 计数下降，
//     低于下界 8 即红——两条判据互为兜底。
function isIntegrationTestName(name) {
  return typeof name === "string" && name.includes("Integration");
}

function main(argv) {
  const logPath = argv[2];
  if (!logPath) {
    console.error("用法: node scripts/check-go-integration-gate.mjs <go-test.jsonl>");
    return 2;
  }

  let raw;
  try {
    raw = readFileSync(logPath, "utf8");
  } catch (error) {
    // fail-closed：日志不存在说明上一步根本没跑成，不能当成「没有问题」。
    console.error(`找不到或读不了 ${logPath}：${error.message}`);
    console.error("这意味着上一步（go test）没有留下日志——门无法判定，按不通过处理。");
    return 1;
  }

  const events = [];
  const malformed = [];
  const lines = raw.split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index].trim();
    if (line === "") {
      continue;
    }
    try {
      events.push(JSON.parse(line));
    } catch {
      // 允许少量非 JSON 行（例如 `go: downloading …`），但把行号与原文留住。
      // 编译器的报错走的是 stderr，**不是** JSON 事件——它只会出现在这里。
      malformed.push({ lineNumber: index + 1, text: line });
    }
  }

  if (events.length === 0) {
    console.error(`${logPath} 里没有任何可解析的 go test JSON 事件——门无法判定，按不通过处理。`);
    if (malformed.length > 0) {
      console.error(`非 JSON 行：${malformed.slice(0, 5).map((entry) => entry.lineNumber).join(", ")}${malformed.length > 5 ? " …" : ""}`);
    }
    return 1;
  }

  const passedIntegration = new Set();
  const skipped = [];
  const failed = [];
  const buildFailures = [];
  const buildOutput = [];
  const packageOutput = new Map();
  const cachedActions = new Set();
  let fingerprint = "";

  for (const event of events) {
    const { Action: action, Test: test, Package: pkg, ImportPath: importPath, Output: output } = event;
    const isTestEvent = typeof test === "string" && test.length > 0;

    switch (action) {
      case "pass":
        if (isTestEvent && isTopLevelIntegrationTest(test)) {
          passedIntegration.add(test);
        }
        break;
      case "skip":
        // 只有**集成用例**被跳过才是失败。
        // `go test -json` 对**没有测试文件的包**（本仓的 go-user-system/docs）会发一条
        // 不带 Test 的 `{"Action":"skip"}`（实测）；那既不是用例，也与本门无关。
        // `TestOpenMySQLSkipsWhenDSNIsMissing` 则是故意 skip 的单元测（见 isIntegrationTestName）。
        if (isTestEvent && isIntegrationTestName(test)) {
          skipped.push(`${pkg || "?"} :: ${test}`);
        }
        break;
      case "fail":
        if (!isTestEvent) {
          // 包级失败：编译错误 / 无法执行（旧版 Go 的形态）。
          const tail = (packageOutput.get(pkg) || []).slice(-5);
          buildFailures.push(`${pkg || "?"}${tail.length > 0 ? `\n${tail.map((line) => `        ${line}`).join("\n")}` : ""}`);
        } else {
          failed.push(`${pkg || "?"} :: ${test}`);
        }
        break;
      case "build-fail":
        // Go 1.25 起，构建失败有独立事件（`-json` 实测），不在包级 fail 里。
        // ImportPath 形如 `pkg [pkg.test]`；去掉方括号里的测试二进制后缀，好与包级 fail 去重。
        if (typeof importPath === "string") {
          buildFailures.push(importPath.replace(/\s*\[[^\]]*\]\s*$/, ""));
        }
        break;
      case "build-output":
        // 编译器报错走这里（Go 1.25 实测）；它不是 stderr 原始行，也不需要是。
        if (typeof output === "string" && output.trim() !== "") {
          buildOutput.push(output.trim());
        }
        break;
      case "output": {
        if (typeof output === "string" && output.includes(FINGERPRINT_PREFIX)) {
          fingerprint = output.trim();
        }
        // 包级（无 Test 字段）的输出留最后几行；带 Test 的输出属于用例，不混进编译诊断。
        if (!isTestEvent && typeof output === "string" && typeof pkg === "string") {
          const linesForPackage = packageOutput.get(pkg) || [];
          linesForPackage.push(output.trim());
          packageOutput.set(pkg, linesForPackage.slice(-10));
        }
        break;
      }
      default:
        break;
    }

    if (typeof output === "string" && output.includes("(cached)")) {
      cachedActions.add(`${test || pkg || "?"}`);
    }
  }

  const passed = [...passedIntegration].sort();

  console.log(`集成用例（顶层、名字含 Integration）通过 ${passed.length} 个：`);
  for (const name of passed) {
    console.log(`  - ${name}`);
  }
  if (fingerprint !== "") {
    console.log(`真实库指纹：${fingerprint}`);
  } else {
    console.log("真实库指纹：未发现");
  }

  const problems = [];

  // 判据 ⓪（A5 的诊断分流）：**先**报 go test 自身的失败，**再**报判据。
  //
  // 顺序是有意义的：基础设施坏了（编译失败 / DSN 连不上 / 库名被 assertTestDatabase 拒绝）时，
  // 日志里同样没有 PASS。若先报「集成用例 0 个」，读者会把「环境坏了」读成「这道门是空的」——
  // 方向对（都失败），但结论错，会把人引去查门的代码而不是查环境。
  if (buildFailures.length > 0) {
    const uniqueFailures = [...new Set(buildFailures)];
    const compilerLines = buildOutput.slice(-10).map((line) => `        ${line}`);
    const stderrLines = malformed
      .filter((entry) => !entry.text.startsWith("go: "))
      .slice(-10)
      .map((entry) => `        ${entry.text}`);
    const details = compilerLines.length > 0 ? compilerLines : stderrLines;
    problems.push(
      `go test 有构建失败 ${uniqueFailures.length} 个（编译错误——集成用例根本没跑起来）。\n` +
        "这不是「判据没建」，是「测试没跑成」：先查编译。\n" +
        uniqueFailures.map((entry) => `    - ${entry}`).join("\n") +
        (details.length > 0 ? `\n    编译输出：\n${details.join("\n")}` : ""),
    );
  }
  if (failed.length > 0) {
    problems.push(
      `有用例执行失败 ${failed.length} 个（门能判，是测试本身红了）：\n` +
        failed.map((entry) => `    - ${entry}`).join("\n"),
    );
  }

  // 判据 ①（A2）：必须有一条真实库指纹。
  // 这不是「顺带多看一眼」——它是**唯一**能把「真 MySQL」和「fake driver」分开的证据：
  // 后者的 PASS/SKIP/FAIL 事件与前者完全同形。
  if (fingerprint === "") {
    problems.push(
      `缺少真实库指纹（${FINGERPRINT_PREFIX.trim()}）。` +
        "集成测可能根本没连上 MySQL（被换成 fake driver、或 DSN 指向了替身），" +
        "此时 PASS 事件不能作为「连过真实数据库」的证据。",
    );
  }

  // 判据 ②（A3）：集成用例（含子测试）不得被跳过。
  if (skipped.length > 0) {
    problems.push(
      `存在被 SKIP 的集成测试 ${skipped.length} 个（含子测试）：\n` +
        skipped.map((entry) => `    - ${entry}`).join("\n"),
    );
  }

  // 判据 ③（A1）：真实连库的集成用例不得少于下界。
  if (passed.length < MIN_REAL_INTEGRATION_PASSES) {
    problems.push(
      `真实集成用例通过 ${passed.length} 个，低于下界 ${MIN_REAL_INTEGRATION_PASSES} 个。` +
        "删除或改名集成用例会让这道门变松——这正是它要防的事。",
    );
  }

  // 判据 ④（A6 的纵深防御）：`(cached)` 说明这是上一次运行的回放，不是本次执行。
  // 调用方必须带 `-count=1`（从根上让缓存不出现）；这里再挡一次，避免有人把 -count=1 去掉。
  if (cachedActions.size > 0) {
    problems.push(
      "日志里出现 (cached)：这是上一次运行的回放，不是本次执行。" +
        "请确认 `go test` 带了 `-count=1`。",
    );
  }

  if (problems.length > 0) {
    console.error("");
    console.error(`门不通过（${problems.length} 项）：`);
    for (const problem of problems) {
      console.error(`  * ${problem}`);
    }
    return 1;
  }

  console.log("");
  console.log(
    `门通过：真实库指纹存在，无 SKIP、无失败，顶层集成用例 ${passed.length} 个 >= 下界 ${MIN_REAL_INTEGRATION_PASSES} 个。`,
  );
  return 0;
}

process.exit(main(process.argv));
