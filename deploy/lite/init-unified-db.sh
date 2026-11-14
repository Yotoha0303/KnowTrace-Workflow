#!/bin/sh
# KnowTrace 交付轻量版统一数据库初始化脚本 (deploy/lite/init-unified-db.sh)
# 作用：在单一 PostgreSQL 实例内同时初始化业务库 (knowtrace_workflow) 与认证库 (go_user_system)
set -eu

: "${POSTGRES_USER:?POSTGRES_USER must be set}"
: "${APP_DB_PASSWORD:-knowtrace}"
: "${AUTH_DB_PASSWORD:-knowtrace_auth_123}"

echo ">>> [Lite-Init] Initializing unified databases inside single PostgreSQL instance..."

# 1. 初始化业务库 (knowtrace_workflow)
psql --username "$POSTGRES_USER" --dbname postgres \
     --set=ON_ERROR_STOP=1 --set=pwd="$APP_DB_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'knowtrace_workflow') THEN
    CREATE ROLE knowtrace_workflow LOGIN;
  END IF;
END
$$;
SELECT format('ALTER ROLE knowtrace_workflow PASSWORD %L', :'pwd') \gexec
SELECT 'CREATE DATABASE knowtrace_workflow OWNER knowtrace_workflow'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'knowtrace_workflow') \gexec
SQL

# 2. 初始化认证库 (go_user_system)
psql --username "$POSTGRES_USER" --dbname postgres \
     --set=ON_ERROR_STOP=1 --set=pwd="$AUTH_DB_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'go_user_system') THEN
    CREATE ROLE go_user_system LOGIN;
  END IF;
END
$$;
SELECT format('ALTER ROLE go_user_system PASSWORD %L', :'pwd') \gexec
SELECT 'CREATE DATABASE go_user_system OWNER go_user_system'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'go_user_system') \gexec
SQL

echo ">>> [Lite-Init] Databases 'knowtrace_workflow' and 'go_user_system' initialized successfully."
