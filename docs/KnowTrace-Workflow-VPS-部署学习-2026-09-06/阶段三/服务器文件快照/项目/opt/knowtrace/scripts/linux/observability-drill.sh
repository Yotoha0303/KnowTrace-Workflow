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
PY

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
