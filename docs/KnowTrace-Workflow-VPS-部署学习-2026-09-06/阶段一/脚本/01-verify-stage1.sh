#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR line=%s status=%s\n" "$LINENO" "$?" >&2' ERR

domain="${1:-knowtrace.duckdns.org}"
project_dir="${2:-/opt/knowtrace}"
failed=0

if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
  printf 'Invalid domain: %s\n' "$domain" >&2
  exit 2
fi

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1" >&2
  failed=$((failed + 1))
}

check_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

check_service() {
  local unit="$1"
  if systemctl is-active --quiet "$unit"; then
    pass "service $unit active"
  else
    fail "service $unit inactive"
  fi
}

check_http() {
  local label="$1"
  local url="$2"
  local expected_pattern="$3"
  local code
  code="$(curl --connect-timeout 5 --max-time 15 -sS -o /dev/null -w '%{http_code}' "$url" || true)"
  if [[ "$code" =~ $expected_pattern ]]; then
    pass "$label status=$code"
  else
    fail "$label status=${code:-request-failed}"
  fi
}

for name in curl docker systemctl ss openssl; do
  check_command "$name"
done

check_service docker
check_service nginx
check_service caddy

if [[ ! -f "$project_dir/compose.yaml" || ! -f "$project_dir/compose.production.yaml" ]]; then
  fail "compose files missing under $project_dir"
else
  compose=(docker compose -f "$project_dir/compose.yaml" -f "$project_dir/compose.production.yaml")
  if "${compose[@]}" config --quiet; then
    pass 'compose config valid'
  else
    fail 'compose config invalid'
  fi

  printf '\n-- compose status --\n'
  "${compose[@]}" ps -a || fail 'cannot read compose status'

  for service in app auth postgres auth-mysql auth-redis; do
    container_id="$("${compose[@]}" ps -q "$service" 2>/dev/null || true)"
    if [[ -z "$container_id" ]]; then
      fail "container missing: $service"
      continue
    fi
    status="$(docker inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null || true)"
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || true)"
    if [[ "$status" == 'running' && "$health" == 'healthy' ]]; then
      pass "container $service running/healthy"
    else
      fail "container $service status=$status health=$health"
    fi
  done
fi

check_http 'app live' 'http://127.0.0.1:3000/api/health/live' '^[23][0-9][0-9]$'
check_http 'app ready' 'http://127.0.0.1:3000/api/health/ready' '^[23][0-9][0-9]$'
check_http 'auth live' 'http://127.0.0.1:8082/livez' '^[23][0-9][0-9]$'
check_http 'auth ready' 'http://127.0.0.1:8082/readyz' '^[23][0-9][0-9]$'
check_http 'nginx health' 'http://127.0.0.1:8080/nginx-health' '^200$'
check_http 'nginx to app' 'http://127.0.0.1:8080/api/health/ready' '^[23][0-9][0-9]$'
check_http 'public HTTP redirect' "http://$domain/login" '^30[1278]$'
check_http 'public HTTPS login' "https://$domain/login" '^[23][0-9][0-9]$'
check_http 'public HTTPS ready' "https://$domain/api/health/ready" '^[23][0-9][0-9]$'

printf '\n-- listening ports --\n'
ss -lntp | grep -E ':(80|443|3000|8080|8082|15432)\b' || true

printf '\n-- certificate --\n'
if certificate="$(echo | openssl s_client -connect "$domain:443" -servername "$domain" 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null)"; then
  printf '%s\n' "$certificate"
  pass 'TLS certificate readable'
else
  fail 'TLS certificate unavailable'
fi

printf '\n-- summary --\n'
if (( failed == 0 )); then
  printf 'PASS all stage-one checks\n'
  exit 0
fi

printf 'FAIL count=%s\n' "$failed" >&2
exit 1

