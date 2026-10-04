#!/usr/bin/env bash
set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_directory="$(cd -- "$script_directory/../.." && pwd -P)"
source_path="$project_directory/deploy/nginx/knowtrace-vps.conf"
target_path="/etc/nginx/sites-available/knowtrace.conf"

if (( EUID != 0 )); then
  exec sudo -- "$0" "$@"
fi

[[ -f "$source_path" ]] || {
  echo "错误：缺少 $source_path" >&2
  exit 1
}
[[ -f "$target_path" ]] || {
  echo "错误：现有 Nginx 站点不存在：$target_path" >&2
  exit 1
}

if cmp -s -- "$source_path" "$target_path"; then
  echo "Nginx 配置已是目标版本。"
  nginx -t
  exit 0
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_directory="/root/knowtrace-ops/backups/${timestamp}-stage3-nginx"
install -d -m 700 "$backup_directory"
cp -a -- "$target_path" "$backup_directory/knowtrace.conf"
sha256sum "$backup_directory/knowtrace.conf" >"$backup_directory/knowtrace.conf.sha256"

install -m 644 -- "$source_path" "$target_path"
if ! nginx -t; then
  cp -a -- "$backup_directory/knowtrace.conf" "$target_path"
  nginx -t
  echo "错误：新配置检查失败，已恢复原配置。" >&2
  exit 1
fi

systemctl reload nginx
if ! curl -fsS http://127.0.0.1:8080/api/health/ready >/dev/null; then
  cp -a -- "$backup_directory/knowtrace.conf" "$target_path"
  nginx -t
  systemctl reload nginx
  echo "错误：新配置下 ready 失败，已恢复原配置。" >&2
  exit 1
fi
metrics_status="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/api/metrics)"
if [[ "$metrics_status" != "404" ]]; then
  cp -a -- "$backup_directory/knowtrace.conf" "$target_path"
  nginx -t
  systemctl reload nginx
  echo "错误：公网代理层的 metrics 状态不是 404，已恢复原配置：$metrics_status" >&2
  exit 1
fi

echo "Nginx 已安全重载；备份目录：$backup_directory"
