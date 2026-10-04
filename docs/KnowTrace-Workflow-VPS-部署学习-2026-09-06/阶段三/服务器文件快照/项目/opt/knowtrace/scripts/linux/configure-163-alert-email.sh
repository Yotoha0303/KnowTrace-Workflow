#!/usr/bin/env bash
set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_directory="$(cd -- "$script_directory/../.." && pwd -P)"
environment_file="$project_directory/.env.observability"

if (( EUID != 0 )); then
  exec sudo -- "$0" "$@"
fi

if [[ ! -t 0 ]]; then
  echo "错误：必须在交互终端运行，禁止通过命令参数或管道传入授权码。" >&2
  exit 1
fi
[[ -f "$environment_file" ]] || {
  echo "错误：缺少 $environment_file；先运行 scripts/linux/init-observability-env.sh。" >&2
  exit 1
}
for command_name in python3 install date; do
  command -v "$command_name" >/dev/null || {
    echo "错误：缺少命令 $command_name" >&2
    exit 1
  }
done

read -r -p "163 发件邮箱（完整地址）: " sender_address
read -r -p "收件邮箱（直接回车则与发件邮箱相同）: " recipient_address
recipient_address="${recipient_address:-$sender_address}"
read -r -s -p "163 SMTP 新授权码（隐藏输入）: " smtp_password
echo
trap 'unset smtp_password' EXIT

backup_directory="/root/knowtrace-ops/backups/$(date -u +%Y%m%dT%H%M%SZ)-pre-smtp-email"
install -d -m 700 "$backup_directory"
install -m 600 "$environment_file" "$backup_directory/.env.observability"

python3 - "$environment_file" "$sender_address" "$recipient_address" \
  3<<<"$smtp_password" <<'PY'
from __future__ import annotations

import os
import re
import sys
from pathlib import Path


environment_path = Path(sys.argv[1])
sender = sys.argv[2].strip()
recipient = sys.argv[3].strip()
with os.fdopen(3, encoding="utf-8") as password_stream:
    password = password_stream.read().removesuffix("\n")

email_pattern = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
for field_name, address in (("发件邮箱", sender), ("收件邮箱", recipient)):
    if not email_pattern.fullmatch(address):
        raise SystemExit(f"{field_name}格式无效")
if not re.fullmatch(r"[A-Za-z0-9]+", password):
    raise SystemExit("163 SMTP 授权码必须为非空英文字母或数字，且不能包含空白")

updates = {
    "ALERT_EMAIL_ENABLED": "true",
    "ALERT_SMTP_SMARTHOST": "smtp.163.com:465",
    "ALERT_SMTP_FROM": sender,
    "ALERT_SMTP_AUTH_USERNAME": sender,
    "ALERT_SMTP_AUTH_PASSWORD": password,
    "ALERT_SMTP_REQUIRE_TLS": "false",
    "ALERT_EMAIL_TO": recipient,
}

lines = environment_path.read_text(encoding="utf-8").splitlines()
seen: set[str] = set()
result: list[str] = []
for line in lines:
    if "=" not in line or line.lstrip().startswith("#"):
        result.append(line)
        continue
    key = line.split("=", 1)[0].strip()
    if key in updates:
        result.append(f"{key}={updates[key]}")
        seen.add(key)
    else:
        result.append(line)
for key, value in updates.items():
    if key not in seen:
        result.append(f"{key}={value}")

temporary_path = environment_path.with_name(
    f"{environment_path.name}.tmp.{os.getpid()}"
)
try:
    descriptor = os.open(temporary_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
        output.write("\n".join(result) + "\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary_path, environment_path)
    os.chmod(environment_path, 0o600)
finally:
    temporary_path.unlink(missing_ok=True)

print("163 SMTP 配置已原子写入；授权码未输出。")
PY

unset smtp_password
trap - EXIT
echo "变更前备份：$backup_directory/.env.observability（0600）"
echo "下一步：渲染并校验配置后，仅重建 Alertmanager。"
