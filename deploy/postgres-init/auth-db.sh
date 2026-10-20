#!/bin/sh
# 认证库初始化（ADR-0019 §M4）。**只在数据目录首次初始化时执行一次。**
#
# 目标：应用角色 go_user_system 是**非超级用户**，且是它自己库的 OWNER。
set -eu
: "${AUTH_DB_PASSWORD:?AUTH_DB_PASSWORD 必须传给本容器}"
: "${POSTGRES_USER:?}"

# 口令经 psql 的 -v 传入、用 :'pwd' 由 psql 负责引用/转义 ——
# 不能让 shell 把口令拼进 SQL 字符串：含单引号的口令会直接把语句拆坏，
# 而那种失败在首次初始化时表现为「库建出来了但角色没密码」，reset 前不会有人发现。
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

# 自证：普通角色必须**不是**超级用户（否则「口令分离」名存实亡）。
is_super="$(psql --username "$POSTGRES_USER" --dbname postgres -tA \
  -c "SELECT rolsuper FROM pg_roles WHERE rolname='go_user_system'")"
if [ "$is_super" != "f" ]; then
  echo "FATAL: go_user_system 是超级用户（rolsuper=$is_super）——拒绝继续" >&2
  exit 1
fi
