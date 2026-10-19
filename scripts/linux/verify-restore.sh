#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18-alpine}"
# 认证库（ADR-0019：MySQL → PostgreSQL）。与主应用**同镜像**，故只需预热一个镜像；
# 仍是**独立实例、独立库**（ADR §4 Option D 未采纳合并）。
AUTH_POSTGRES_IMAGE="${AUTH_POSTGRES_IMAGE:-postgres:18-alpine}"
AUTH_POSTGRES_USER="${AUTH_POSTGRES_USER:-go_user_system}"
AUTH_POSTGRES_DB="${AUTH_POSTGRES_DB:-go_user_system}"
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
      if [[ "$(docker inspect --format '{{index .Config.Labels "com.knowtrace-workflow.purpose"}}' "$container_name" 2>/dev/null)" == "restore-check" ]]; then
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
  auth-postgres.dump \
  auth-postgres-counts.tsv \
  redis.rdb \
  redis-key-count.txt \
  uploads.tar.gz \
  uploads-stats.txt; do
  [[ -s "$bundle_dir/$required_file" ]] || die "备份组件缺失或为空: $required_file"
done

log "验证组件 SHA-256"
(cd "$bundle_dir" && sha256sum --check SHA256SUMS)

# metadata.txt 的键值读取。**缺失与空值都返回空串**，由调用方决定是 die 还是放行——
# 这里刻意不给默认值：默认值会把「没记录」静默变成「记录的是那个值」。
metadata_value() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; found=1; exit} END {if (!found) exit 1}' \
    "$bundle_dir/metadata.txt"
}

# ----------------------------------------------------------------------------
# 备份的是「哪个库」（A1/A2）
# ----------------------------------------------------------------------------
# `cmp` 只证明「备份与恢复自洽」：把 auth-postgres.dump 换成主库 dump、重算校验，
# 整条链全绿 —— 因为两份 dump 各自的恢复也都自洽。故必须把**库身份**写进 metadata
# 并在这里断言。两路独立来源：
#   ① 备份端 psql 在源库里读到的 current_database()（metadata 的 *postgres_db=）
#   ② dump 自己的 TOC 头 `;     dbname: <库名>`（pg_restore --list 输出）
# 实测 PG 17.11：`pg_restore --list` 的头部带 dbname，故 ② 可得；它能被单独伪造，
# 所以**两路都要对**。
[[ "$(metadata_value schema_version || true)" =~ ^[0-9]+$ ]] \
  || die "metadata.txt 缺少可解析的 schema_version——无法证明归档格式，拒绝演练"
main_db_meta="$(metadata_value postgres_db || true)"
auth_db_meta="$(metadata_value auth_postgres_db || true)"
[[ -n "$main_db_meta" ]] \
  || die "metadata.txt 缺少 postgres_db（备份端未记录实际库名）——拒绝演练：无法区分两份 dump"
[[ -n "$auth_db_meta" ]] \
  || die "metadata.txt 缺少 auth_postgres_db（备份端未记录实际库名）——拒绝演练：无法区分两份 dump"
[[ "$main_db_meta" != "$auth_db_meta" ]] \
  || die "metadata 里主应用库与认证库同名（$main_db_meta）——两份 dump 不可区分"
[[ "$main_db_meta" == "knowtrace_workflow" ]] \
  || die "主应用库名与期望不符：metadata=$main_db_meta 期望=knowtrace_workflow"
[[ "$auth_db_meta" == "$AUTH_POSTGRES_DB" ]] \
  || die "认证库名与期望不符：metadata=$auth_db_meta 期望=$AUTH_POSTGRES_DB"

main_dump_bytes_meta="$(metadata_value postgres_dump_bytes || true)"
auth_dump_bytes_meta="$(metadata_value auth_postgres_dump_bytes || true)"
main_dump_toc_meta="$(metadata_value postgres_dump_toc_entries || true)"
auth_dump_toc_meta="$(metadata_value auth_postgres_dump_toc_entries || true)"
for __value in "$main_dump_bytes_meta" "$auth_dump_bytes_meta" "$main_dump_toc_meta" "$auth_dump_toc_meta"; do
  [[ "$__value" =~ ^[0-9]+$ ]] \
    || die "metadata 缺少 dump 字节数 / TOC 条目数（备份端未记录）——拒绝演练：这两项是完整性回归的依据"
done
[[ "$(stat -c %s "$bundle_dir/postgres.dump")" == "$main_dump_bytes_meta" ]] \
  || die "postgres.dump 字节数与 metadata 不符"
[[ "$(stat -c %s "$bundle_dir/auth-postgres.dump")" == "$auth_dump_bytes_meta" ]] \
  || die "auth-postgres.dump 字节数与 metadata 不符"

if [[ ! -s "$bundle_dir/config/.env" ]]; then
  log "WARNING: 备份中没有 config/.env；灾难恢复时需要从独立密钥库补齐" >&2
fi

for image_name in "$POSTGRES_IMAGE" "$AUTH_POSTGRES_IMAGE" "$REDIS_IMAGE"; do
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
  [[ "$(docker inspect --format '{{index .Config.Labels "com.knowtrace-workflow.purpose"}}' "$container_name")" == "restore-check" ]] \
    || die "拒绝删除缺少恢复演练标签的容器: $container_name"
  docker rm --force --volumes "$container_name" >/dev/null
}

# 逐表行数（PostgreSQL）。主应用与认证库**共用这一个程序**——恢复端就是把它的输出
# 与归档里的 *-counts.tsv 逐字节 cmp。\gexec 展开表名，不在 shell 里拼标识符。
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

postgres_counts_container() {
  local container_name="$1"
  emit_pg_table_counts_sql | docker exec -i "$container_name" psql \
    --username=knowtrace \
    --dbname=knowtrace \
    --no-psqlrc \
    --tuples-only \
    --no-align \
    --field-separator=$'\t'
}

auth_postgres_counts_container() {
  local container_name="$1"
  emit_pg_table_counts_sql | docker exec -i "$container_name" psql \
    --username="$AUTH_POSTGRES_USER" \
    --dbname="$AUTH_POSTGRES_DB" \
    --no-psqlrc \
    --tuples-only \
    --no-align \
    --field-separator=$'\t'
}

run_id="$$-$RANDOM"
pg_container="knowtrace-restore-check-pg-$run_id"

log "在无端口、无生产卷的临时 PostgreSQL 容器中恢复"
docker run --detach \
  --name "$pg_container" \
  --label com.knowtrace-workflow.purpose=restore-check \
  --network none \
  --env POSTGRES_DB=knowtrace \
  --env POSTGRES_USER=knowtrace \
  --env POSTGRES_PASSWORD=restore-check-only \
  "$POSTGRES_IMAGE" >/dev/null
containers+=("$pg_container")
wait_for_command "$pg_container" 60 pg_isready --username=knowtrace --dbname=knowtrace \
  || die "临时 PostgreSQL 未就绪"
docker cp "$bundle_dir/postgres.dump" "$pg_container:/tmp/postgres.dump"
# ---- dump 与「库身份」对得上吗（A1/A2）----
# ① TOC 头自述的 dbname 必须等于 metadata 里主应用库名。两份 dump 互换后，
#    认证库那份的自述是 go_user_system，会在这一行被拦下。
main_dump_dbname="$(docker exec "$pg_container" sh -ec \
  "pg_restore --list /tmp/postgres.dump | awk '/^; *dbname:/ {print \$3; exit}'" | tr -d '\r')"
[[ -n "$main_dump_dbname" ]] || die "postgres.dump 的 TOC 头读不到 dbname"
[[ "$main_dump_dbname" == "$main_db_meta" ]] \
  || die "postgres.dump 实际来自库 $main_dump_dbname，但 metadata 声明主应用库是 $main_db_meta —— 两份 dump 被互换/调包"
# ② TOC 条目数必须与备份时一致。字节数由 SHA256SUMS 覆盖，条目数覆盖的是
#    「文件没被换成一个同样大小、能跑通的其他 dump」这一类。
main_toc_actual="$(docker exec "$pg_container" sh -ec \
  "pg_restore --list /tmp/postgres.dump | awk '/TOC Entries:/ {print \$4; exit}'" | tr -d '\r')"
[[ "$main_toc_actual" == "$main_dump_toc_meta" ]] \
  || die "postgres.dump 的 TOC 条目数 $main_toc_actual 与 metadata 的 $main_dump_toc_meta 不符"
docker exec "$pg_container" sh -ec \
  'pg_restore --username=knowtrace --dbname=knowtrace --no-owner --no-privileges --exit-on-error /tmp/postgres.dump'
postgres_counts_container "$pg_container" | sed '/^[[:space:]]*$/d' | sort >"$scratch_dir/postgres-restored.tsv"
cmp --silent "$bundle_dir/postgres-counts.tsv" "$scratch_dir/postgres-restored.tsv" \
  || { diff --unified "$bundle_dir/postgres-counts.tsv" "$scratch_dir/postgres-restored.tsv" >&2 || true; die "PostgreSQL 表行数与备份时不一致"; }
remove_test_container "$pg_container"

auth_pg_container="knowtrace-restore-check-authpg-$run_id"

log "在无端口、无生产卷的临时 PostgreSQL 容器中恢复认证库"
docker run --detach \
  --name "$auth_pg_container" \
  --label com.knowtrace-workflow.purpose=restore-check \
  --network none \
  --env POSTGRES_DB="$AUTH_POSTGRES_DB" \
  --env POSTGRES_USER="$AUTH_POSTGRES_USER" \
  --env POSTGRES_PASSWORD=restore-check-only \
  "$AUTH_POSTGRES_IMAGE" >/dev/null
containers+=("$auth_pg_container")
wait_for_command "$auth_pg_container" 60 pg_isready \
  --username="$AUTH_POSTGRES_USER" --dbname="$AUTH_POSTGRES_DB" \
  || die "临时认证 PostgreSQL 未就绪"
docker cp "$bundle_dir/auth-postgres.dump" "$auth_pg_container:/tmp/auth-postgres.dump"
# 同为 A1/A2：TOC 头自述的库名必须是认证库。主库 dump 被放进 auth-postgres.dump 时，
# 自述是 knowtrace_workflow —— 与 metadata 的 auth_postgres_db 不符，在此拦下。
auth_dump_dbname="$(docker exec "$auth_pg_container" sh -ec \
  "pg_restore --list /tmp/auth-postgres.dump | awk '/^; *dbname:/ {print \$3; exit}'" | tr -d '\r')"
[[ -n "$auth_dump_dbname" ]] || die "auth-postgres.dump 的 TOC 头读不到 dbname"
[[ "$auth_dump_dbname" == "$auth_db_meta" ]] \
  || die "auth-postgres.dump 实际来自库 $auth_dump_dbname，但 metadata 声明认证库是 $auth_db_meta —— 两份 dump 被互换/调包"
auth_toc_actual="$(docker exec "$auth_pg_container" sh -ec \
  "pg_restore --list /tmp/auth-postgres.dump | awk '/TOC Entries:/ {print \$4; exit}'" | tr -d '\r')"
[[ "$auth_toc_actual" == "$auth_dump_toc_meta" ]] \
  || die "auth-postgres.dump 的 TOC 条目数 $auth_toc_actual 与 metadata 的 $auth_dump_toc_meta 不符"
# 先校验「可解析 + 数据块完整」，再恢复：--list 只读 TOC，抓不到尾部截断；
# --data-only 配 --file=/dev/null 会把数据块完整读一遍（不写库、不连库）。
# ⚠️ 边界（别写成「完整性闭环」）：--data-only **抓不到尾部追加**（实测 append-128B 仍 0）；
#    尾部追加与 TOC 区损坏由**备份端**的全量 `pg_restore --file=/dev/null` 与
#    TOC 条目数挡住；TOC 头部 `int`/`off` 镜像字段翻转仍会静默漏过（见 backup-all.sh 的注释）。
docker exec "$auth_pg_container" sh -ec 'pg_restore --list /tmp/auth-postgres.dump >/dev/null' \
  || die "认证库 dump 不可解析（pg_restore --list 失败）"
docker exec "$auth_pg_container" sh -ec 'pg_restore --data-only --file=/dev/null /tmp/auth-postgres.dump >/dev/null' \
  || die "认证库 dump 数据块不完整（全量读取失败）"
# 与 --data-only 不同，这一道走完整流程（TOC + 数据块 + 文件尾），不连数据库。
docker exec "$auth_pg_container" sh -ec 'pg_restore --file=/dev/null /tmp/auth-postgres.dump >/dev/null' \
  || die "认证库 dump 完整性校验失败（全量读取）"
docker exec "$auth_pg_container" sh -ec \
  'pg_restore --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --no-owner --no-privileges --exit-on-error /tmp/auth-postgres.dump'
auth_postgres_counts_container "$auth_pg_container" | sed '/^[[:space:]]*$/d' | sort >"$scratch_dir/auth-postgres-restored.tsv"
cmp --silent "$bundle_dir/auth-postgres-counts.tsv" "$scratch_dir/auth-postgres-restored.tsv" \
  || { diff --unified "$bundle_dir/auth-postgres-counts.tsv" "$scratch_dir/auth-postgres-restored.tsv" >&2 || true; die "认证 PostgreSQL 表行数与备份时不一致"; }
remove_test_container "$auth_pg_container"

redis_container="knowtrace-restore-check-redis-$run_id"

log "在无端口、无生产卷的临时 Redis 容器中加载 RDB"
docker create \
  --name "$redis_container" \
  --label com.knowtrace-workflow.purpose=restore-check \
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
printf 'AUTH_POSTGRES_TABLES=%s\n' "$(wc -l <"$bundle_dir/auth-postgres-counts.tsv" | tr -d ' ')"
printf 'REDIS_KEYS_SOURCE=%s\n' "$source_redis_count"
printf 'REDIS_KEYS_RESTORED=%s\n' "$restored_redis_count"
printf 'UPLOAD_FILES=%s\n' "$restored_upload_count"
