#!/usr/bin/env bash
set -Eeuo pipefail

scenario="${1:-blackbox}"
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_directory="$(cd -- "$script_directory/../.." && pwd -P)"

if [[ "$scenario" != "blackbox" ]]; then
  echo "用法：$0 blackbox" >&2
  exit 2
fi
if (( EUID != 0 )); then
  exec sudo -- "$0" "$@"
fi

"$script_directory/init-observability-env.sh" >/dev/null
export KNOWTRACE_APP_REVISION="$(git -C "$project_directory" rev-parse HEAD 2>/dev/null || echo unknown)"
compose=(docker compose --project-directory "$project_directory" --env-file "$project_directory/.env" --env-file "$project_directory/.env.observability" -f "$project_directory/compose.yaml" -f "$project_directory/compose.production.yaml" -f "$project_directory/compose.observability.yaml")

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
log_path="/var/log/knowtrace-observability-drill-$timestamp.log"
touch "$log_path"
chmod 600 "$log_path"
exec > >(tee "$log_path") 2>&1

# 邮件投递基线（供编排器在演练后判定「计数必须 +1」）。
# 为什么基线在这里取、而断言不在这里做，见下方「2.5 邮件送达」的说明。
drill_baseline_file="${log_path%.log}.email-baseline"
export DRILL_METRIC_BASELINE_FILE="$drill_baseline_file"

restore_blackbox() {
  "${compose[@]}" start blackbox-exporter >/dev/null 2>&1 || true
}
trap restore_blackbox EXIT

echo "SCENARIO=blackbox-exporter-stop"
echo "STARTED_AT_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 "$script_directory/verify-observability.py" --core

echo "ACTION=stop blackbox-exporter"
"${compose[@]}" stop blackbox-exporter

python3 - <<'PY'
from __future__ import annotations

import json
import time
import urllib.request


def get(url: str):
    with urllib.request.urlopen(url, timeout=5) as response:
        return json.load(response)


deadline = time.time() + 150
while time.time() < deadline:
    payload = get("http://127.0.0.1:9090/api/v1/alerts")
    alerts = payload.get("data", {}).get("alerts", [])
    matches = [
        alert
        for alert in alerts
        if alert.get("labels", {}).get("alertname") == "KnowTraceMetricsTargetDown"
        and alert.get("labels", {}).get("job") == "blackbox-exporter"
        and alert.get("state") == "firing"
    ]
    if matches:
        print("PASS Prometheus alert firing: KnowTraceMetricsTargetDown job=blackbox-exporter")
        break
    time.sleep(5)
else:
    raise SystemExit("FAIL Prometheus alert did not reach firing state")

deadline = time.time() + 60
while time.time() < deadline:
    alerts = get("http://127.0.0.1:9093/api/v2/alerts")
    if any(
        alert.get("labels", {}).get("alertname") == "KnowTraceMetricsTargetDown"
        and alert.get("labels", {}).get("job") == "blackbox-exporter"
        for alert in alerts
    ):
        print("PASS Alertmanager received KnowTraceMetricsTargetDown")
        break
    time.sleep(3)
else:
    raise SystemExit("FAIL Alertmanager did not receive firing alert")

# ---------------------------------------------------------------------------
# 邮件投递基线
# ---------------------------------------------------------------------------
# 这里**只取基线，不断言**。原因（2026-10-04 实测）：
#
#   AM 的 `group_wait` 是 30s：告警进入 AM 后要等满 30 秒才会首次投递。
#   而演练的验证循环是 3 秒一轮——一旦确认 AM 收到就立刻 `start blackbox-exporter`，
#   告警随即 resolve，**整个组在 group_wait 到期前就被清掉了，AM 一封都不发**。
#   （实测：15:57:40 firing → 15:58:05 已 resolve，投递本应在 15:58:10。）
#
# 所以「演练脚本自己断言收到邮件」在结构上不可能成立——除非把演练时长
# 硬撑到 group_wait 之后，而那会让一次演练的停机时间从秒级变成分钟级。
# 正解是把「有没有发出去」交给**编排器**在演练结束后判定：
# 它会读下面这个基线文件，再查 Prometheus 的 `notifications_total{integration="email"}`。
import os

baseline_path = os.environ.get("DRILL_METRIC_BASELINE_FILE", "")
if baseline_path:
    email_sent = 0
    try:
        with urllib.request.urlopen("http://127.0.0.1:9093/metrics", timeout=5) as response:
            for raw in response.read().decode("utf-8", "replace").splitlines():
                if raw.startswith('alertmanager_notifications_total{integration="email"}'):
                    email_sent = int(float(raw.rsplit(" ", 1)[1]))
    except Exception as error:  # noqa: BLE001 —— 基线取不到不应让演练失败
        print(f"WARN could not read email notification baseline: {error}")
    with open(baseline_path, "w", encoding="utf-8") as handle:
        handle.write(f"EMAIL_NOTIFICATIONS_BASELINE={email_sent}\n")
    print(f"EMAIL_NOTIFICATIONS_BASELINE={email_sent}")
PY

# ---- 保持故障注入，让告警真正走完投递 ----
# 默认 0 = 保持原行为（AM 收到就恢复，最快的演练）。
# 要验证**邮件送达**必须设成 > AM 的 `group_wait`（本栈 30s）：
# 否则告警会在 group_wait 到期前就被 resolve，AM 把整组丢掉、一封都不发。
# 2026-10-04 实测：15:57:40 firing → 15:58:05 已 resolve，而投递本应在 15:58:10。
hold_seconds="${DRILL_HOLD_SECONDS:-0}"
if [[ "$hold_seconds" =~ ^[0-9]+$ ]] && (( hold_seconds > 0 )); then
  echo "HOLDING_FAULT_SECONDS=$hold_seconds"
  sleep "$hold_seconds"
  echo "HOLD_DONE_AT_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
else
  echo "HOLDING_FAULT_SECONDS=0（跳过保持；本次不验证邮件投递）"
fi

echo "ACTION=start blackbox-exporter"
"${compose[@]}" start blackbox-exporter
trap - EXIT

sleep 20
python3 "$script_directory/verify-observability.py" --core

python3 - <<'PY'
from __future__ import annotations

import json
import time
import urllib.request

deadline = time.time() + 120
while time.time() < deadline:
    with urllib.request.urlopen("http://127.0.0.1:9090/api/v1/alerts", timeout=5) as response:
        payload = json.load(response)
    active = [
        alert
        for alert in payload.get("data", {}).get("alerts", [])
        if alert.get("labels", {}).get("alertname") == "KnowTraceMetricsTargetDown"
        and alert.get("labels", {}).get("job") == "blackbox-exporter"
        and alert.get("state") in {"pending", "firing"}
    ]
    if not active:
        print("PASS Prometheus alert recovered and cleared")
        break
    time.sleep(5)
else:
    raise SystemExit("FAIL Prometheus alert did not clear after recovery")
PY

echo "RESULT=PASS"
echo "FINISHED_AT_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "LOG_PATH=$log_path"
