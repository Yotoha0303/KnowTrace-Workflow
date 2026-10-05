#!/usr/bin/env bash
# ============================================================================
# 业务级恢复验收 —— 恢复之后，**业务到底能不能用**
# ============================================================================
#
# 为什么需要它（十环「08 恢复」的准出）
# ------------------------------------
# 准出要求「不仅有数据层（checksum/行数）校验，必须提供**业务级可用性
# （登录/读写）**核验用例」。
#
# 数据层 PASS **不等于**恢复出来的东西能用：外键、附件路径、会话、迁移版本
# 都可能在恢复后才暴露问题。本项目 2026-10-04 的恢复演练实测
# `RESTORE_VERIFY=PASS`、36 秒，但**登录 / 读历史记录 / 下载附件这三件事
# 一次都没在恢复后的环境里做过** —— 因为那时生产库里没有真实业务数据。
#
# 本脚本就是那三步的可执行用例。**它不依赖恢复环境的具体形态**：
# 指向哪个 BASE_URL 就验哪个环境（刚恢复出来的那个，或生产）。
#
# 用法
# ----
#   BUSINESS_USER=<用户名> BUSINESS_PASSWORD=<口令> \
#     bash scripts/linux/verify-business-acceptance.sh
#
#   # 可选
#   BASE_URL=http://127.0.0.1:8080     # 默认走 nginx；也可指 http://127.0.0.1:3000
#   PG_CONTAINER=knowtrace-workflow-postgres-1   # 找附件样本用；默认自动解析
#
# 判据（三条，缺一条就不算业务级可用）
#   1. **登录**      POST /api/v1/auth/login → 200 且 `ok:true`，并拿到会话
#   2. **读历史记录** GET  /api/v1/captures   → 200 且至少 1 条（空库不算通过）
#   3. **下载真实附件** GET /api/evidence-images/<id> → 200 且
#                   **字节数一致 + sha256 与库里记录一致**
#
# 退出码
#   0=PASS   1=FAIL   2=前置不满足（缺凭据 / 库里还没有业务数据）   3=脚本自身错误
#
# **凭据绝不写进本文件、也不写进任何入库文档** —— 只从环境变量读。
# 为什么「没有业务数据」算前置不满足而不是失败：那是**环境状态**，
# 不是恢复损坏。恢复空库仍然是「恢复成功」，只是无从验证业务层。
# ============================================================================

set -Eeuo pipefail

base_url="${BASE_URL:-http://127.0.0.1:8080}"
business_user="${BUSINESS_USER:-}"
business_password="${BUSINESS_PASSWORD:-}"

log()  { printf '%s\n' "$*"; }
ok()   { printf '  [ OK ] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; }

if [[ -z "$business_user" || -z "$business_password" ]]; then
  fail "缺少凭据：需要 BUSINESS_USER 与 BUSINESS_PASSWORD 环境变量"
  log "      **不要把口令写进本文件或任何入库文档。**"
  log "      用法：BUSINESS_USER=... BUSINESS_PASSWORD=... bash $0"
  exit 2
fi

for c in curl jq; do
  command -v "$c" >/dev/null || { fail "缺少命令 $c"; exit 3; }
done

workdir="$(mktemp -d)"
trap 'rm -rf -- "$workdir"' EXIT
cookie_jar="$workdir/cookies.txt"
started_at="$(date -u +%s)"

log "=== 业务级恢复验收 ==="
log "BASE_URL=$base_url"
log "STARTED_AT_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log

# ---- 1. 登录 -----------------------------------------------------------------
log "== 1/3 登录 =="
login_body="$workdir/login.json"
login_code="$(curl -sS -o "$login_body" -w '%{http_code}' \
  -c "$cookie_jar" \
  -H 'Content-Type: application/json' \
  -H "X-Forwarded-For: 127.0.0.1" \
  -X POST "$base_url/api/v1/auth/login" \
  --data "$(jq -cn --arg u "$business_user" --arg p "$business_password" '{username:$u,password:$p}')" \
  2>/dev/null || printf '000')"

if [[ "$login_code" != "200" ]]; then
  fail "登录返回 HTTP $login_code（期望 200）"
  log "      响应：$(head -c 300 "$login_body" 2>/dev/null || printf '(空)')"
  log "      排查：AUTH 是否启用、账号是否存在、口令是否正确、是否被登录限流"
  log "RESULT=FAIL"
  exit 1
fi
if [[ "$(jq -r '.ok // false' "$login_body" 2>/dev/null)" != "true" ]]; then
  fail "登录 HTTP 200 但 ok != true"
  log "      响应：$(head -c 300 "$login_body" 2>/dev/null)"
  log "RESULT=FAIL"
  exit 1
fi
if [[ ! -s "$cookie_jar" ]]; then
  warn "登录成功但没有拿到会话 cookie —— 后面几步可能 401（原生客户端走 Bearer，本脚本按浏览器流程验）"
else
  ok "登录成功，已取得会话"
fi

# 会话可用性（顺带验证会话在下一跳仍有效 —— 这正是「恢复后会话能不能用」）
session_body="$workdir/session.json"
session_code="$(curl -sS -o "$session_body" -w '%{http_code}' -b "$cookie_jar" \
  "$base_url/api/v1/auth/session" 2>/dev/null || printf '000')"
if [[ "$session_code" == "200" ]] && [[ "$(jq -r '.ok // false' "$session_body" 2>/dev/null)" == "true" ]]; then
  ok "会话可用（/api/v1/auth/session → 200）"
else
  fail "会话不可用（HTTP $session_code）—— 登录成功但下一跳认不出会话"
  log "RESULT=FAIL"
  exit 1
fi
log

# ---- 2. 读历史记录 -----------------------------------------------------------
log "== 2/3 读历史记录 =="
captures_body="$workdir/captures.json"
captures_code="$(curl -sS -o "$captures_body" -w '%{http_code}' -b "$cookie_jar" \
  "$base_url/api/v1/captures" 2>/dev/null || printf '000')"

if [[ "$captures_code" != "200" ]]; then
  fail "读记录返回 HTTP $captures_code（期望 200）"
  log "      响应：$(head -c 300 "$captures_body" 2>/dev/null || printf '(空)')"
  log "RESULT=FAIL"
  exit 1
fi

captures_count="$(jq -r 'if (.data|type)=="array" then (.data|length) else ((.data.items // [])|length) end' "$captures_body" 2>/dev/null || printf '0')"
if [[ ! "$captures_count" =~ ^[0-9]+$ ]]; then captures_count=0; fi

if (( captures_count == 0 )); then
  warn "读记录返回 200，但**库里没有任何记录** —— 业务数据尚未就位"
  log
  log "      ⚠ 这**不是**恢复失败：恢复空库也是「恢复成功」，只是无从验证业务层。"
  log "      这正是 2026-10-04 演练记录里「业务级三步无法验证」的原因。"
  log "      等生产库有真实业务数据后重跑本脚本即可。"
  log "RESULT=SKIP（前置：无业务数据）"
  exit 2
fi
ok "读到 $captures_count 条记录"
log

# ---- 3. 下载真实附件 ---------------------------------------------------------
log "== 3/3 下载真实附件 =="

pg_container="${PG_CONTAINER:-$(docker ps --filter name=postgres --format '{{.Names}}' 2>/dev/null | head -1 || true)}"
attachment_row=""
if [[ -n "$pg_container" ]]; then
  # 从库里取一条真实附件（id / 期望字节数 / 期望 sha256）。
  # 为什么要从库里取而不是构造：那样验的是「**恢复出来的那条记录**指向的文件
  # 真的还在、内容还对」—— 这正是恢复后最容易坏的一环（storagePath 对应的文件
  # 没跟着恢复、或挂载目录属主变了）。
  attachment_row="$(docker exec "$pg_container" psql -U knowtrace_workflow -d knowtrace_workflow -tAF'|' \
    -c "select id, byte_size, sha256 from evidence_attachments order by created_at desc limit 1" 2>/dev/null || true)"
else
  warn "找不到 postgres 容器，无法从库里取附件样本"
fi

if [[ -z "$attachment_row" ]]; then
  warn "库里没有 evidence_attachments 记录 —— **没有真实附件可下载**"
  log
  log "      这同样不是恢复失败，是「业务数据尚未就位」。"
  log "      判据 3（下载真实附件）在数据到位前**无法验证**，如实记录，不假装通过。"
  log "RESULT=SKIP（前置：无真实附件）"
  exit 2
fi

att_id="${attachment_row%%|*}"
rest="${attachment_row#*|}"
att_size="${rest%%|*}"
att_sha="${rest##*|}"

if [[ ! "$att_id" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  fail "从库里取到的附件 id 不像 UUID：$att_id"
  log "RESULT=FAIL"
  exit 3
fi

blob="$workdir/attachment.bin"
blob_code="$(curl -sS -o "$blob" -w '%{http_code}' -b "$cookie_jar" \
  "$base_url/api/evidence-images/$att_id" 2>/dev/null || printf '000')"

if [[ "$blob_code" != "200" ]]; then
  fail "下载附件返回 HTTP $blob_code（期望 200）"
  log "      附件 id：$att_id"
  log "      排查：requireAttachmentReadAccess 是否因权限拒绝、storagePath 指向的文件是否存在"
  log "RESULT=FAIL"
  exit 1
fi

actual_size="$(stat -c %s "$blob" 2>/dev/null || printf '?')"
actual_sha="$(sha256sum "$blob" | awk '{print $1}')"

if [[ "$actual_size" != "$att_size" ]]; then
  fail "字节数不一致：期望 $att_size，实际 $actual_size"
  log "RESULT=FAIL"
  exit 1
fi
if [[ "$actual_sha" != "$att_sha" ]]; then
  fail "sha256 不一致：期望 $att_sha，实际 $actual_sha"
  log "      ⚠ 字节数对得上但内容不对 —— 这比字节数不一致更隐蔽，必须靠 sha256 才能发现"
  log "RESULT=FAIL"
  exit 1
fi
ok "附件可下载且内容一致（$att_id，$actual_size 字节，sha256 匹配）"

# ---- 结论 -------------------------------------------------------------------
elapsed=$(( $(date -u +%s) - started_at ))
log
log "=== 结论 ==="
log "业务三步全部通过：登录 / 读记录（${captures_count} 条）/ 下载附件（内容校验一致）"
log "耗时 ${elapsed} 秒（业务级验收本身；**不是** RTO —— RTO 要含环境重建）"
log "FINISHED_AT_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log "RESULT=PASS"
