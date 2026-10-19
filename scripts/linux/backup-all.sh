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

# 真实恢复验证（verify_dump_by_real_restore）会在**目标实例上建一个临时库再删掉**，
# 故执行用户必须有 CREATEDB 权限。
#   - 主应用：POSTGRES_VERIFY_USER 默认 = 主库用户 knowtrace_workflow
#     （compose.yaml 的 POSTGRES_USER 就是它，即实例超级用户）。
#   - 认证库：compose 切库（M4）之后**管理用户是 auth_admin**，应用用户 go_user_system
#     可能只有 LOGIN/CONNECT。生产用户无 CREATEDB 时按实际情况覆盖：
#         AUTH_POSTGRES_VERIFY_USER=auth_admin
#     默认沿用 AUTH_POSTGRES_USER，以保持「未切库 / 应用用户即管理用户」时也能跑。
#   ⚠️ 若两者都没有 CREATEDB，真实恢复验证会失败并**阻断归档** —— 这是有意的：
#      宁可备份失败，也不落一份没经过真实恢复验证的归档。
POSTGRES_VERIFY_USER="${POSTGRES_VERIFY_USER:-knowtrace_workflow}"
AUTH_POSTGRES_VERIFY_USER="${AUTH_POSTGRES_VERIFY_USER:-$AUTH_POSTGRES_USER}"

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

for command_name in docker git sha256sum tar flock awk sed curl od tr find wc cmp diff; do
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

# 真实恢复验证用的临时库（每库一条："<compose 服务>|<库名>"）。
# 任何退出路径（成功、die、SIGTERM、SIGINT）都必须把它们删干净 —— 残留库会随每次备份累积。
verify_temp_databases=()

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

# ----------------------------------------------------------------------------
# 真实恢复验证（唯一能证明「这份 dump 恢复出来是完整的」的判据）
# ----------------------------------------------------------------------------
# 为什么必须有这一道（2026-10-19 CI 实测，PG **18**，run `39258948661`）：
#   把 dump 的数据区翻 1 字节后，**全量** `pg_restore --file=/dev/null` 返回 **0**；
#   同一注入在 PG 17.11 上返回 1。⇒ 这条判据**不跨版本成立**。
#   它是「快速失败前置」，不是完整性证据。真正能证明完整性的是**把数据恢复进一个库**，
#   再逐表 count(*) 与源库清单逐字节比对。
#
# 代价（如实）：每次备份对两个库各做一次临时恢复 —— O(数据量) 的恢复时间 + 一份临时库的磁盘。
# 换来的是「归档落盘时，它已经被真实恢复验证过一次」。任一环节非 0 ⇒ die，不落归档。
verify_temp_databases=()

new_verify_db_name() {
  local service="$1"
  # 唯一后缀：时间戳 + 本次备份的 nonce + 服务名（两库不同名，避免互相覆盖）。
  # 只保留 [A-Za-z0-9_]：库名要直接进 SQL 之外的命令行参数，不做引号体操。
  printf 'knowtrace_verify_%s_%s_%s' \
    "$(date -u +'%Y%m%d%H%M%S')" "$nonce" "${service//[^A-Za-z0-9]/_}"
}

# 删除本次备份创建的全部临时验证库。幂等：可被 on_exit 重复调用。
# 只删「名字带本次 nonce」的库 —— 变量被意外改写时宁可留下也不删错。
drop_verify_databases() {
  local entry service database username rc=0 i
  local remaining=()

  for ((i = ${#verify_temp_databases[@]} - 1; i >= 0; i -= 1)); do
    entry="${verify_temp_databases[$i]}"
    IFS='|' read -r service database username <<<"$entry"
    if [[ "$database" != knowtrace_verify_*"${nonce}"* ]]; then
      log "WARNING: 拒绝删除不符合命名约定的临时库: $database" >&2
      remaining+=("$entry")
      rc=1
      continue
    fi
    if "${compose[@]}" exec -T "$service" dropdb \
        --username="$username" \
        --if-exists \
        --force \
        --no-password \
        "$database"; then
      log "已删除临时验证库: $service/$database"
    else
      log "WARNING: 删除临时验证库失败，保留待重试: $service/$database" >&2
      remaining+=("$entry")
      rc=1
    fi
  done

  # 空数组在 `set -u` 下的展开写法：`"${arr[@]}"` 在 bash < 4.4 会报 unbound variable。
  verify_temp_databases=(${remaining[@]+"${remaining[@]}"})
  return "$rc"
}

# verify_dump_by_real_restore <标签> <compose 服务> <验证用户> <dump 文件> <期望计数>
#
# 期望计数 = 备份时从**源库**读到的 *-counts.tsv（已 sort、已去空行）。
# 恢复库用**同一段 SQL** 读计数，再逐字节 cmp。
# ⚠️ 恢复验证不得用 `--file=/dev/null`：那条路径不建库、不灌数据，
#    在 PG 18 上对数据区损坏返回 0（见本节开头的实测）。
verify_dump_by_real_restore() {
  local label="$1" service="$2" verify_user="$3" dump_path="$4" expected_counts="$5"
  local verify_db restored_counts

  verify_db="$(new_verify_db_name "$service")"
  log "$label：在 $service 上创建临时库 $verify_db 做真实恢复验证（用户 $verify_user，需 CREATEDB）"
  "${compose[@]}" exec -T "$service" createdb \
    --username="$verify_user" \
    --no-password \
    "$verify_db" \
    || die "$label 无法创建临时验证库 $verify_db（验证用户 $verify_user 缺 CREATEDB？见脚本头部注释）——备份未完成，不落归档"
  verify_temp_databases+=("$service|$verify_db|$verify_user")

  "${compose[@]}" exec -T "$service" pg_restore \
    --username="$verify_user" \
    --dbname="$verify_db" \
    --no-owner \
    --no-privileges \
    --exit-on-error <"$dump_path" \
    || die "$label 真实恢复失败（pg_restore --exit-on-error，临时库 $verify_db）——备份未完成，不落归档"

  if ! restored_counts="$(emit_pg_table_counts_sql | "${compose[@]}" exec -T "$service" psql \
      --username="$verify_user" \
      --dbname="$verify_db" \
      --no-password \
      --no-psqlrc \
      --tuples-only \
      --no-align \
      --field-separator=$'\t' \
      | sed '/^[[:space:]]*$/d' | sort)"; then
    die "$label 读不到恢复库 $verify_db 的逐表计数（psql 失败）——备份未完成，不落归档"
  fi
  # 空分母不得判绿（AGENTS.md D3）：空清单与空清单 cmp 是「相等」的。
  [[ -n "$restored_counts" ]] \
    || die "$label 临时库 $verify_db 的逐表计数为空（恢复了 0 张表）——备份未完成，不落归档"
  if ! cmp -s <(printf '%s\n' "$expected_counts") <(printf '%s\n' "$restored_counts"); then
    log "ERROR: $label 逐表计数不一致（左=备份时源库，右=恢复库）" >&2
    diff --unified <(printf '%s\n' "$expected_counts") <(printf '%s\n' "$restored_counts") >&2 || true
    die "$label 恢复库的逐表行数与备份时不一致——备份未完成，不落归档"
  fi

  drop_verify_databases \
    || die "$label 临时验证库清理失败（$verify_db）——备份未完成，不落归档"
  log "$label 真实恢复验证通过（逐表计数逐字节一致，临时库已删除）"
}

on_exit() {
  local original_rc=$?
  local restart_rc=0
  trap - EXIT
  set +e
  # 临时库先删：即使后面恢复运行时也失败，也不留下残库。
  drop_verify_databases
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
# SIGTERM / SIGINT 走同一条清理路径：systemd 超时杀进程时，临时库同样不能留下。
trap 'exit 143' SIGTERM
trap 'exit 130' SIGINT


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
# 结构判据（**快速失败前置，不是完整性证据**）
# ----------------------------------------------------------------------------
# 这一族（末 5 字节 / --list / --data-only / 全量 --file=/dev/null）比真实恢复**快得多**，
# 且能在解压前就拦下明显损坏的归档 —— 所以保留。但**不要**把其中任何一条当作
# 「完整性已证明」：
#   2026-10-19 CI 实测（PG **18**，run `39258948661`）：数据区翻 1 字节 ⇒
#   全量 `--file=/dev/null` **0**、`--data-only` **0**、`--list` **0**、末 5 字节判据 **0**。
#   同一注入在 PG 17.11 上是 1。⇒ 这一族**不跨版本成立**。
#   完整性证据只有一条：`verify_dump_by_real_restore`（真实恢复 + 逐表计数逐字节 cmp）。
#
# 末 5 字节这一道的来历（实测，PG 17.11，160 KB / 45 TOC 条目的 dump）：
#   尾部**追加** 128 B 垃圾后：`--list` **0**、`--data-only --file=/dev/null` **0**、
#   连全量 `pg_restore --file=/dev/null` 也 **0** —— 三条 pg_restore 路径全部看不见它。
#   原因：最后一条 TOC 记录记的 `size` 与实际读取长度失配时，pg_restore 按**名字长度**
#   调 archive_read，把追加的字节当成该记录载荷的一部分读走。
#   PG 18 实测：**只有它**能拦住 append-128B（list/data_only/full 全 0）。
#   ⇒ 追加类损坏必须在**归档层**判结构，不要指望 pg_restore 报错。
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
# 结构判据（**快速失败前置，不是完整性证据** —— 见下方「结构判据」小节的长注释）：
#   --list           只读 TOC，抓得到头部截断（并守住「可解析」）
#   --file=/dev/null 全量走完解压流程，不连数据库；**PG 18 上对数据区翻字节返回 0**，不可当证据
#   require_custom_archive_tail  末 5 字节必须是 NUL，抓**尾部追加**（pg_restore 看不见它）
#   真正的完整性证据在下面：verify_dump_by_real_restore（真实恢复 + 逐表计数 cmp）。
"${compose[@]}" exec -T postgres pg_restore --file=/dev/null <"$incomplete_dir/postgres.dump" >/dev/null \
  || die "主应用 dump 解压前置检查失败（全量读取）——备份未完成，不落归档"
require_custom_archive_tail "$incomplete_dir/postgres.dump" "主应用"
# ⚠️ 逐表计数**为空也不得落归档**：空清单与恢复端的空清单逐字节 cmp 是「相等」的，
#    于是恢复演练会对一份没有行数依据的备份判 PASS（空分母判绿，AGENTS.md D3）。
#    psql 失败本身由 pipefail 拦下；这里拦的是「psql 成功但输出 0 行」。
postgres_counts | sed '/^[[:space:]]*$/d' | sort >"$incomplete_dir/postgres-counts.tsv"
[[ -s "$incomplete_dir/postgres-counts.tsv" ]] \
  || die "主应用逐表计数为空（postgres_counts 无输出）——备份未完成，不落归档"
# 完整性证据：把 dump 真实恢复进一个临时库，逐表计数与上面刚产出的清单逐字节 cmp。
verify_dump_by_real_restore \
  "主应用" postgres "$POSTGRES_VERIFY_USER" \
  "$incomplete_dir/postgres.dump" "$(cat "$incomplete_dir/postgres-counts.tsv")"
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
# 结构判据（**快速失败前置，不是完整性证据**）。PG 18 实测（run 39258948661，逐条见下）：
#   --list                        0（append-128B / 数据区翻字节都拦不住）
#   --data-only --file=/dev/null  0（同上）
#   全量 --file=/dev/null         0（**数据区翻字节也返回 0** —— PG 17.11 上曾是 1）
#   末 5 字节判据                 只有它能拦住 append-128B
# ⇒ 这一族保留只为「快」，完整性证据只有真实恢复（verify_dump_by_real_restore）。
"${compose[@]}" exec -T "$AUTH_POSTGRES_SERVICE" pg_restore --data-only --file=/dev/null <"$incomplete_dir/auth-postgres.dump" >/dev/null \
  || die "认证库 dump 数据块解压失败（--data-only 读取）——备份未完成，不落归档"
"${compose[@]}" exec -T "$AUTH_POSTGRES_SERVICE" pg_restore --file=/dev/null <"$incomplete_dir/auth-postgres.dump" >/dev/null \
  || die "认证库 dump 解压前置检查失败（全量读取）——备份未完成，不落归档"
# 仍然抓不到的两类（**不**由这一族负责，交由真实恢复兜底）：
#   ① **尾部追加**：全量也 exit 0 → 由 require_custom_archive_tail 在归档层挡住。
#   ② **TOC 头部镜像字段 / schema 区翻转**：解压不执行 SQL，看不见 → 真实恢复会红。
require_custom_archive_tail "$incomplete_dir/auth-postgres.dump" "认证库"
auth_postgres_counts | sed '/^[[:space:]]*$/d' | sort >"$incomplete_dir/auth-postgres-counts.tsv"
[[ -s "$incomplete_dir/auth-postgres-counts.tsv" ]] \
  || die "认证库逐表计数为空（auth_postgres_counts 无输出）——备份未完成，不落归档"
# 完整性证据：真实恢复 + 逐表计数逐字节 cmp（见脚本上方 verify_dump_by_real_restore 注释）。
verify_dump_by_real_restore \
  "认证库" "$AUTH_POSTGRES_SERVICE" "$AUTH_POSTGRES_VERIFY_USER" \
  "$incomplete_dir/auth-postgres.dump" "$(cat "$incomplete_dir/auth-postgres-counts.tsv")"
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
