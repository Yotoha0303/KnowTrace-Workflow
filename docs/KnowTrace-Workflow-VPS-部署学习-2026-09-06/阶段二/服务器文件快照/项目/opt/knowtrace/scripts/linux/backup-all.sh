#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

PROJECT_DIR="${PROJECT_DIR:-/opt/knowtrace}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/knowtrace}"
QUIESCE_WRITES="${QUIESCE_WRITES:-1}"
APP_READY_URL="${APP_READY_URL:-http://127.0.0.1:3000/api/health/ready}"
AUTH_READY_URL="${AUTH_READY_URL:-http://127.0.0.1:8082/readyz}"

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

for command_name in docker git sha256sum tar flock awk sed curl od tr find wc; do
  require_command "$command_name"
done

[[ -d "$PROJECT_DIR" ]] || die "项目目录不存在: $PROJECT_DIR"
[[ -f "$PROJECT_DIR/compose.yaml" ]] || die "缺少 $PROJECT_DIR/compose.yaml"
[[ "$BACKUP_ROOT" = /* ]] || die "BACKUP_ROOT 必须是绝对路径"
[[ "$BACKUP_ROOT" != "/" ]] || die "BACKUP_ROOT 不能是根目录"
[[ "$QUIESCE_WRITES" == "0" || "$QUIESCE_WRITES" == "1" ]] || die "QUIESCE_WRITES 只能是 0 或 1"

mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"

cd "$PROJECT_DIR"

compose_files=(-f compose.yaml)
if [[ -f compose.production.yaml ]]; then
  compose_files+=(-f compose.production.yaml)
fi
compose=(docker compose --project-directory "$PROJECT_DIR" "${compose_files[@]}")

running_services="$("${compose[@]}" ps --status running --services)"
for service_name in postgres auth-mysql auth-redis auth app; do
  grep -Fxq "$service_name" <<<"$running_services" || die "Compose 服务未运行: $service_name"
done

exec 9>"$BACKUP_ROOT/.backup.lock"
flock -n 9 || die "已有 KnowTrace 备份任务在运行"

created_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
stamp="$(date -u +'%Y%m%dT%H%M%SZ')"
nonce="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
backup_id="knowtrace-${stamp}-${nonce}"
incomplete_dir="$BACKUP_ROOT/.incomplete-$backup_id"
final_dir="$BACKUP_ROOT/$backup_id"
archive_path="$BACKUP_ROOT/$backup_id.tar.gz"
quiesced=0

mkdir -p "$incomplete_dir/config"
chmod 700 "$incomplete_dir" "$incomplete_dir/config"

service_health() {
  local service_name="$1"
  local container_id
  container_id="$("${compose[@]}" ps -q "$service_name")"
  [[ -n "$container_id" ]] || return 1
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id"
}

wait_healthy() {
  local service_name="$1"
  local attempts="${2:-60}"
  local state=""
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    state="$(service_health "$service_name" 2>/dev/null || true)"
    if [[ "$state" == "healthy" || "$state" == "running" ]]; then
      return 0
    fi
    sleep 2
  done

  log "ERROR: 服务未在等待时间内恢复健康: $service_name (state=${state:-unknown})" >&2
  return 1
}

restore_runtime() {
  local restart_rc=0

  if [[ "$quiesced" -ne 1 ]]; then
    return 0
  fi

  log "恢复认证服务"
  "${compose[@]}" start auth || restart_rc=1
  wait_healthy auth 60 || restart_rc=1

  log "恢复 KnowTrace 应用"
  "${compose[@]}" start app || restart_rc=1
  wait_healthy app 60 || restart_rc=1

  quiesced=0
  return "$restart_rc"
}

on_exit() {
  local original_rc=$?
  local restart_rc=0
  trap - EXIT
  set +e
  restore_runtime
  restart_rc=$?
  set -e

  if [[ "$original_rc" -eq 0 && "$restart_rc" -ne 0 ]]; then
    original_rc="$restart_rc"
  fi
  if [[ "$original_rc" -ne 0 ]]; then
    log "备份未完成；保留现场目录: $incomplete_dir" >&2
  fi
  exit "$original_rc"
}
trap on_exit EXIT

postgres_counts() {
  "${compose[@]}" exec -T postgres psql \
    --username=knowtrace \
    --dbname=knowtrace \
    --no-psqlrc \
    --tuples-only \
    --no-align \
    --field-separator=$'\t' <<'SQL'
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

mysql_counts() {
  local table_name
  local row_count
  local table_list

  table_list="$("${compose[@]}" exec -T auth-mysql sh -ec \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --batch --skip-column-names --user=root --database=go_user_system --execute="SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = '\''BASE TABLE'\'' ORDER BY TABLE_NAME"')"

  while IFS= read -r table_name; do
    [[ -n "$table_name" ]] || continue
    [[ "$table_name" =~ ^[A-Za-z0-9_]+$ ]] || die "MySQL 表名包含未支持字符: $table_name"
    row_count="$("${compose[@]}" exec -T auth-mysql sh -ec \
      "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql --batch --skip-column-names --user=root --database=go_user_system --execute='SELECT COUNT(*) FROM \`$table_name\`'" </dev/null)"
    printf '%s\t%s\n' "$table_name" "$row_count"
  done <<<"$table_list"
}

if [[ "$QUIESCE_WRITES" == "1" ]]; then
  log "进入短暂维护窗口：停止 app 与 auth 写入入口"
  quiesced=1
  "${compose[@]}" stop --timeout 30 app auth
else
  log "WARNING: 在线备份模式不会提供跨存储原子一致性"
fi

log "导出 PostgreSQL"
"${compose[@]}" exec -T postgres pg_dump \
  --username=knowtrace \
  --dbname=knowtrace \
  --format=custom \
  --no-owner \
  --no-privileges >"$incomplete_dir/postgres.dump"
"${compose[@]}" exec -T postgres pg_restore --list <"$incomplete_dir/postgres.dump" >/dev/null
postgres_counts | sed '/^[[:space:]]*$/d' | sort >"$incomplete_dir/postgres-counts.tsv"

log "导出认证 MySQL"
"${compose[@]}" exec -T auth-mysql sh -ec \
  'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump --user=root --single-transaction --routines --triggers --events --set-gtid-purged=OFF go_user_system' \
  >"$incomplete_dir/mysql.sql"
mysql_counts | sort >"$incomplete_dir/mysql-counts.tsv"

log "生成 Redis RDB 快照"
redis_key_count="$("${compose[@]}" exec -T auth-redis redis-cli --raw DBSIZE)"
for _ in {1..60}; do
  redis_info="$("${compose[@]}" exec -T auth-redis redis-cli --raw INFO persistence | tr -d '\r')"
  if grep -q '^rdb_bgsave_in_progress:0$' <<<"$redis_info"; then
    break
  fi
  sleep 1
done
grep -q '^rdb_bgsave_in_progress:0$' <<<"$redis_info" || die "等待已有 Redis RDB 任务结束超时"
redis_saves_before="$(awk -F: '$1 == "rdb_saves" {print $2}' <<<"$redis_info")"
[[ "$redis_saves_before" =~ ^[0-9]+$ ]] || die "无法读取 Redis rdb_saves 计数"

"${compose[@]}" exec -T auth-redis redis-cli --raw BGSAVE >/dev/null
for _ in {1..60}; do
  redis_info="$("${compose[@]}" exec -T auth-redis redis-cli --raw INFO persistence | tr -d '\r')"
  redis_saves_after="$(awk -F: '$1 == "rdb_saves" {print $2}' <<<"$redis_info")"
  if [[ "$redis_saves_after" =~ ^[0-9]+$ ]] \
    && (( redis_saves_after > redis_saves_before )) \
    && grep -q '^rdb_bgsave_in_progress:0$' <<<"$redis_info"; then
    grep -q '^rdb_last_bgsave_status:ok$' <<<"$redis_info" || die "Redis 最近一次 RDB 保存失败"
    break
  fi
  sleep 1
done
[[ "${redis_saves_after:-}" =~ ^[0-9]+$ ]] \
  && (( redis_saves_after > redis_saves_before )) \
  && grep -q '^rdb_bgsave_in_progress:0$' <<<"$redis_info" \
  || die "Redis 新 RDB 保存未在等待时间内完成"

redis_dir="$("${compose[@]}" exec -T auth-redis redis-cli --raw CONFIG GET dir | sed -n '2p' | tr -d '\r')"
redis_dbfilename="$("${compose[@]}" exec -T auth-redis redis-cli --raw CONFIG GET dbfilename | sed -n '2p' | tr -d '\r')"
[[ "$redis_dir" =~ ^/[A-Za-z0-9._/-]+$ && "/$redis_dir/" != *"/../"* ]] \
  || die "Redis dir 不是受支持的安全绝对路径: $redis_dir"
[[ "$redis_dbfilename" =~ ^[A-Za-z0-9._-]+$ && "$redis_dbfilename" != ".." ]] \
  || die "Redis dbfilename 不安全: $redis_dbfilename"
redis_rdb_path="${redis_dir%/}/$redis_dbfilename"
"${compose[@]}" exec -T auth-redis sh -ec "test -s '$redis_rdb_path'" \
  || die "Redis RDB 不存在或为空: $redis_rdb_path"
"${compose[@]}" exec -T auth-redis sh -ec "cat '$redis_rdb_path'" >"$incomplete_dir/redis.rdb"
[[ -s "$incomplete_dir/redis.rdb" ]] || die "导出的 Redis RDB 为空"
printf '%s\n' "$redis_key_count" >"$incomplete_dir/redis-key-count.txt"

log "归档上传文件"
mkdir -p "$PROJECT_DIR/data/uploads"
tar --create --gzip --file "$incomplete_dir/uploads.tar.gz" --directory "$PROJECT_DIR/data" uploads
upload_file_count="$(find "$PROJECT_DIR/data/uploads" -type f -printf '.' | wc -c | tr -d ' ')"
upload_total_bytes="$(find "$PROJECT_DIR/data/uploads" -type f -printf '%s\n' | awk '{sum += $1} END {print sum + 0}')"
printf 'file_count=%s\ntotal_bytes=%s\n' "$upload_file_count" "$upload_total_bytes" >"$incomplete_dir/uploads-stats.txt"

log "保存恢复所需配置（包含敏感信息）"
for config_file in .env compose.yaml compose.production.yaml; do
  if [[ -f "$PROJECT_DIR/$config_file" ]]; then
    cp --preserve=mode,timestamps "$PROJECT_DIR/$config_file" "$incomplete_dir/config/$config_file"
  fi
done
for system_config in \
  /etc/caddy/Caddyfile \
  /etc/nginx/nginx.conf \
  /etc/nginx/sites-available/knowtrace \
  /etc/nginx/sites-available/knowtrace.conf \
  /etc/nginx/sites-enabled/knowtrace \
  /etc/nginx/sites-enabled/knowtrace.conf \
  /etc/ssh/sshd_config \
  /etc/ssh/sshd_config.d/*.conf; do
  if [[ -f "$system_config" ]]; then
    config_name="$(sed 's#^/##; s#/#__#g' <<<"$system_config")"
    cp --preserve=mode,timestamps "$system_config" "$incomplete_dir/config/$config_name"
  fi
done

application_commit="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || printf 'unknown')"
cat >"$incomplete_dir/metadata.txt" <<EOF
schema_version=1
backup_id=$backup_id
created_at_utc=$created_at
hostname=$(hostname)
application_commit=$application_commit
compose_overlay=$([[ -f compose.production.yaml ]] && printf 'compose.production.yaml' || printf 'none')
quiesced_writes=$QUIESCE_WRITES
consistency=$([[ "$QUIESCE_WRITES" == "1" ]] && printf 'application-writes-stopped' || printf 'per-datastore-only')
postgres_image=postgres:18-alpine
mysql_image=mysql:8.0
redis_image=redis:7.4-alpine
contains_secrets=yes
EOF

(cd "$incomplete_dir" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
chmod -R go-rwx "$incomplete_dir"

restore_runtime

curl -fsS --max-time 10 "$APP_READY_URL" >/dev/null || die "备份后 KnowTrace ready 检查失败: $APP_READY_URL"
curl -fsS --max-time 10 "$AUTH_READY_URL" >/dev/null || die "备份后认证服务 ready 检查失败: $AUTH_READY_URL"

mv "$incomplete_dir" "$final_dir"
tar --create --gzip --file "$archive_path" --directory "$BACKUP_ROOT" "$backup_id"
(cd "$BACKUP_ROOT" && sha256sum "$(basename "$archive_path")" >"$(basename "$archive_path").sha256")
chmod 600 "$archive_path" "$archive_path.sha256"

trap - EXIT
log "备份完成: $archive_path"
log "校验文件: $archive_path.sha256"
printf 'BACKUP_ARCHIVE=%s\n' "$archive_path"
printf 'BACKUP_SHA256=%s\n' "$archive_path.sha256"
