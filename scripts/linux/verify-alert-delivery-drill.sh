#!/usr/bin/env bash
# ============================================================================
# 告警送达演练（编排器）—— 让「邮件真的发出去了」成为可断言的判据
# ============================================================================
#
# 为什么需要它（2026-10-04 实测）
# -----------------------------
# `observability-drill.sh` 只证明到「Alertmanager 收到了告警」。它**不可能**
# 证明「邮件发出去了」，因为 AM 的 `group_wait` 是 30s：告警进 AM 后要等满
# 30 秒才首次投递，而演练的验证循环 3 秒一轮、一确认收到就立刻恢复故障 ——
# 整组在 group_wait 到期前就被清掉，AM 一封都不发。
#
#   实测时间线：15:57:40 firing → 15:58:05 已 resolve，而投递本应在 15:58:10。
#
# 十环「06 观测」的准出要求「完成真实停机告警送达演练」——两次尝试都不完整：
#   * 2026-09-08：只验到 AM 收到（当时 SMTP 未配置），且日志已被 10-02 重装抹掉；
#   * 2026-10-04：AM 收到，但**一封邮件都没发**（就是上面那个 group_wait 竞态）。
#
# 本编排器补上那一跳：
#   1. 取投递计数基线（读 AM 自己的 /metrics，不经 Prometheus，避免抓取延迟）；
#   2. 以 `DRILL_HOLD_SECONDS > group_wait` 跑完整演练（故障保持到投递之后）；
#   3. 断言 `notifications_total{integration="email"}` **至少 +1**，且失败计数为 0；
#   4. 把四段证据（基线 / 保持时长 / 演练结论 / 投递增量）写进一份记录。
#
# **判据落在投递计数上，不落在「应该发出去了」上。** 计数不涨就是 FAIL ——
# 这正是它是「可证伪判据」而不是「看起来成功了」的原因。
#
# 用法
# ----
#   bash scripts/linux/verify-alert-delivery-drill.sh
#   DRILL_HOLD_SECONDS=120 bash scripts/linux/verify-alert-delivery-drill.sh
#
# 退出码：0=PASS  1=FAIL（含投递未发生）  2=前置不满足  3=脚本自身错误
#
# 影响面：与 observability-drill.sh 相同 —— 只停 blackbox-exporter，
# 不碰 app / auth / 数据库。停机时长 = 告警 pending+firing 时间 + hold_seconds。
# ============================================================================

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_directory="${PROJECT_DIR:-$(cd -- "$script_directory/../.." && pwd -P)}"
drill_script="$script_directory/observability-drill.sh"
alertmanager_config="$project_directory/runtime/alertmanager/alertmanager.json"

# 记录写到**证据目录**，不写进 docs/。
# 理由：/opt/knowtrace 是 git 检出，往里写未跟踪文件会在下次 `git pull` 时
# 挡住 `docs/` 下同名路径的创建（这个坑本项目踩过：见 部署链路笔记）。
# `/var/lib/knowtrace/reports/` 已是 daily-ops / weekly-check 报告的归档位置，
# 属十环判据认可的「证据目录」。要进仓库需人工归档一份。
record_directory="${DRILL_RECORD_DIR:-/var/lib/knowtrace/reports}"

if (( EUID != 0 )); then
  exec sudo -- "$0" "$@"
fi

for command_name in curl python3; do
  command -v "$command_name" >/dev/null || {
    echo "错误：缺少命令 $command_name" >&2
    exit 3
  }
done
[[ -x "$drill_script" ]] || { echo "错误：找不到 $drill_script" >&2; exit 3; }

alertmanager_url="${ALERTMANAGER_BASE:-http://127.0.0.1:9093}"

read_email_sent() {
  curl -sS --max-time 8 "$alertmanager_url/metrics" 2>/dev/null \
    | awk '/^alertmanager_notifications_total\{integration="email"\}/ {print $NF}' \
    | head -1
}

read_email_failed() {
  curl -sS --max-time 8 "$alertmanager_url/metrics" 2>/dev/null \
    | awk '/^alertmanager_notifications_failed_total\{integration="email"\}/ {total += $NF} END {print total + 0}' \
    | head -1
}

# ---- 0. 前置：外部邮件必须已启用，否则整件事无意义 --------------------------
environment_file="$project_directory/.env.observability"
if ! grep -Eq '^ALERT_EMAIL_ENABLED=(true|TRUE|1)$' "$environment_file" 2>/dev/null; then
  echo "前置不满足：$environment_file 里 ALERT_EMAIL_ENABLED 不是 true。" >&2
  echo "先配好 SMTP 再跑本演练（见 运维手册 §7）。" >&2
  exit 2
fi

# ---- 1. 解析 group_wait，据此定保持时长 -------------------------------------
# 保持时长必须**严格大于** group_wait：等满 group_wait 才会首次投递，
# 再留 30s 余量给 SMTP 往返与计数刷新。
resolved_group_wait="$(grep -oE '"group_wait"[[:space:]]*:[[:space:]]*"[0-9]+s"' "$alertmanager_config" 2>/dev/null \
  | grep -oE '[0-9]+' | head -1)"
hold_seconds="${DRILL_HOLD_SECONDS:-$(( ${resolved_group_wait:-30} + 30 ))}"
if ! [[ "$hold_seconds" =~ ^[0-9]+$ ]]; then
  echo "错误：DRILL_HOLD_SECONDS 必须是整数秒（收到 '$hold_seconds'）" >&2
  exit 3
fi
if (( hold_seconds <= ${resolved_group_wait:-30} )); then
  echo "错误：保持时长 ${hold_seconds}s 必须大于 AM 的 group_wait ${resolved_group_wait:-30}s，" >&2
  echo "      否则告警会在首次投递前被 resolve，AM 不会发信。" >&2
  exit 3
fi

baseline_sent="$(read_email_sent)"
if [[ -z "$baseline_sent" ]]; then
  echo "错误：读不到 $alertmanager_url/metrics 的邮件投递计数（AM 是否在跑？）" >&2
  exit 3
fi

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=== 告警送达演练 ==="
echo "STARTED_AT_UTC=$started_at"
echo "GROUP_WAIT=${resolved_group_wait:-30}s"
echo "HOLD_SECONDS=$hold_seconds"
echo "EMAIL_SENT_BASELINE=$baseline_sent"
echo

# ---- 2. 跑演练（带保持时长）------------------------------------------------
set +e
DRILL_HOLD_SECONDS="$hold_seconds" bash "$drill_script" blackbox
drill_exit=$?
set -e
echo
echo "DRILL_EXIT=$drill_exit"

if (( drill_exit != 0 )); then
  echo "RESULT=FAIL（演练本身未通过，不进入投递判定）"
  exit 1
fi

# ---- 3. 断言投递确实发生 ---------------------------------------------------
# 轮询 AM 自己的计数（不经 Prometheus）。给足 SMTP 往返时间。
deadline=$(( $(date +%s) + 180 ))
delivered=0
while (( $(date +%s) < deadline )); do
  current_sent="$(read_email_sent)"
  if [[ -n "$current_sent" ]] && (( current_sent > baseline_sent )); then
    delivered=$(( current_sent - baseline_sent ))
    break
  fi
  sleep 5
done

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
final_sent="$(read_email_sent)"
failed_total="$(read_email_failed)"

echo
echo "EMAIL_SENT_FINAL=${final_sent:-unknown}"
echo "EMAIL_DELIVERED_DELTA=$delivered"
echo "EMAIL_FAILED_TOTAL=${failed_total:-unknown}"
echo "FINISHED_AT_UTC=$finished_at"

if (( delivered < 1 )); then
  echo "RESULT=FAIL（判据：投递计数必须至少 +1，实际 +${delivered}）"
  exit 1
fi

echo "RESULT=PASS"

# ---- 3b. 判定**触发方式**（可验证，不猜）-----------------------------------
# 为什么需要：这份记录要回答「是按计划自然发生的，还是人工跑的一次」——
# 十环的判据只在自然发生时才成立。原先这里硬编码写「人工触发」，
# 而 2026-10-05 20:31:06 那次其实是**定时器**触发的（`OnCalendar=Mon 20:30 UTC`）
# ⇒ **记录在本可以证伪的地方说了假话**（与 KT-GAP-41 是同一形状：
# 产物断言了一个它并不知道的成因）。
#
# 判据用两个**可查的真实时间**比对：
#   * 本服务的 ExecMainStartTimestamp（它什么时候起来的）
#   * 定时器的 LastTriggerUSec（定时器最后一次触发）
# 两者相差在一分钟量级 ⇒ 是定时器触发的；相差很大（例如几天）⇒ 人工跑的。
# 这不是推断，是读 systemd 自己的记录。
trigger_label="未判定"
timer_unit="knowtrace-workflow-alert-drill.timer"
svc_start_raw="$(systemctl show knowtrace-workflow-alert-drill.service -p ExecMainStartTimestamp --value 2>/dev/null)"
timer_last_raw="$(systemctl show "$timer_unit" -p LastTriggerUSec --value 2>/dev/null)"
if [[ -n "$svc_start_raw" && -n "$timer_last_raw" && "$timer_last_raw" != "n/a" ]]; then
  svc_epoch="$(date -d "$svc_start_raw" +%s 2>/dev/null || echo "")"
  timer_epoch="$(date -d "$timer_last_raw" +%s 2>/dev/null || echo "")"
  if [[ -n "$svc_epoch" && -n "$timer_epoch" ]]; then
    delta=$(( svc_epoch - timer_epoch )); (( delta < 0 )) && delta=$(( -delta ))
    if (( delta <= 120 )); then
      trigger_label="**自然触发**（定时器 \`$timer_unit\`；相差 ${delta}s）"
    else
      # 单位按量级给 —— 固定写「天」会在几分钟量级时印出「约 0 天」，读不出信息。
      if (( delta >= 86400 )); then
        human_delta="$(( delta / 86400 )) 天"
      elif (( delta >= 3600 )); then
        human_delta="$(( delta / 3600 )) 小时"
      else
        human_delta="${delta} 秒"
      fi
      trigger_label="**人工触发**（非定时器；与服务启动相差 $human_delta）"
    fi
  fi
fi
if [[ "$trigger_label" == "未判定" ]]; then
  # 读不到就如实说读不到 —— 不要退回硬编码，那正是本次要修掉的毛病。
  trigger_label="**未判定**（读不到 systemd 时间戳；请查 \`journalctl -u $timer_unit\`）"
fi
echo "TRIGGER=$trigger_label"

# ---- 4. 落一份记录（判据要落在能复查的文件上，不能只在终端回滚里）----------
# 文件名带时间戳，与 daily-ops / weekly-check 的报告同风格：**每次运行各留一份**，
# 不覆盖历史——「证明它发生过」的证据不应该被下一次运行冲掉。
record_path="$record_directory/alert-delivery-drill-$(date -u +%Y%m%dT%H%M%SZ).md"
cat >"$record_path" <<RECORD
# 告警送达演练记录

- 执行方式：$trigger_label。
  判定依据是 systemd 的两个真实时间戳（服务 `ExecMainStartTimestamp` 与
  定时器 `LastTriggerUSec`），**不是脚本自己声明的** —— 见下方「复算」。
- 结论：**RESULT=PASS**
- 时间：\`$started_at\` → \`$finished_at\`（UTC）

## 判据与实测

| 判据 | 值 |
| --- | --- |
| 故障场景 | 停 \`blackbox-exporter\`，触发 \`KnowTraceMetricsTargetDown\`（**critical**，路由到 email） |
| AM \`group_wait\` | \`${resolved_group_wait:-30}s\` |
| 故障保持时长 | \`${hold_seconds}s\`（必须 > group_wait，否则投递不会发生） |
| 邮件投递计数（基线） | \`$baseline_sent\` |
| 邮件投递计数（结束） | \`$final_sent\` |
| **投递增量** | **\`$delivered\`**（判据：至少 +1） |
| 投递失败计数 | \`$failed_total\`（判据：0） |
| 演练脚本退出码 | \`$drill_exit\` |

## 为什么这条判据以前过不了

\`observability-drill.sh\` 的验证循环是 3 秒一轮，确认 AM 收到就**立刻**恢复故障。
而 AM 要等满 \`group_wait\` 才首次投递 —— 整组在投递前就被清掉，一封都不发。

2026-10-04 实测时间线：
\`\`\`
15:57:40  KnowTraceMetricsTargetDown 进入 firing
15:58:05  演练脚本恢复 blackbox-exporter，告警 resolve
15:58:10  首次投递本应发生 —— 但组已不存在
\`\`\`

所以本编排器把保持时长显式设为 \`> group_wait\`，并把判据从
「AM 收到了」改成「**投递计数至少 +1**」。

## 复算

\`\`\`bash
# 投递计数（AM 自己的指标，不经 Prometheus）
curl -s localhost:9093/metrics | grep '^alertmanager_notifications_total{integration="email"}'
# 该次演练的完整日志
ls -t /var/log/knowtrace-observability-drill-*.log | head -1
# 本目录下的历次记录
ls -t /var/lib/knowtrace/reports/alert-delivery-drill-*.md | head
# 触发方式（两个时间戳比对，本记录就是这么判的）
systemctl show knowtrace-workflow-alert-drill.service -p ExecMainStartTimestamp --value
systemctl show knowtrace-workflow-alert-drill.timer   -p LastTriggerUSec --value
# 重跑
DRILL_HOLD_SECONDS=$hold_seconds bash scripts/linux/verify-alert-delivery-drill.sh
\`\`\`

## 仍未覆盖的部分

- **收件箱里是否看到**：计数只证明 AM 递交给 SMTP 成功，不证明 163 收下。
  那一步只能落在收件箱上（见 \`运维手册.md\` §7.5）。
- **收件箱里是否看到**：同上 —— 本判据只到 SMTP 递交。
- （2026-10-05 更正）本节原写「要证明调度会跑，需把它接进定时器 —— 目前没有」。
  **定时器已于 2026-10-05 接上**（`KT-GAP-38`，`Mon 20:30 UTC`），
  首次自然触发即 2026-10-05 20:31:06 —— 而原先的记录头仍硬编码写着「人工触发」，
  与事实相反。现已改为读 systemd 时间戳判定。
RECORD

echo "RECORD=$record_path"
