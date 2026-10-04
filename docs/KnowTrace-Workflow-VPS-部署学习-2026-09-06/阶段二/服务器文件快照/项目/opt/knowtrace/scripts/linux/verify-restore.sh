#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18-alpine}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7.4-alpine}"

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

for command_name in docker tar sha256sum awk grep sort cmp diff find mktemp sed wc tr; do
  require_command "$command_name"
done

[[ $# -eq 1 ]] || die "用法: $0 /var/backups/knowtrace/knowtrace-*.tar.gz"
backup_input="$1"
[[ -e "$backup_input" ]] || die "备份不存在: $backup_input"

scratch_dir="$(mktemp -d /tmp/knowtrace-restore-check.XXXXXX)"
[[ "$scratch_dir" == /tmp/knowtrace-restore-check.* ]] || die "临时目录不符合安全前缀"

containers=()
cleanup() {
  local container_name
  local cleanup_rc=0
  set +e
  for container_name in "${containers[@]}"; do
    if [[ "$container_name" == knowtrace-restore-check-* ]]; then
      if [[ "$(docker inspect --format '{{index .Config.Labels "com.knowtrace.purpose"}}' "$container_name" 2>/dev/null)" == "restore-check" ]]; then
        docker rm --force --volumes "$container_name" >/dev/null 2>&1 || true
      fi
    fi
  done
  if [[ "$scratch_dir" == /tmp/knowtrace-restore-check.* && -d "$scratch_dir" ]]; then
    rm -rf -- "$scratch_dir"
  else
    log "WARNING: 未删除不符合前缀的临时路径: $scratch_dir" >&2
    cleanup_rc=1
  fi
  return "$cleanup_rc"
}
trap cleanup EXIT

if [[ -d "$backup_input" ]]; then
  bundle_dir="$backup_input"
else
  log "检查并解包归档"
  checksum_file="$backup_input.sha256"
  if [[ -f "$checksum_file" ]]; then
    (cd "$(dirname "$backup_input")" && sha256sum --check "$(basename "$checksum_file")")
  else
    log "WARNING: 未找到归档外层校验文件: $checksum_file" >&2
  fi
  tar --list --gzip --file "$backup_input" >/dev/null
  mkdir -p "$scratch_dir/extracted"
  tar --extract --gzip --file "$backup_input" --directory "$scratch_dir/extracted"
  mapfile -t extracted_roots < <(find "$scratch_dir/extracted" -mindepth 1 -maxdepth 1 -type d -print)
  [[ "${#extracted_roots[@]}" -eq 1 ]] || die "归档必须只包含一个顶层目录"
  bundle_dir="${extracted_roots[0]}"
fi

for required_file in \
  SHA256SUMS \
  metadata.txt \
  postgres.dump \
  postgres-counts.tsv \
  mysql.sql \
  mysql-counts.tsv \
  redis.rdb \
  redis-key-count.txt \
  uploads.tar.gz \
  uploads-stats.txt; do
  [[ -s "$bundle_dir/$required_file" ]] || die "备份组件缺失或为空: $required_file"
done

log "验证组件 SHA-256"
(cd "$bundle_dir" && sha256sum --check SHA256SUMS)

if [[ ! -s "$bundle_dir/config/.env" ]]; then
  log "WARNING: 备份中没有 config/.env；灾难恢复时需要从独立密钥库补齐" >&2
fi

for image_name in "$POSTGRES_IMAGE" "$MYSQL_IMAGE" "$REDIS_IMAGE"; do
  docker image inspect "$image_name" >/dev/null 2>&1 || die "本机没有恢复演练所需镜像: $image_name"
done

wait_for_command() {
  local container_name="$1"
  local attempts="$2"
  shift 2
  local attempt
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if docker exec "$container_name" "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

remove_test_container() {
  local container_name="$1"
  [[ "$container_name" == knowtrace-restore-check-* ]] || die "拒绝删除非恢复演练容器: $container_name"
  [[ "$(docker inspect --format '{{index .Config.Labels "com.knowtrace.purpose"}}' "$container_name")" == "restore-check" ]] \
    || die "拒绝删除缺少恢复演练标签的容器: $container_name"
  docker rm --force --volumes "$container_name" >/dev/null
}

postgres_counts_container() {
  local container_name="$1"
  docker exec -i "$container_name" psql \
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

mysql_counts_container() {
  local container_name="$1"
  local table_name
  local row_count
  local table_list

  table_list="$(docker exec "$container_name" sh -ec \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --batch --skip-column-names --user=root --database=go_user_system --execute="SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = '\''BASE TABLE'\'' ORDER BY TABLE_NAME"')"

  while IFS= read -r table_name; do
    [[ -n "$table_name" ]] || continue
    [[ "$table_name" =~ ^[A-Za-z0-9_]+$ ]] || die "MySQL 表名包含未支持字符: $table_name"
    row_count="$(docker exec "$container_name" sh -ec \
      "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql --batch --skip-column-names --user=root --database=go_user_system --execute='SELECT COUNT(*) FROM \`$table_name\`'")"
    printf '%s\t%s\n' "$table_name" "$row_count"
  done <<<"$table_list"
}

run_id="$$-$RANDOM"
pg_container="knowtrace-restore-check-pg-$run_id"

log "在无端口、无生产卷的临时 PostgreSQL 容器中恢复"
docker run --detach \
  --name "$pg_container" \
  --label com.knowtrace.purpose=restore-check \
  --network none \
  --env POSTGRES_DB=knowtrace \
  --env POSTGRES_USER=knowtrace \
  --env POSTGRES_PASSWORD=restore-check-only \
  "$POSTGRES_IMAGE" >/dev/null
containers+=("$pg_container")
wait_for_command "$pg_container" 60 pg_isready --username=knowtrace --dbname=knowtrace \
  || die "临时 PostgreSQL 未就绪"
docker cp "$bundle_dir/postgres.dump" "$pg_container:/tmp/postgres.dump"
docker exec "$pg_container" sh -ec \
  'pg_restore --username=knowtrace --dbname=knowtrace --no-owner --no-privileges --exit-on-error /tmp/postgres.dump'
postgres_counts_container "$pg_container" | sed '/^[[:space:]]*$/d' | sort >"$scratch_dir/postgres-restored.tsv"
cmp --silent "$bundle_dir/postgres-counts.tsv" "$scratch_dir/postgres-restored.tsv" \
  || { diff --unified "$bundle_dir/postgres-counts.tsv" "$scratch_dir/postgres-restored.tsv" >&2 || true; die "PostgreSQL 表行数与备份时不一致"; }
remove_test_container "$pg_container"

mysql_container="knowtrace-restore-check-mysql-$run_id"

log "在无端口、无生产卷的临时 MySQL 容器中恢复"
docker run --detach \
  --name "$mysql_container" \
  --label com.knowtrace.purpose=restore-check \
  --network none \
  --env MYSQL_ROOT_PASSWORD=restore-check-only \
  --env MYSQL_DATABASE=go_user_system \
  "$MYSQL_IMAGE" --skip-log-bin >/dev/null
containers+=("$mysql_container")
wait_for_command "$mysql_container" 90 sh -ec \
  'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --batch --skip-column-names --user=root --execute="SELECT 1"' \
  || die "临时 MySQL 未就绪"
docker cp "$bundle_dir/mysql.sql" "$mysql_container:/tmp/mysql.sql"
docker exec "$mysql_container" sh -ec \
  'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --user=root go_user_system </tmp/mysql.sql'
mysql_counts_container "$mysql_container" | sort >"$scratch_dir/mysql-restored.tsv"
cmp --silent "$bundle_dir/mysql-counts.tsv" "$scratch_dir/mysql-restored.tsv" \
  || { diff --unified "$bundle_dir/mysql-counts.tsv" "$scratch_dir/mysql-restored.tsv" >&2 || true; die "MySQL 表行数与备份时不一致"; }
remove_test_container "$mysql_container"

redis_container="knowtrace-restore-check-redis-$run_id"

log "在无端口、无生产卷的临时 Redis 容器中加载 RDB"
docker create \
  --name "$redis_container" \
  --label com.knowtrace.purpose=restore-check \
  --network none \
  "$REDIS_IMAGE" redis-server --appendonly no >/dev/null
containers+=("$redis_container")
docker cp "$bundle_dir/redis.rdb" "$redis_container:/data/dump.rdb"
docker start "$redis_container" >/dev/null
wait_for_command "$redis_container" 30 redis-cli ping || die "临时 Redis 未就绪"
docker exec "$redis_container" sh -ec 'redis-check-rdb /data/dump.rdb' >/dev/null
source_redis_count="$(tr -d '[:space:]' <"$bundle_dir/redis-key-count.txt")"
restored_redis_count="$(docker exec "$redis_container" redis-cli --raw DBSIZE | tr -d '[:space:]')"
[[ "$source_redis_count" =~ ^[0-9]+$ && "$restored_redis_count" =~ ^[0-9]+$ ]] \
  || die "Redis key 数量不是有效整数"
if (( restored_redis_count > source_redis_count )); then
  die "恢复后的 Redis key 数量异常增加"
fi
if (( restored_redis_count < source_redis_count )); then
  log "WARNING: Redis 有 $((source_redis_count - restored_redis_count)) 个带 TTL 的 key 在演练前已过期" >&2
fi
remove_test_container "$redis_container"

log "解包并核对上传文件统计"
mkdir -p "$scratch_dir/uploads"
tar --list --gzip --file "$bundle_dir/uploads.tar.gz" >/dev/null
tar --extract --gzip --file "$bundle_dir/uploads.tar.gz" --directory "$scratch_dir/uploads"
[[ -d "$scratch_dir/uploads/uploads" ]] || die "上传归档缺少 uploads 顶层目录"
restored_upload_count="$(find "$scratch_dir/uploads/uploads" -type f -printf '.' | wc -c | tr -d ' ')"
restored_upload_bytes="$(find "$scratch_dir/uploads/uploads" -type f -printf '%s\n' | awk '{sum += $1} END {print sum + 0}')"
source_upload_count="$(awk -F= '$1 == "file_count" {print $2}' "$bundle_dir/uploads-stats.txt")"
source_upload_bytes="$(awk -F= '$1 == "total_bytes" {print $2}' "$bundle_dir/uploads-stats.txt")"
[[ "$restored_upload_count" == "$source_upload_count" ]] || die "上传文件数量不一致"
[[ "$restored_upload_bytes" == "$source_upload_bytes" ]] || die "上传文件总字节数不一致"

log "恢复演练通过；未连接生产网络、未挂载生产卷、未改写生产数据库"
printf 'RESTORE_VERIFY=PASS\n'
printf 'POSTGRES_TABLES=%s\n' "$(wc -l <"$bundle_dir/postgres-counts.tsv" | tr -d ' ')"
printf 'MYSQL_TABLES=%s\n' "$(wc -l <"$bundle_dir/mysql-counts.tsv" | tr -d ' ')"
printf 'REDIS_KEYS_SOURCE=%s\n' "$source_redis_count"
printf 'REDIS_KEYS_RESTORED=%s\n' "$restored_redis_count"
printf 'UPLOAD_FILES=%s\n' "$restored_upload_count"
