#!/usr/bin/env node
// ============================================================================
// 断言：告警规则里的 `runbook:` 锚点必须能在目标文档里解析
// ============================================================================
//
// 为什么需要它（2026-10-06 实测）
// -----------------------------
// `deploy/monitoring/rules/knowtrace-workflow.yml` 里每条告警都带一个
// `runbook: "docs/16-stage3-observability.md#<anchor>"`，指向排障步骤。
//
// **告警响的时候，人会点那个链接。** 若锚点解析不到（标题被改过、或中文标题的
// slug 与英文写法不一致），点进去就落到文档顶部 —— 而**没有任何东西会报错**：
// Prometheus 照样加载规则、告警照样 firing、`health` 照样 `ok`。
//
// 实测抓到：13 个锚点里 12 个能解析，`#revision` **不能** ——
// 因为那个标题当时写的是 `### 运行态版本核对`（中文），而 GFM 的 slug 是
// `运行态版本核对`，不是 `revision`。同节其余 12 个标题都是英文。
//
// 与本项目其它缺口的共同形状：**判据的输入/出口坏了，而输出看起来只是「一切正常」**。
//
// 为什么放 CI 而不是巡检
// ---------------------
// 规则与文档**都在仓库里**，是静态文件。这个断言不需要服务器、不需要运行时，
// 属于「每次改都该跑」的那一类 —— 所以进 CI，让它自然发生（见 README 的判据）。
//
// 用法
// ----
//   node scripts/check-runbook-anchors.mjs
//
// 退出码：0 = 全部可解析  1 = 有锚点解析不到  3 = 脚本自身错误
// ============================================================================

import { readFileSync, existsSync } from "node:fs";
import { dirname, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const rulesFile = "deploy/monitoring/rules/knowtrace-workflow.yml";

/**
 * GFM 风格标题 → 锚点。
 * 规则：去掉行内格式（反引号/星号/下划线），去掉非字母数字（含 CJK 保留）、空格、连字符的字符，
 * 转小写，空格转连字符，去掉首尾连字符。
 * 多级标题按 GFM 只取标题文本（不带 # 号）。
 */
function slugify(headingText) {
  return headingText
    .replace(/`/g, "")
    .replace(/[*_]/g, "")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1") // markdown 链接取文本
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s-]/gu, "") // 保留字母（含 CJK）、数字、空格、连字符
    .trim()
    .replace(/\s+/g, "-")
    .replace(/^-+|-+$/g, "");
}

/** 从一个 markdown 文件里抽出所有标题生成的锚点集合 */
function anchorsOf(docPath) {
  const text = readFileSync(docPath, "utf8");
  const anchors = new Set();
  let inFence = false;
  for (const line of text.split(/\r?\n/)) {
    // 跳过代码围栏内的 `# 注释` —— 那些不是标题
    if (/^\s*(```|~~~)/.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    const m = /^(#{1,6})\s+(.*\S)\s*$/.exec(line);
    if (!m) continue;
    const base = slugify(m[2]);
    if (!base) continue;
    // GFM 对重复标题会加 -1/-2 后缀；这里只登记基础名与递增名，够用
    let slug = base;
    let n = 0;
    while (anchors.has(slug)) slug = `${base}-${++n}`;
    anchors.add(slug);
  }
  return anchors;
}

let failures = 0;
const checked = [];

if (!existsSync(resolve(repoRoot, rulesFile))) {
  console.error(`错误：找不到 ${rulesFile}`);
  process.exit(3);
}

const rules = readFileSync(resolve(repoRoot, rulesFile), "utf8");
const refRe = /runbook:\s*"([^"#]+)(?:#([^"]+))?"/g;
const seen = new Map(); // "path#anchor" → 首次出现的行号附近

for (const m of rules.matchAll(refRe)) {
  const [full, docRel, anchor] = m;
  const key = anchor ? `${docRel}#${anchor}` : docRel;
  if (!seen.has(key)) seen.set(key, rules.slice(0, m.index).split("\n").length);
}

for (const [key, lineNo] of seen) {
  const [docRel, anchor] = key.split("#");
  const docAbs = resolve(repoRoot, docRel);
  const at = `${rulesFile}:${lineNo} → ${key}`;

  if (!existsSync(docAbs)) {
    console.error(`  [FAIL] ${at}\n         文档不存在：${docRel}`);
    failures++;
    continue;
  }
  if (!anchor) {
    checked.push(`${at}（无锚点，仅文件）`);
    continue;
  }
  const anchors = anchorsOf(docAbs);
  if (anchors.has(anchor)) {
    checked.push(at);
  } else {
    console.error(
      `  [FAIL] ${at}\n` +
        `         锚点 #${anchor} 在 ${docRel} 里解析不到。\n` +
        `         该文档现有锚点（前 8 个）：${[...anchors].slice(0, 8).join(", ")} …\n` +
        `         修法：改标题使其 slug 等于 #${anchor}，或改规则里的锚点。`,
    );
    failures++;
  }
}

if (failures > 0) {
  console.error(`\nrunbook 锚点检查：${failures} 处解析不到（共 ${seen.size} 个引用）`);
  process.exit(1);
}

console.log(`runbook 锚点检查：全部可解析（${checked.length} 个引用）`);
for (const c of checked) console.log(`  OK  ${c}`);
