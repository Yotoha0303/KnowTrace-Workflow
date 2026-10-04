#!/usr/bin/env bash
set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_directory="$(cd -- "$script_directory/../.." && pwd -P)"
environment_file="$project_directory/.env.observability"
runtime_directory="$project_directory/runtime"

if (( EUID != 0 )); then
  exec sudo -- "$0" "$@"
fi

for command_name in openssl python3 install; do
  command -v "$command_name" >/dev/null || {
    echo "错误：缺少命令 $command_name" >&2
    exit 1
  }
done

if [[ ! -e "$environment_file" ]]; then
  umask 077
  grafana_password="$(openssl rand -hex 24)"
  metrics_token="$(openssl rand -hex 32)"
  {
    echo "GRAFANA_ADMIN_USER=admin"
    echo "GRAFANA_ADMIN_PASSWORD=$grafana_password"
    echo "METRICS_BEARER_TOKEN=$metrics_token"
    echo "PROMETHEUS_PORT=9090"
    echo "GRAFANA_PORT=3001"
    echo "ALERTMANAGER_PORT=9093"
    echo "ELASTICSEARCH_PORT=9200"
    echo "LOGSTASH_TCP_PORT=5000"
    echo "KIBANA_PORT=5601"
    echo "ALERT_EMAIL_ENABLED=false"
    echo "ALERT_SMTP_SMARTHOST=smtp.example.com:587"
    echo "ALERT_SMTP_FROM=alerts@example.com"
    echo "ALERT_SMTP_AUTH_USERNAME=alerts@example.com"
    echo "ALERT_SMTP_AUTH_PASSWORD="
    echo "ALERT_SMTP_REQUIRE_TLS=true"
    echo "ALERT_EMAIL_TO=operator@example.com"
  } >"$environment_file"
  echo "已创建 $environment_file（0600）；未输出任何密码或 token。"
fi
chmod 600 "$environment_file"

install -d -m 700 "$runtime_directory"
install -d -m 750 -o 65534 -g 65534 \
  "$runtime_directory/prometheus" \
  "$runtime_directory/alertmanager"
install -d -m 755 "$runtime_directory/node-exporter"

python3 - "$environment_file" "$runtime_directory" <<'PY'
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            value = value[1:-1]
        values[key.strip()] = value
    return values


environment_path = Path(sys.argv[1])
runtime_path = Path(sys.argv[2])
values = read_env(environment_path)

token = values.get("METRICS_BEARER_TOKEN", "").strip()
grafana_password = values.get("GRAFANA_ADMIN_PASSWORD", "").strip()
if len(token) < 32:
    raise SystemExit("METRICS_BEARER_TOKEN 必须至少 32 个字符")
if len(grafana_password) < 16:
    raise SystemExit("GRAFANA_ADMIN_PASSWORD 必须至少 16 个字符")

token_path = runtime_path / "prometheus" / "metrics.token"
token_path.write_text(token, encoding="utf-8")
os.chown(token_path, 65534, 65534)
os.chmod(token_path, 0o400)

email_enabled = values.get("ALERT_EMAIL_ENABLED", "false").lower() == "true"
receiver_name = "email" if email_enabled else "local-only"
config: dict[str, object] = {
    "global": {"resolve_timeout": "5m"},
    "route": {
        "receiver": receiver_name,
        "group_by": ["alertname", "instance"],
        "group_wait": "30s",
        "group_interval": "5m",
        "repeat_interval": "4h",
    },
    "receivers": [{"name": "local-only"}],
    "inhibit_rules": [
        {
            "source_matchers": ['severity="critical"'],
            "target_matchers": ['severity="warning"'],
            "equal": ["alertname", "instance"],
        }
    ],
}

if email_enabled:
    required = [
        "ALERT_SMTP_SMARTHOST",
        "ALERT_SMTP_FROM",
        "ALERT_EMAIL_TO",
    ]
    missing = [key for key in required if not values.get(key, "").strip()]
    if missing:
        raise SystemExit("邮件告警已启用但缺少：" + ", ".join(missing))

    smtp_smarthost = values["ALERT_SMTP_SMARTHOST"].strip()
    smtp_require_tls = values.get("ALERT_SMTP_REQUIRE_TLS", "true").lower() != "false"
    if smtp_smarthost.rsplit(":", 1)[-1] == "465" and smtp_require_tls:
        raise SystemExit(
            "Alertmanager 0.28.1 使用 465 隐式 TLS 时，"
            "ALERT_SMTP_REQUIRE_TLS 必须设为 false，以避免在已加密连接上重复请求 STARTTLS"
        )

    email_config: dict[str, object] = {
        "to": values["ALERT_EMAIL_TO"],
        "from": values["ALERT_SMTP_FROM"],
        "smarthost": smtp_smarthost,
        "send_resolved": True,
        "require_tls": smtp_require_tls,
        "headers": {"Subject": "[KnowTrace] {{ .Status | toUpper }} {{ .CommonLabels.alertname }}"},
    }
    username = values.get("ALERT_SMTP_AUTH_USERNAME", "").strip()
    password = values.get("ALERT_SMTP_AUTH_PASSWORD", "")
    if username:
        email_config["auth_username"] = username
    if password:
        email_config["auth_password"] = password
    config["global"] = {
        "resolve_timeout": "5m",
        "smtp_smarthost": smtp_smarthost,
        "smtp_from": values["ALERT_SMTP_FROM"],
        "smtp_require_tls": email_config["require_tls"],
    }
    config["receivers"] = [
        {"name": "local-only"},
        {"name": "email", "email_configs": [email_config]},
    ]

alertmanager_path = runtime_path / "alertmanager" / "alertmanager.json"
alertmanager_path.write_text(
    json.dumps(config, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
os.chown(alertmanager_path, 65534, 65534)
os.chmod(alertmanager_path, 0o400)
print("Alertmanager 配置已渲染；邮件模式=" + ("enabled" if email_enabled else "local-only"))
PY

"$script_directory/write-backup-metrics.sh"
