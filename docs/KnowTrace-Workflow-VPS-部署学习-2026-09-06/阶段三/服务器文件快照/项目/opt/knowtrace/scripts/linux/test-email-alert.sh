#!/usr/bin/env bash
set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_directory="$(cd -- "$script_directory/../.." && pwd -P)"
environment_file="$project_directory/.env.observability"

if (( EUID != 0 )); then
  exec sudo -- "$0" "$@"
fi
[[ -f "$environment_file" ]] || {
  echo "错误：缺少 $environment_file" >&2
  exit 1
}
if ! grep -Eq '^ALERT_EMAIL_ENABLED=(true|TRUE|1)$' "$environment_file"; then
  echo "错误：外部邮件尚未启用。先安全填写 SMTP 配置并重新运行 init-observability-env.sh。" >&2
  exit 2
fi

event_id="email-test-$(date -u +%Y%m%dT%H%M%SZ)"
python3 - "$event_id" <<'PY'
from __future__ import annotations

import json
import sys
import urllib.request
from datetime import datetime, timedelta, timezone

event_id = sys.argv[1]
now = datetime.now(timezone.utc)
payload = [
    {
        "labels": {
            "alertname": "KnowTraceEmailDeliveryTest",
            "severity": "warning",
            "instance": event_id,
        },
        "annotations": {
            "summary": "Manual KnowTrace email delivery verification",
            "runbook": "docs/16-stage3-observability.md#email-delivery",
        },
        "startsAt": now.isoformat(),
        "endsAt": (now + timedelta(minutes=5)).isoformat(),
    }
]
request = urllib.request.Request(
    "http://127.0.0.1:9093/api/v2/alerts",
    data=json.dumps(payload).encode(),
    method="POST",
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(request, timeout=10) as response:
    if response.status not in {200, 202}:
        raise SystemExit(f"Alertmanager returned HTTP {response.status}")
print(f"TEST_ALERT_ACCEPTED={event_id}")
PY

echo "请在收件箱和垃圾邮件目录确认测试邮件；收到邮件前不得写成外部告警已验证。"
