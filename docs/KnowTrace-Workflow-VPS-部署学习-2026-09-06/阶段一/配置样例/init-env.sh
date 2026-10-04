#!/usr/bin/env bash
set -Eeuo pipefail

env_file="${1:-/opt/knowtrace/.env}"

if [[ -e "$env_file" ]]; then
  printf 'Refusing to overwrite existing environment file: %s\n' "$env_file" >&2
  exit 1
fi

umask 077
postgres_password="$(openssl rand -hex 32)"
auth_root_password="$(openssl rand -hex 32)"
auth_db_password="$(openssl rand -hex 32)"
auth_jwt_secret="$(openssl rand -hex 64)"
admin_password="$(openssl rand -hex 24)"

{
  printf 'POSTGRES_HOST_PORT=15432\n'
  printf 'POSTGRES_PASSWORD=%s\n' "$postgres_password"
  printf 'DATABASE_URL=postgres://knowtrace:%s@postgres:5432/knowtrace\n' "$postgres_password"
  printf '\n'
  printf 'AUTH_ENABLED=true\n'
  printf 'AUTH_SERVICE_URL=http://auth:8082\n'
  printf 'AUTH_REGISTRATION_ENABLED=false\n'
  printf 'AUTH_COOKIE_SECURE=true\n'
  printf 'AUTH_BACKEND_PORT=8082\n'
  printf 'AUTH_APP_ENV=production\n'
  printf 'AUTH_ACCESS_TOKEN_EXPIRE_MINUTES=15\n'
  printf 'AUTH_REFRESH_TOKEN_EXPIRE_HOURS=168\n'
  printf 'AUTH_TRUSTED_PROXIES=\n'
  printf 'AUTH_DB_ROOT_PASSWORD=%s\n' "$auth_root_password"
  printf 'AUTH_DB_PASSWORD=%s\n' "$auth_db_password"
  printf 'AUTH_JWT_SECRET=%s\n' "$auth_jwt_secret"
  printf '\n'
  printf 'KNOWTRACE_ADMIN_USERNAME=KnowTrace-Workflow\n'
  printf 'KNOWTRACE_ADMIN_PASSWORD=%s\n' "$admin_password"
  printf 'KNOWTRACE_HOST=127.0.0.1\n'
  printf '\n'
  printf 'AI_DEFAULT_PROVIDER=mock\n'
  printf 'AI_REQUEST_TIMEOUT_MS=90000\n'
  printf 'AI_MAX_INPUT_CHARS=12000\n'
  printf 'AI_RUNNING_STALE_AFTER_MS=300000\n'
  printf 'OPENAI_API_KEY=\n'
  printf 'OPENAI_MODEL=gpt-5.6-luna\n'
  printf 'OPENAI_BASE_URL=https://api.openai.com/v1\n'
  printf 'DEEPSEEK_API_KEY=\n'
  printf 'DEEPSEEK_MODEL=deepseek-v4-flash\n'
  printf 'DEEPSEEK_BASE_URL=https://api.deepseek.com\n'
} > "$env_file"

chmod 600 "$env_file"
unset postgres_password auth_root_password auth_db_password auth_jwt_secret admin_password
printf 'Created %s with mode 600; secret values were not printed.\n' "$env_file"

