#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# 本脚本所在目录 —— 末尾要调用同目录的 write-backup-metrics.sh。
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

PROJECT_DIR="${PROJECT_DIR:-/opt/knowtrace}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/knowtrace}"
QUIESCE_WRITES="${QUIESCE_WRITES:-1}"
APP_READY_URL="${APP_READY_URL:-http://127.0.0.1:3000/api/health/ready}"
AUTH_READY_URL="${AUTH_READY_URL:-http://127.0.0.1:8082/readyz}"

# 认证库（ADR-0019：MySQL → PostgreSQL）。
# ⚠️ 服务名/库名/用户名**刻意可配置**：它们由 compose 决定，而 compose 属 M4（切库）。
#    本脚本**不**硬编码"新容器叫什么"——只给一个目标默认值，部署时按 compose 实际值覆盖。
# ⚠️ 合并顺序：本脚本要求认证库已是 PostgreSQL。在 compose.yaml 切库（M4）**之前**合并本脚本，
#    备份链会停在「Compose 服务未运行: auth-postgres」——这是**有意**的失败，不是回归。
AUTH_POSTGRES_SERVICE="${AUTH_POSTGRES_SERVICE:-auth-postgres}"
AUTH_POSTGRES_USER="${AUTH_POSTGRES_USER:-go_user_system}"
AUTH_POSTGRES_DB="${AUTH_POSTGRES_DB:-go_user_system}"
AUTH_POSTGRES_IMAGE="${AUTH_POSTGRES_IMAGE:-postgres:18-alpine}"

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
for service_name in postgres "$AUTH_POSTGRES_SERVICE" auth-redis auth app; do
  grep -Fxq "$service_name" <<<"$running_services" || die "Compose 服务未运行: $service_name"
done

exec 9>"$BACKUP_ROOT/.backup.lock"
flock -n 9 || die "已有 KnowTrace-Workflow 备份任务在运行"

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

  log "恢复 KnowTrace-Workflow 应用"
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

# 逐表行数清单（PostgreSQL）。
#
# 主应用与认证库**共用这一个程序**：两库 schema 不同，但「逐表 count(*) 并按
# schemaname/relname 排序」的形状必须一致——恢复端就是拿这份清单逐字节 cmp 的。
# \gexec 把 pg_stat_user_tables 展开成一串 SELECT（不在 shell 里拼标识符，
# 也就不必担心表名转义）。
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

# 实际库名（写进 metadata 供恢复端断言「备份的是哪个库」）。
#
# ⚠️ dump 的 TOC 头**其实**带 `;     dbname: <库名>`（实测 PG 17.11 的 pg_restore --list 输出），
#    但它是「被 dump 的那个库」的**自述**——两份 dump 互换后，自述会跟着换，`cmp` 仍自洽。
#    恢复端另外会拿 TOC 头与 metadata 交叉核对（见 verify-restore.sh），
#    而这里记录的是 psql 在**源库内**读到的 current_database()，是独立的一路来源。
current_database_name() {
  local service="$1" username="$2" dbname="$3"
  "${compose[@]}" exec -T "$service" psql \
    --username="$username" \
    --dbname="$dbname" \
    --no-psqlrc \
    --tuples-only \
    --no-align \
    --command='SELECT current_database();' \
    | tr -d '[:space:]'
}

dump_toc_entries() {
  local service="$1" dump_path="$2"
  "${compose[@]}" exec -T "$service" pg_restore --list <"$dump_path" \
    | awk '/TOC Entries:/ {print $4; exit}'
}

# ----------------------------------------------------------------------------
# 完整性检查：custom 归档必须以 5 个 NUL 结尾
# ----------------------------------------------------------------------------
# **这一道是实测逼出来的**（PG 17.11，160 KB / 45 TOC 条目的 dump）：
#   尾部**追加** 128 B 垃圾后：`--list` **0**、`--data-only --file=/dev/null` **0**、
#   连全量 `pg_restore --file=/dev/null` 也 **0** —— 三条 pg_restore 路径全部看不见它。
#   原因：最后一条 TOC 记录记的 `size` 与实际读取长度失配时，pg_restore 按**名字长度**
#   调 archive_read，把追加的字节当成该记录载荷的一部分读走；本机 PG 17.11 上产物碰巧不变，
#   权威验证方在 PG 18 上观察到「真实恢复 0、数据却只剩 2 张表」——即**版本相关、会静默损坏**。
#   ⇒ 正确做法是在**归档层**判结构，不要指望 pg_restore 报错。
#
# custom 格式的末尾 5 字节是固定的：最后一条 TOC 的偏移（4 字节，pg_backup_archiver 写
# `arct->tocs.toc_tail` 的偏移）+ 1 个 NUL 结尾。归档里**不可能**出现「最后一条记录
# 就在文件末尾」的情况，故正常 dump 的这 4 字节恒为 `00 00 00 00`（5 个 NUL）。
# 实测样本：1.6 KB / 14.9 KB / 160 KB / 376 KB 四种 dump，末尾 8 字节都是 `xx xx xx xx 00 00 00 00`
# （最后 5 字节全 0）。尾部追加任何内容都会破坏它。
custom_archive_tail_ok() {
  local dump_path="$1"
  [[ "$(tail -c 5 "$dump_path" | od -An -tx1 | tr -d ' \n')" == "0000000000" ]]
}

require_custom_archive_tail() {
  local dump_path="$1" label="$2"
  custom_archive_tail_ok "$dump_path" \
    || die "$label dump 末尾不是 5 个 NUL（尾部被追加了内容）——备份未完成，不落归档"
}

postgres_counts() {
  emit_pg_table_counts_sql | "${compose[@]}" exec -T postgres psql \
    --username=knowtrace_workflow \
    --dbname=knowtrace_workflow \
    --no-psqlrc \
    --tuples-only \
    --no-align \
    --field-separator=$'\t'
}

auth_postgres_counts() {
  emit_pg_table_counts_sql | "${compose[@]}" exec -T "$AUTH_POSTGRES_SERVICE" psql \
    --username="$AUTH_POSTGRES_USER" \
    --dbname="$AUTH_POSTGRES_DB" \
    --no-psqlrc \
    --tuples-only \
    --no-align \
    --field-separator=$'\t'
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
  --username=knowtrace_workflow \
  --dbname=knowtrace_workflow \
  --format=custom \
  --no-owner \
  --no-privileges >"$incomplete_dir/postgres.dump"
"${compose[@]}" exec -T postgres pg_restore --list <"$incomplete_dir/postgres.dump" >/dev/null
# 与认证库同一套完整性检查（见下方认证库段的长注释）：
#   --list           只读 TOC，抓得到头部截断（并守住「可解析」）
#   --file=/dev/null 全量走完恢复流程（TOC + 数据块），不连数据库；抓数据区/TOC 区损坏
#   require_custom_archive_tail  末 5 字节必须是 NUL，抓**尾部追加**（pg_restore 看不见它）
"${compose[@]}" exec -T postgres pg_restore --file=/dev/null <"$incomplete_dir/postgres.dump" >/dev/null \
  || die "主应用 dump 完整性校验失败（全量读取）——备份未完成，不落归档"
require_custom_archive_tail "$incomplete_dir/postgres.dump" "主应用"
# ⚠️ 逐表计数**为空也不得落归档**：空清单与恢复端的空清单逐字节 cmp 是「相等」的，
#    于是恢复演练会对一份没有行数依据的备份判 PASS（空分母判绿，AGENTS.md D3）。
#    psql 失败本身由 pipefail 拦下；这里拦的是「psql 成功但输出 0 行」。
postgres_counts | sed '/^[[:space:]]*$/d' | sort >"$incomplete_dir/postgres-counts.tsv"
[[ -s "$incomplete_dir/postgres-counts.tsv" ]] \
  || die "主应用逐表计数为空（postgres_counts 无输出）——备份未完成，不落归档"
postgres_db_name="$(current_database_name postgres knowtrace_workflow knowtrace_workflow)"
[[ -n "$postgres_db_name" ]] || die "读不到主应用实际库名——备份未完成，不落归档"
postgres_dump_toc_entries="$(dump_toc_entries postgres "$incomplete_dir/postgres.dump")"
[[ "$postgres_dump_toc_entries" =~ ^[0-9]+$ ]] \
  || die "读不到主应用 dump 的 TOC 条目数（pg_restore --list 输出异常）"

log "导出认证 PostgreSQL"
# 与主应用 postgres.dump 同形（--format=custom）：恢复端用同一套 pg_restore 路径。
# ⚠️ dump 之后**必须**立刻做一次 pg_restore --list：custom 格式是**二进制**，
#    「非空」不等于「可解析」——被截断但非空的 dump 会一路绿到恢复时才炸
#    （AGENTS.md §8.1 ① 的 PG 版；主应用侧在上面的 postgres.dump 已有同一道检查）。
"${compose[@]}" exec -T "$AUTH_POSTGRES_SERVICE" pg_dump \
  --username="$AUTH_POSTGRES_USER" \
  --dbname="$AUTH_POSTGRES_DB" \
  --format=custom \
  --no-owner \
  --no-privileges >"$incomplete_dir/auth-postgres.dump"
"${compose[@]}" exec -T "$AUTH_POSTGRES_SERVICE" pg_restore --list <"$incomplete_dir/auth-postgres.dump" >/dev/null \
  || die "认证库 dump 不可解析（pg_restore --list 失败）——备份未完成，不落归档"
# --list 只读 TOC，**抓不到尾部截断**（实测尾部砍 128B 时仍 exit 0）。再全量读数据块：
# --data-only 配 --file=/dev/null —— 解压+校验、不写库、**不连数据库**。
"${compose[@]}" exec -T "$AUTH_POSTGRES_SERVICE" pg_restore --data-only --file=/dev/null <"$incomplete_dir/auth-postgres.dump" >/dev/null \
  || die "认证库 dump 数据块不完整（全量读取失败）——备份未完成，不落归档"
# ⚠️ --data-only 的边界（实测，别写成「完整性已闭环」）：
#    它只解压**数据块**，TOC 与文件尾不归它管 —— **尾部追加** 128 B 垃圾时它仍 exit 0。
# 再加一道**全量** --file=/dev/null：走完整的「建 schema + 灌数据」流程，不连数据库
# （PGHOST=127.0.0.1 PGPORT=1 下实测 exit 0）。实测（PG 17.11，160 KB / 45 TOC 条目）：
#      TOC / 数据区翻 1 字节（offset 20000 / 60000 / 100000 …）：全量 **1**
#      截断 1% 或 128 B：全量 **1**
# **仍有两处抓不到**（本项目不声称堵住，逐条给实测）：
#   ① **尾部追加**：全量也 exit 0。由下面的 require_custom_archive_tail 单独挡住。
#   ② **TOC 头部镜像字段翻转**（offset 200 / 600 实测「全绿 + 行数仍对」）：
#      改的是 TOC 头的 `int`/`off` 镜像，解压仍按头部的 `data` 偏移走，产物无恙；
#      schema 区的特征字节（offset 2000 / 3000 / 5000 / 6000 / 8000）翻转让 SQL 出现
#      非法 UTF-8，真实恢复 exit 1，但**全量 --file=/dev/null 只写文件不执行 SQL**，
#      所以它看不见。那一段由恢复端的真实恢复（--exit-on-error）覆盖。
#   对外一律表述为「尾部截断、尾部追加、数据区/TOC 区损坏已覆盖；TOC 头部镜像字段未覆盖」。
"${compose[@]}" exec -T "$AUTH_POSTGRES_SERVICE" pg_restore --file=/dev/null <"$incomplete_dir/auth-postgres.dump" >/dev/null \
  || die "认证库 dump 完整性校验失败（全量读取）——备份未完成，不落归档"
require_custom_archive_tail "$incomplete_dir/auth-postgres.dump" "认证库"
auth_postgres_counts | sed '/^[[:space:]]*$/d' | sort >"$incomplete_dir/auth-postgres-counts.tsv"
[[ -s "$incomplete_dir/auth-postgres-counts.tsv" ]] \
  || die "认证库逐表计数为空（auth_postgres_counts 无输出）——备份未完成，不落归档"
auth_postgres_db_name="$(current_database_name "$AUTH_POSTGRES_SERVICE" "$AUTH_POSTGRES_USER" "$AUTH_POSTGRES_DB")"
[[ -n "$auth_postgres_db_name" ]] || die "读不到认证库实际库名——备份未完成，不落归档"
auth_postgres_dump_toc_entries="$(dump_toc_entries "$AUTH_POSTGRES_SERVICE" "$incomplete_dir/auth-postgres.dump")"
[[ "$auth_postgres_dump_toc_entries" =~ ^[0-9]+$ ]] \
  || die "读不到认证库 dump 的 TOC 条目数（pg_restore --list 输出异常）"
[[ "$postgres_db_name" != "$auth_postgres_db_name" ]] \
  || die "主应用库与认证库的**实际库名相同**（$postgres_db_name）——恢复端将无法区分两份 dump"

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
# 注意：这份归档含生产密钥（.env 与 .env.observability 里都有），
# 脚本已在 metadata.txt 标了 contains_secrets=yes。
# 因此它只应留在服务器本地，**推到异地前必须加密**。
for config_file in .env .env.observability compose.yaml compose.production.yaml; do
  if [[ -f "$PROJECT_DIR/$config_file" ]]; then
    cp --preserve=mode,timestamps "$PROJECT_DIR/$config_file" "$incomplete_dir/config/$config_file"
  fi
done
for system_config in \
  /etc/caddy/Caddyfile \
  /etc/nginx/nginx.conf \
  /etc/nginx/sites-available/knowtrace \
  /etc/nginx/sites-available/knowtrace-workflow.conf \
  /etc/nginx/sites-enabled/knowtrace \
  /etc/nginx/sites-enabled/knowtrace-workflow.conf \
  /etc/ssh/sshd_config \
  /etc/ssh/sshd_config.d/*.conf; do
  if [[ -f "$system_config" ]]; then
    config_name="$(sed 's#^/##; s#/#__#g' <<<"$system_config")"
    cp --preserve=mode,timestamps "$system_config" "$incomplete_dir/config/$config_name"
  fi
done

# 镜像名从**容器实测**，不写字面量：字面量会在镜像升级后与事实脱节，
# 而 metadata 正是恢复端判断「用哪个镜像演练」的依据（不一致 ⇒ 演练验的不是同一组合）。
inspect_image() {
  local service_name="$1" container_id image_name
  container_id="$("${compose[@]}" ps -q "$service_name")"
  [[ -n "$container_id" ]] || die "读不到 Compose 服务 $service_name 的容器 ID"
  image_name="$(docker inspect --format '{{.Config.Image}}' "$container_id")"
  [[ -n "$image_name" ]] || die "读不到 $service_name 容器的实际镜像名"
  printf '%s' "$image_name"
}

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
postgres_image=$(inspect_image postgres)
auth_postgres_image=$(inspect_image "$AUTH_POSTGRES_SERVICE")
redis_image=$(inspect_image auth-redis)
postgres_db=$postgres_db_name
auth_postgres_db=$auth_postgres_db_name
postgres_dump_bytes=$(stat -c %s "$incomplete_dir/postgres.dump")
auth_postgres_dump_bytes=$(stat -c %s "$incomplete_dir/auth-postgres.dump")
postgres_dump_toc_entries=$postgres_dump_toc_entries
auth_postgres_dump_toc_entries=$auth_postgres_dump_toc_entries
contains_secrets=yes
EOF

(cd "$incomplete_dir" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
chmod -R go-rwx "$incomplete_dir"

restore_runtime

curl -fsS --max-time 10 "$APP_READY_URL" >/dev/null || die "备份后 KnowTrace-Workflow ready 检查失败: $APP_READY_URL"
curl -fsS --max-time 10 "$AUTH_READY_URL" >/dev/null || die "备份后认证服务 ready 检查失败: $AUTH_READY_URL"

mv "$incomplete_dir" "$final_dir"
tar --create --gzip --file "$archive_path" --directory "$BACKUP_ROOT" "$backup_id"
(cd "$BACKUP_ROOT" && sha256sum "$(basename "$archive_path")" >"$(basename "$archive_path").sha256")
chmod 600 "$archive_path" "$archive_path.sha256"

# 刷新备份指标。
#
# 为什么必须在这里刷新：systemd 单元的 ExecStartPost 只在**定时触发**时跑，
# 而运维手册教人**手工**跑 backup-all.sh。手工路径不刷新的话，
# knowtrace_backup_archive_count 会停在旧值 —— 实测踩到：备份已成功落盘、
# 校验通过，指标却仍是 0，于是 KnowTraceBackupMissing / BackupStale
# 继续 firing，而人已经"做完了备份"。误报会训练人忽略告警。
#
# 与 ExecStartPost 重复执行是无害的：write-backup-metrics.sh 只做只读扫描 +
# 原子覆盖，幂等且极便宜。
#
# 非致命：指标写失败不该让一次**已经成功**的备份被判为失败（与单元里
# ExecStartPost 前的 `-` 同一思路）。
"$script_directory/write-backup-metrics.sh" >/dev/null 2>&1 \
  || log "WARNING: 备份指标刷新失败（不影响备份本身，可手工跑 write-backup-metrics.sh 补）"

trap - EXIT
log "备份完成: $archive_path"
log "校验文件: $archive_path.sha256"
printf 'BACKUP_ARCHIVE=%s\n' "$archive_path"
printf 'BACKUP_SHA256=%s\n' "$archive_path.sha256"
