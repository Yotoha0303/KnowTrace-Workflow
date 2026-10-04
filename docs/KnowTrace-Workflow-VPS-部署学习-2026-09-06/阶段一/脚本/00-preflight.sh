#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR line=%s status=%s\n" "$LINENO" "$?" >&2' ERR

domain="${1:-knowtrace.duckdns.org}"
project_dir="${2:-/opt/knowtrace}"

if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
  printf 'Invalid domain: %s\n' "$domain" >&2
  exit 2
fi

section() {
  printf '\n== %s ==\n' "$1"
}

show_command() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    printf 'FOUND   %-12s %s\n' "$name" "$(command -v "$name")"
  else
    printf 'MISSING %-12s\n' "$name"
  fi
}

section 'identity'
printf 'user=%s\n' "$(id -un)"
printf 'uid=%s\n' "$(id -u)"
printf 'host=%s\n' "$(hostname)"
printf 'shell=%s\n' "${SHELL:-unknown}"

section 'operating system'
if [[ -r /etc/os-release ]]; then
  grep -E '^(PRETTY_NAME|VERSION_ID|VERSION_CODENAME)=' /etc/os-release
fi
uname -srmo

section 'resources'
free -h
df -hT /
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS

section 'network'
ip -brief address
ip route
printf 'dns domain=%s\n' "$domain"
if command -v dig >/dev/null 2>&1; then
  dig +short "$domain" A || true
else
  getent ahostsv4 "$domain" || true
fi
ss -lntup || true

section 'firewall'
if command -v ufw >/dev/null 2>&1; then
  ufw status verbose || true
else
  printf 'MISSING ufw\n'
fi

section 'required commands'
for name in git curl openssl docker nginx caddy jq; do
  show_command "$name"
done

section 'services'
for unit in ssh docker nginx caddy; do
  if systemctl list-unit-files "$unit.service" --no-legend 2>/dev/null | grep -q "$unit.service"; then
    printf '%-8s active=%s enabled=%s\n' \
      "$unit" \
      "$(systemctl is-active "$unit" 2>/dev/null || true)" \
      "$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  else
    printf '%-8s not-installed\n' "$unit"
  fi
done

section 'project'
if [[ -d "$project_dir/.git" ]]; then
  printf 'project=%s\n' "$project_dir"
  git -C "$project_dir" status --short --branch
  printf 'head=%s\n' "$(git -C "$project_dir" rev-parse HEAD)"
else
  printf 'project-not-cloned=%s\n' "$project_dir"
fi

section 'result'
printf 'Preflight completed. This script made no changes.\n'

