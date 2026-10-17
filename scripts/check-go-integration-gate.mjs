#!/usr/bin/env node
// CI 门（第一道）：从 `go test -json` 日志判断集成测「看起来」跑过、且「看起来」连的是真实数据库。
//
// ⚠️ 本门是**跳线（tripwire），不是证据（proof）**。它能证明的只有一件事：
//   「测试进程自己在日志里说了：有 8 条集成用例 PASS、且各打出了一行真实库指纹」。
// 它**不能**证明这些话是真的——qa 已实测（2026-10-17，F1/F2/F3 三个形态）：
//   在任意测试体内写**一行** `t.Log("REAL_DB_FINGERPRINT …")` 或 `fmt.Println(…)`，
//   `go test -json` 就会把这条 Output 事件归因到那条测试，
//   于是「假用例补上被删 / 被 skip 让出的槽位」原样复活，甚至可以在**零连库**下全绿。
//   **攻击成本 = 一行日志。**
// ⇒ 禁止把本门的绿色引用为「集成测真的连过库」的证据。真证据在第二道门：
//   `scripts/check-go-integration-server-witness.mjs`（读 MySQL 服务端 general_log，
//   测试进程够不着那个账本）。本门防的是**误配 / 疏忽**（DSN 没配、用例被无意跳过、
//   fake driver 被误接上），防不住蓄意伪造。
//
// 用法：node scripts/check-go-integration-gate.mjs <go-test.jsonl>
//
// 输入是 `go test ./... -count=1 -json` 的原始输出（一行一个 JSON 事件）。
// 本脚本**不读** `--- PASS:` 文本——那种文本判据有四个可击穿的缝（见下）。
//
// 为什么不用 grep 文本日志（falsifier 对第一版的判定，逐条对应本脚本的一条判据）：
//   A1 只判「非空」→ 删掉 9 条里的 8 条仍绿。本脚本判「**带自有指纹**的顶层集成 PASS
//      集合 >= 8」——下界是**真实连库**的用例数，不是名字里带 Integration 的用例数。
//   A2 无法区分真 MySQL 与 fake driver。本脚本要求出现 REAL_DB_FINGERPRINT 标记。
//   A3 `^--- SKIP:` 锚在行首，抓不到缩进 4 空格的子测试。本脚本按 JSON 的
//      Action=="skip" 计数，与缩进无关。
//   A6 `go test` 对成功的包缓存，`-v` 会回放上次的 PASS。调用方用 `-count=1` 从根上避免；
//      本脚本额外检查 `(cached)` 事件作为纵深防御。
//
// 返工（2026-10-17，qa-validator 的 03 环阻断）：
//   G1 上一版的下界判据数的是「名字含 Integration 的顶层 PASS」，其中
//      `TestAcquireIntegrationLockSucceeds` 走 fake driver、**从未连过库**，却照样被计入——
//      注释里写着「不计」，代码没有实现这句话。假槽位正好吃掉「删/改名一条真用例」降下来的那 1 个，
//      于是「删掉一条真用例」仍然绿（qa 真跑证明）。
//      修法：判据从「单值计数」改为「**按 Test 归因的集合**」——见下方 MIN 常量与判据 ③。
//      残余（G1-R1，**结构性、本门修不了**）：归因来自测试进程自己的日志，所以**一行日志就能伪造**。
//      qa 的 F1/F2/F3 已实测。本门因此**降格为跳线**（见文件头）；真证据在服务端见证门。
//   G1-R3 「门红」的两种原因必须能分开报：**用例被删 / 改名 / skip** 与 **用例偶发失败**
//      在退出码上同形，但修法完全不同。判据 ③ 现在三分（判据里逐条对应）：
//      (a) 有指纹、且在日志里有一条属于它的红（fail 事件，或顶层且含 Integration 的 skip）
//          ⇒「用例确实跑过但没通过」（偶发失败 / 真失败）；
//      (b) 有指纹，但既无 PASS 也无 FAIL / skip 事件 ⇒ 改名或删除（改名后名字不再含 Integration，
//          ② 抓不到它，它也不会产生 fail 事件）；
//      (c) 一条孤儿指纹都没有 ⇒ 打指纹的用例根本没跑起来（-skip / 整条删除 / DSN 没配）。
//   G5 上一版把**任何**包级 fail 都当构建失败，实测 `t.Fatalf` 的包级事件
//      `{"Action":"fail","Package":"…/dao","Elapsed":1.6}`（**无 FailedBuild 字段**）
//      被报成「编译错误——集成用例根本没跑起来」，方向对（红）但结论错（把人引去查编译）。
//      修法：包级 fail **必须**有 FailedBuild 字段才判构建失败；否则归入「用例失败」族。
//      同时去重：`build-fail` 事件与带 FailedBuild 的包级 fail 是**同一次**编译失败，只报 1 条。
//   G5-R1 上一版注释把 ImportPath 写成固定形态，与实测不符；已按两种实测形态改写（见 normalizeImportPath）。
//
// 退出码：0 = 门通过；1 = 门不通过（无法证明它要证明的事）；2 = 用法/输入错误。

import { readFileSync } from "node:fs";

// 真实连 MySQL 的顶层集成用例数的**下界**。
//
// 口径：**带自有指纹**（REAL_DB_FINGERPRINT 事件被 go test 归因到这条测试名下）
// 且 PASS 的顶层、名字含 Integration 的用例数。
//
// ⚠️ 「指纹」只说明**测试进程打印了这一行**，不说明它真的连过库（见文件头的 G1-R1）。
// 下界 8 是「正常的正向运行里应当有 8 条」的记账值，不是服务端事实；
// 服务端事实由 scripts/check-go-integration-server-witness.mjs 给。
//
// 为什么是 8：本机隔离 MySQL 8.4.8 上真实跑一遍，指纹行按 Test 去重后是 8 条——
//   $ node -e "const fs=require('fs');const s=new Set();for(const l of fs.readFileSync(process.argv[1],'utf8').split(/\r?\n/)){let e;try{e=JSON.parse(l)}catch{continue}if(e.Action==='output'&&typeof e.Output==='string'&&e.Output.includes('REAL_DB_FINGERPRINT ')&&e.Test)s.add(e.Test.split('/')[0])}console.log(s.size)" go-test.jsonl
//   8
//   8 条分别是（domains 省略）：
//     TestAuthServiceIntegrationConcurrentRefreshAllowsOneSuccessAndRevokesFamilyOnReplay
//     TestBootstrapAdminIntegrationCreatesOnlyAdministrator
//     TestUserDAOIntegrationCreateReadAndUpdateUser
//     TestUserDAOIntegrationHonorsCanceledContext
//     TestUserDAOIntegrationReturnsNotFoundForMissingUser
//     TestUserServiceIntegrationPasswordChangeInvalidatesOldAuthVersionAndRefreshTokens
//     TestUserServiceIntegrationRegisterLoginProfileAndNickname
//     TestUserServiceIntegrationRejectsDisabledUser
//   名字里带 Integration 的顶层用例一共 **9** 条，第 9 条是
//   testutil/mysql_test.go 的 TestAcquireIntegrationLockSucceeds —— 它走自注册的 fake driver，
//   **不产生指纹**，因此在新口径下**自然被排除**（不需要任何名字特判）。
//
// ⚠️ **这句话只剩「那条测试碰巧没打日志」这个偶然事实**（qa 的 G1-R1 实测）：
// 在它里面加一行 t.Log("REAL_DB_FINGERPRINT …")，它就会重新计入。
// 所以「fake 用例自然出局」**不是判据的性质，是当前测试代码的性质**。
//
// 取舍（已知且接受）：加用例不会红（>= 不是 ==），删到 8 以下才红。
// 不写成「== 用例总数」是因为那个数要跟着仓库变，门会变成「每次加用例都得改门」；
// 也不写成名字白名单，因为白名单会在重命名时静默失效（名字对不上 = 不计入 = 门变松）。
const MIN_FINGERPRINTED_INTEGRATION_PASSES = 8;

const FINGERPRINT_PREFIX = "REAL_DB_FINGERPRINT ";

// 集成用例的识别口径：顶层 + 名字里有 Integration。
// 顶层 = Test 字段不含 "/"；子测试由父用例的 PASS/SKIP 代表，单独计数会重复。
function isTopLevelIntegrationTest(name) {
  return typeof name === "string" && name.length > 0 && !name.includes("/") && name.includes("Integration");
}

// 顶层归一：`TestParent/sub` → `TestParent`。
// 指纹行由 testutil.OpenMySQL 里的 t.Log 打印，若它是在子测试里被调用的，
// Output 事件的 Test 字段会带 "/"。归属应当是**运行它的顶层用例**——门判的是顶层用例。
function topLevelTestName(name) {
  const slash = name.indexOf("/");
  return slash === -1 ? name : name.slice(0, slash);
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
//   - 「把集成用例改名去掉 Integration 再 t.Skip」（qa 的 G3）：**本判据抓不到它**（名字不含
//     Integration 了），拦住它的是判据 ③——改名后它不再计入「带自有指纹的顶层集成 PASS」，
//     集合大小从 8 掉到 7，低于下界。
//
// ⚠️ 上一版这里写的是「两条判据互为兜底」，但当时**不成立**：③数的是「名字含 Integration 的
// PASS」，而 fake 的 TestAcquireIntegrationLockSucceeds 正好补上被改名用例让出的那个槽位，
// 于是「改名 + skip」仍然绿（qa 真跑证明）。现在 ③ 的口径换成**指纹归因的集合**，
// 假槽位不再存在，这句话才第一次成立。
// ⚠️ 但它成立的**前提是「没人往 fake 用例里加一行指纹日志」**（G1-R1）——那正是本门挡不住的。
// 判据 ② 与 ③ 互兜底，挡的是**误操作**，不是**意图**。
function isIntegrationTestName(name) {
  return typeof name === "string" && name.includes("Integration");
}

// 编译失败时两个事件里的 ImportPath 实测有**两种**形态（2026-10-17 本机复测）：
//   ① 包自带的测试二进制编译失败：`go-user-system/internal/dao [go-user-system/internal/dao.test]`
//      （`build-output` 与 `build-fail` 的 ImportPath、包级 fail 的 FailedBuild 字段同形）；
//   ② 被依赖的包编译失败：`go-user-system/internal/dao`（**无方括号**，且 ImportPath 是出错的那个包）。
// 上一版注释把 ① 写成了唯一形态，与 qa 实测（`pkg.test`，无方括号）不符——**那只是它当时注入的位置不同**，
// 不是事实冲突。下面两种都处理：去掉方括号里的测试二进制后缀，好让**同一次**编译失败的两个事件归并为 1 条。
function normalizeImportPath(path) {
  return String(path).replace(/\s*\[[^\]]*\]\s*$/, "").trim();
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

  // ---- 收集 --------------------------------------------------------------
  const passedIntegration = new Set(); // 顶层、名字含 Integration 的 PASS
  const fingerprintsByTest = new Map(); // 顶层测试名 -> 指纹原文（Set 语义，重复只留第一条）
  const unattributedFingerprints = []; // 有指纹但没有 Test 字段（无法归因）
  const skipped = [];
  const skippedIntegrationNames = new Set(); // 顶层归一后的跳过用例名（判据 ③ 的分诊用）
  const failedTests = []; // { pkg, test }
  const failedTestNames = new Set(); // 顶层归一后的失败用例名（判据 ③ 的分诊用）
  const failedPackages = []; // 包级 fail 且**没有** FailedBuild：非构建失败
  const buildFailures = new Set(); // 归一后的 import path；同一次编译失败只留 1 条
  const buildOutput = [];
  const packageOutput = new Map();
  const cachedActions = new Set();

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
          skippedIntegrationNames.add(topLevelTestName(test));
        }
        break;
      case "fail":
        // G5：包级 fail 有两种，**必须看 FailedBuild 才分得清**。
        //   有 FailedBuild（实测形如 `pkg [pkg.test]`）→ 编译失败，与 build-fail 事件同源；
        //   没有 FailedBuild（实测 `t.Fatalf` 的形态，连字段都没有）→ **是用例失败**，
        //     绝不能报成「编译错误——集成用例根本没跑起来」（那会把人引去查编译）。
        if (typeof event.FailedBuild === "string" && event.FailedBuild.trim() !== "") {
          buildFailures.add(normalizeImportPath(event.FailedBuild));
        } else if (isTestEvent) {
          failedTests.push({ pkg: pkg || "?", test });
          failedTestNames.add(topLevelTestName(test));
        } else {
          failedPackages.push(pkg || "?");
        }
        break;
      case "build-fail":
        // Go 1.25 起，构建失败有独立事件（`-json` 实测），且**同时**带一条 FailedBuild 的包级 fail。
        // 两者都归到同一个 set 里，按归一后的 import path 去重——同一次编译失败只报 1 条。
        buildFailures.add(normalizeImportPath(importPath || pkg || "(unknown import path)"));
        break;
      case "build-output":
        // 编译器报错走这里（Go 1.25 实测）；它不是 stderr 原始行，也不需要是。
        if (typeof output === "string" && output.trim() !== "") {
          buildOutput.push(output.trim());
        }
        break;
      case "output": {
        if (typeof output === "string" && output.includes(FINGERPRINT_PREFIX)) {
          // G1 的核心：指纹**按 Test 归因**。go test -json 会把 t.Log 的 Output 事件
          // 标上打出它的测试名，所以这里不需要 runtime.Caller、也不需要改 OpenMySQL 的签名。
          if (isTestEvent) {
            const owner = topLevelTestName(test);
            if (!fingerprintsByTest.has(owner)) {
              fingerprintsByTest.set(owner, output.trim());
            }
          } else {
            unattributedFingerprints.push(output.trim());
          }
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

  // ---- 判据 ③ 的集合：**带自有指纹**的顶层集成 PASS --------------------------------
  //
  // 两个条件同时成立才计入：
  //   ① 顶层、名字含 Integration、Action=="pass"；
  //   ② 存在一条指纹事件，其 Test 字段（顶层归一后）**就是它自己**。
  // 于是 fake 的 TestAcquireIntegrationLockSucceeds（无指纹）自然出局；
  // 删掉 / 改名 / skip 掉任意一条真用例，集合就少一个元素。
  const countedNames = [...passedIntegration].filter((name) => fingerprintsByTest.has(name)).sort();
  // 指纹在手、但没进「顶层 Integration PASS」集合的用例——判据 ③ 要靠它**区分两种红**。
  const fingerprintWithoutIntegrationPass = [...fingerprintsByTest.keys()]
    .filter((name) => !passedIntegration.has(name))
    .sort();
  const fingerprintWithoutIntegrationPassFailed = fingerprintWithoutIntegrationPass.filter(
    (name) => failedTestNames.has(name) || skippedIntegrationNames.has(name),
  );
  const fingerprintWithoutIntegrationPassNotFailed = fingerprintWithoutIntegrationPass.filter(
    (name) => !failedTestNames.has(name),
  );

  const passed = [...passedIntegration].sort();

  console.log(`顶层集成用例（名字含 Integration）PASS ${passed.length} 个，其中带自有指纹 ${countedNames.length} 个：`);
  for (const name of passed) {
    console.log(`  - ${name}${fingerprintsByTest.has(name) ? "  [指纹 ✓]" : "  [无指纹——不计入]"}`);
  }
  if (fingerprintsByTest.size > 0) {
    const sample = countedNames.length > 0 ? countedNames[0] : [...fingerprintsByTest.keys()].sort()[0];
    console.log(`真实库指纹（示例，来自 ${sample}）：${fingerprintsByTest.get(sample)}`);
  } else if (unattributedFingerprints.length > 0) {
    console.log(`真实库指纹：${unattributedFingerprints[0]}（事件里没有 Test 字段，无法归因——见下方判据）`);
  } else {
    console.log("真实库指纹：未发现");
  }

  const problems = [];

  // ---- 判据 ⓪（A5 的诊断分流）：**先**报 go test 自身的失败，**再**报判据 ------------------
  //
  // 顺序是有意义的：基础设施坏了（编译失败 / DSN 连不上 / 库名被 assertTestDatabase 拒绝）时，
  // 日志里同样没有 PASS。若先报「集成用例 0 个」，读者会把「环境坏了」读成「这道门是空的」——
  // 方向对（都失败），但结论错，会把人引去查门的代码而不是查环境。
  //
  // 三种失败分开报，因为修法完全不同：
  //   构建失败 → 查编译；用例失败 → 看是哪条测试红了；包级失败但无具体用例 → 查 panic / TestMain。
  if (buildFailures.size > 0) {
    const uniqueFailures = [...buildFailures].sort();
    const compilerLines = buildOutput.slice(-10).map((line) => `        ${line}`);
    const stderrLines = malformed
      .filter((entry) => !entry.text.startsWith("go: "))
      .slice(-10)
      .map((entry) => `        ${entry.text}`);
    const details = compilerLines.length > 0 ? compilerLines : stderrLines;
    problems.push(
      `go test 有构建失败 ${uniqueFailures.length} 个（编译错误——测试二进制根本没编出来）。\n` +
        "这不是「判据没建」，是「测试没跑成」：先查编译。\n" +
        uniqueFailures.map((entry) => `    - ${entry}`).join("\n") +
        (details.length > 0 ? `\n    编译输出：\n${details.join("\n")}` : ""),
    );
  }
  if (failedTests.length > 0) {
    problems.push(
      `有用例执行失败 ${failedTests.length} 个（门能判，是测试本身红了——**不是**编译错误）：\n` +
        failedTests.map((entry) => `    - ${entry.pkg} :: ${entry.test}`).join("\n"),
    );
  }
  const packagesWithTestFailure = new Set(failedTests.map((entry) => entry.pkg));
  const packageOnlyFailures = failedPackages.filter((pkg) => !packagesWithTestFailure.has(pkg));
  if (packageOnlyFailures.length > 0) {
    problems.push(
      `有包级失败但没有具体用例失败 ${packageOnlyFailures.length} 个（既不是用例失败，也读不到 FailedBuild）。\n` +
        "常见原因：panic、TestMain 失败，或旧版 Go 的编译错误（Go >= 1.24 的编译错误走 FailedBuild 字段）。\n" +
        "先看下方该包的输出。\n" +
        [...new Set(packageOnlyFailures)].sort().map((entry) => `    - ${entry}`).join("\n"),
    );
  }

  // ---- 判据 ①（A2）：日志里必须有一条「真实库指纹」这一行 --------------------------------
  // 它不是「顺带多看一眼」：它是本门唯一**试图**把「真 MySQL」与「fake driver」分开的地方。
  //
  // ⚠️ **G8：它挡不住伪造，而且攻击成本很低。** 上一版这里写的是「改 fake driver 的兜底返回值
  // 才能造出指纹」——**写大了**。qa 实测（F1/F2/F3）：在任意测试体内写**一行**
  // `t.Log("REAL_DB_FINGERPRINT …")`、或**一行** `fmt.Println(…)`（后者不经 testing，同样被归因），
  // 就足以产出一条合格指纹。不需要改 fake driver，不需要连库。
  //   也**不要**试图用「前缀必须是 mysql.go:」或「只允许 t.Log」来补救——qa 已实测两条都能绕过：
  //   去掉 t.Helper() 能改前缀，而 fmt.Println 可以手写任意前缀。
  // ⇒ 本判据的真实作用只有两个：① 抓「DSN 配错 / 用例被无意换成 fake」这类**疏忽**；
  //   ② 让「完全没跑」有一个明确的红。它是跳线，不是证据。
  //   真证据请看 server-witness 门（服务端 general_log 的连接计数）。
  if (fingerprintsByTest.size === 0) {
    problems.push(
      `缺少真实库指纹（${FINGERPRINT_PREFIX.trim()}）。` +
        "集成测可能根本没连上 MySQL（被换成 fake driver、或 DSN 指向了替身），" +
        "此时 PASS 事件不能作为「连过真实数据库」的证据。",
    );
  }
  if (unattributedFingerprints.length > 0) {
    // fail-closed：能打出指纹却归不到具体用例，说明这条连接不是任何测试建立的。
    // 门据此无法证明「哪条用例连过库」，按不通过处理。
    problems.push(
      `有 ${unattributedFingerprints.length} 条真实库指纹无法归因到具体用例（事件里没有 Test 字段）。\n` +
        "指纹必须由某条测试的 t.Log 打出（testutil.OpenMySQL），否则无法计入下界判据。",
    );
  }

  // ---- 判据 ②（A3）：集成用例（含子测试）不得被跳过 ---------------------------------
  if (skipped.length > 0) {
    problems.push(
      `存在被 SKIP 的集成测试 ${skipped.length} 个（含子测试）：\n` +
        skipped.map((entry) => `    - ${entry}`).join("\n"),
    );
  }

  // ---- 判据 ③（A1）：**带自有指纹**的顶层集成 PASS 不得少于下界 ----------------------
  //
  // G1-R3：低于下界有两个**完全不同**的原因，修法不同，必须在输出里分开：
  //   (a) 有指纹的用例**没通过**（失败 / 跳过）——「用例偶发失败」。它同时会在判据 ⓪ / ② 里报，
  //       这里只补一句指向，避免读者把它当成「有人删了用例」。
  //       进入 (a) 而不是 (b) 的条件是：它在日志里有一条**落在集合规则之外的红**——
  //       一条顶层（不含 /）且名字含 Integration 的 skip 事件，或一条 fail 事件。
  //       ⚠️ 「改名 + t.Skip」不满足 (a)：改名后名字不含 Integration，② 抓不到它，
  //       它也没有 fail 事件 —— 那属于 (b)「被改名 / 删除」，不是「偶发失败」。
  //   (b) 有指纹但**既没 PASS 也没 FAIL 事件**——日志里根本没有这条测试的结局。
  //       正常跳过会出现在 ②；正常失败会出现在 ⓪。两者都没有 ⇒ 它被**改名 / 删除**了
  //       （改名后新名字不满足「名字含 Integration」，所以不在 passedIntegration 里；
  //        删除后连事件都没有）。**前提是它先连了库**——先连接、再在改名后的用例里 skip，
  //       才会留下指纹；实测正是这一形态。
  //   (c) 一个孤儿指纹都没有：打指纹的用例**根本没跑起来**——被 `-skip` 跳过、
  //       被整条删除、或被改名到不含 Integration 后再跳过（此时连 SKIP 事件都看不到）。
  //   (d) 与 (c) 同形，但日志里**有**含 Integration 的 SKIP 事件：改报「有集成用例被跳过」，
  //       避开「8 条全 SKIP（DSN 没配）却写成『有人删了用例』」的误报。
  if (countedNames.length < MIN_FINGERPRINTED_INTEGRATION_PASSES) {
    const details = [];
    if (fingerprintWithoutIntegrationPassFailed.length > 0) {
      details.push(
        "原因 (a)：以下用例**确实跑过**（打出了指纹），但**没有通过**（失败 / 跳过）——" +
          "这是用例失败，不是有人删了用例：\n" +
          fingerprintWithoutIntegrationPassFailed.map((entry) => `    - ${entry}`).join("\n") +
          "\n  先看判据 ⓪ 与 ② 里它们各自的失败原因；修好后计数自然回到下界。",
      );
    }
    if (fingerprintWithoutIntegrationPassNotFailed.length > 0) {
      details.push(
        "原因 (b)：以下用例打出了指纹，但日志里**既没有 PASS 也没有 FAIL**——" +
          "说明它没有以「名字含 Integration」的身份跑完：**被改名或删除**是首要解释：\n" +
          fingerprintWithoutIntegrationPassNotFailed.map((entry) => `    - ${entry}`).join("\n") +
          "\n  （改名后的新名字不含 Integration，因此不计入集合；删除后连事件都没有。）",
      );
    }
    if (details.length === 0 && skippedIntegrationNames.size > 0) {
      details.push(
        `原因 (d)：日志里有 ${skippedIntegrationNames.size} 条**名字含 Integration 的用例被跳过**（见判据 ② 的清单），\n` +
          "  且一个孤儿指纹都没有 ⇒ 它们**根本没跑**。首要解释是 DSN 没配；其次是有人用 -skip 点名跳过。\n" +
          "  这两种都**不是**「用例偶发失败」，也不是「用例被删」——按判据 ② 的清单逐条处理。",
      );
    }
    if (details.length === 0) {
      details.push(
        "原因 (c)：日志里**一条孤儿指纹都没有**，也**没有任何集成用例的 SKIP 事件**——打指纹的用例根本没跑起来。\n" +
          "  常见解释：被整条删除、被 `-skip` 跳过但改名后已不含 Integration（此时 log 里看不到 SKIP 事件），\n" +
          "  或这次不是完整的 `go test ./...`。\n" +
          "  ⚠️ 「被人故意删掉一条」也会长成这个样子——本门分不出「误删」与「故意跳过」，\n" +
          "  但服务端见证门会：删了用例，服务端的真实连接数就会掉到 8 以下。",
      );
    }
    problems.push(
      `带自有指纹的顶层集成用例通过 ${countedNames.length} 个，低于下界 ${MIN_FINGERPRINTED_INTEGRATION_PASSES} 个。\n` +
        details.join("\n"),
    );
  }

  // ---- 判据 ④（A6 的纵深防御）：`(cached)` 说明这是上一次运行的回放，不是本次执行 --------
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
    `门通过：带自有指纹的顶层集成用例 ${countedNames.length} 个 >= 下界 ${MIN_FINGERPRINTED_INTEGRATION_PASSES} 个，` +
      "无 SKIP、无失败。",
  );
  // 这句话必须跟着绿色一起出现：绿色单独出现时，读的人很容易把它当成「连过库」的证据。
  console.log(
    "⚠️ 本门是跳线，不是证据：它只核对**测试进程自己在日志里说的话**，一行 t.Log 即可伪造。" +
      "「集成测真的连过库」以 server-witness 门（服务端 general_log）为准。",
  );
  return 0;
}

process.exit(main(process.argv));
