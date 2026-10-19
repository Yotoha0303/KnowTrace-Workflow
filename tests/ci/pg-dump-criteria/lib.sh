#!/usr/bin/env bash
# 共用函数：把 PostgreSQL 客户端送进 **service 容器内部**执行。
#
# 为什么不在 runner 上装客户端：
#   ubuntu-latest 预装的 `pg_dump` / `pg_restore` 是 PG 16 一代，对 PG 18 服务端会直接拒绝
#   （`abort: server version mismatch`）。装 PG 18 客户端要加 PGDG 源，多一层网络依赖；
#   而 service 容器里本来就有**版本完全一致**的客户端。
#   这同时**和生产链路同形**：backup-all.sh 里的 pg_dump / pg_restore 也是
#   `docker compose exec <service> pg_dump …`，即客户端在容器内。
#
# 依赖环境变量：
#   PG_SERVICE_CONTAINER  service 容器的 docker id（CI 里由 job.services.postgres.id 注入）
#   PGUSER / PGPASSWORD   service 容器的初始超级用户（默认 postgres/postgres）
#
# 用法：source 本文件后调用 run_psql / pg_dump_db / pg_restore_in_container。
set -Eeuo pipefail

# ⚠️ 不在 source 时就断言 PG_SERVICE_CONTAINER：`run-criteria.sh self-check` 是本机
# 可跑的纯逻辑自检（不需要 Docker），source 即失败会让那条路径也跑不起来。
# 只有真正要进容器时才检查 —— 缺前置必须失败，但要在**用到它的那一刻**失败。
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres}"
PGHOST_IN_CONTAINER="${PGHOST_IN_CONTAINER:-127.0.0.1}"
PGPORT_IN_CONTAINER="${PGPORT_IN_CONTAINER:-5432}"

# python 解释器：ubuntu-latest 保证有 python3、不保证有 python；本机（Windows）反之。
# 一次性解析好并**打印出来** —— 免得「用了哪个解释器」变成推断（AGENTS.md D1）。
resolve_python() {
  if [[ -n "${PYTHON_BIN:-}" ]]; then
    printf '%s' "$PYTHON_BIN"
    return 0
  fi
  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

PYTHON_BIN="$(resolve_python)" || {
  printf 'ERROR 找不到 python3 / python —— 缺前置必须失败，不得静默跳过\n' >&2
  exit 1
}
export PYTHON_BIN

# 在容器里跑任意命令；`-i` 让 stdin 透传（psql --file=- 与 pg_restore < dump 都要）。
pg_exec() {
  : "${PG_SERVICE_CONTAINER:?PG_SERVICE_CONTAINER must be set (docker id of the postgres service container)}"
  docker exec -e PGPASSWORD="$PGPASSWORD" -i "$PG_SERVICE_CONTAINER" "$@"
}

# run_psql <db> [psql args...]
run_psql() {
  local database="$1"
  shift
  pg_exec psql \
    --host="$PGHOST_IN_CONTAINER" \
    --port="$PGPORT_IN_CONTAINER" \
    --username="$PGUSER" \
    --dbname="$database" \
    --no-psqlrc \
    --set=ON_ERROR_STOP=1 \
    --quiet \
    "$@"
}

# pg_restore_in_container [pg_restore args...]
# stdin 透传，故 `pg_restore_in_container --list < dump` 可用。
pg_restore_in_container() {
  pg_exec pg_restore \
    --host="$PGHOST_IN_CONTAINER" \
    --port="$PGPORT_IN_CONTAINER" \
    --username="$PGUSER" \
    "$@"
}

# pg_dump_db <database> > file
# 参数与 scripts/linux/backup-all.sh 的 pg_dump 调用**逐项对齐**
# （--format=custom --no-owner --no-privileges）—— 判据要在同一个形状上成立。
pg_dump_db() {
  local database="$1"
  pg_exec pg_dump \
    --host="$PGHOST_IN_CONTAINER" \
    --port="$PGPORT_IN_CONTAINER" \
    --username="$PGUSER" \
    --dbname="$database" \
    --format=custom \
    --no-owner \
    --no-privileges
}

# 逐表行数 SQL：**逐字复制**自 scripts/linux/backup-all.sh 的 emit_pg_table_counts_sql。
# 两份必须同时改；本脚本的 O1 用例会打印这份清单的实际行数，漂移会立刻显形。
emit_pg_table_counts_sql() {
  cat <<'SQL'
SELECT format(
  'SELECT %L AS table_name, count(*) AS row_count FROM %I.%I;',
  schemaname || '.' || relname,
  schemaname,
  relname
)
FROM pg_stat_user_tables
ORDER BY schemaname, relname
\gexec
SQL
}
