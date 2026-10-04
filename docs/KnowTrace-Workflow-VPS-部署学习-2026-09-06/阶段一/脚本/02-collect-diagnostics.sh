#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR line=%s status=%s\n" "$LINENO" "$?" >&2' ERR

domain="${1:-knowtrace.duckdns.org}"
project_dir="${2:-/opt/knowtrace}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
report_dir="/tmp/knowtrace-diagnostics-$timestamp"
report_file="$report_dir/report.txt"

if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
  printf 'Invalid domain: %s\n' "$domain" >&2
  exit 2
fi

umask 077
mkdir -p "$report_dir"

section() {
  printf '\n== %s ==\n' "$1" >>"$report_file"
}

capture() {
  local label="$1"
  shift
  section "$label"
  "$@" >>"$report_file" 2>&1 || printf 'command failed status=%s\n' "$?" >>"$report_file"
}

printf 'KnowTrace-Workflow diagnostic report\ncreated_utc=%s\ndomain=%s\nproject_dir=%s\n' \
  "$timestamp" "$domain" "$project_dir" >"$report_file"

capture 'identity' id
capture 'operating system' hostnamectl
capture 'kernel' uname -a
capture 'memory' free -h
capture 'disk' df -hT
capture 'block devices' lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
capture 'listening ports' ss -lntup
capture 'failed services' systemctl --failed --no-pager
capture 'docker service' systemctl status docker --no-pager
capture 'nginx service' systemctl status nginx --no-pager
capture 'caddy service' systemctl status caddy --no-pager
capture 'caddy journal' journalctl -u caddy --since '-30 minutes' --no-pager
capture 'nginx error log' tail -n 200 /var/log/nginx/knowtrace.error.log

section 'dns'
if command -v dig >/dev/null 2>&1; then
  dig +short "$domain" A >>"$report_file" 2>&1 || true
  dig @1.1.1.1 +short "$domain" A >>"$report_file" 2>&1 || true
else
  getent ahostsv4 "$domain" >>"$report_file" 2>&1 || true
fi

section 'health endpoints'
for url in \
  'http://127.0.0.1:3000/api/health/live' \
  'http://127.0.0.1:3000/api/health/ready' \
  'http://127.0.0.1:8082/livez' \
  'http://127.0.0.1:8082/readyz' \
  'http://127.0.0.1:8080/nginx-health' \
  "https://$domain/api/health/ready"; do
  code="$(curl --connect-timeout 5 --max-time 15 -sS -o /dev/null -w '%{http_code}' "$url" || true)"
  printf '%s status=%s\n' "$url" "${code:-request-failed}" >>"$report_file"
done

if [[ -d "$project_dir/.git" ]]; then
  capture 'git status' git -C "$project_dir" status --short --branch
  capture 'git head' git -C "$project_dir" log -1 --oneline --decorate
fi

if [[ -f "$project_dir/compose.yaml" && -f "$project_dir/compose.production.yaml" ]]; then
  compose=(docker compose -f "$project_dir/compose.yaml" -f "$project_dir/compose.production.yaml")
  capture 'compose status' "${compose[@]}" ps -a
  capture 'compose app/auth logs' "${compose[@]}" logs --since=30m --tail=300 app auth
  capture 'compose database logs' "${compose[@]}" logs --since=30m --tail=200 postgres auth-mysql auth-redis
fi

chmod 0600 "$report_file"
printf 'Created private report: %s\n' "$report_file"
printf 'The script does not intentionally read .env, database rows or access logs.\n'
printf 'Container/error logs can still contain unexpected context; review and redact hostnames, IP addresses, Cookies, Tokens and business data before sharing.\n'
