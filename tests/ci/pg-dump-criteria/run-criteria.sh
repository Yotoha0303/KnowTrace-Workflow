#!/usr/bin/env bash
# PG 18 上的 dump 判据 —— M5 三跳链 03 环阻断项 G-6 的第二层（**证据**，不是跳线）。
#
# 为什么需要这个 job：
#   `scripts/linux/backup-all.sh` / `verify-restore.sh` 里的 dump 完整性判据
#   （`pg_restore --list` / `--data-only --file=/dev/null` / 全量 `--file=/dev/null` /
#   末 5 字节为 NUL / 逐表计数非空）此前**全部实测都在 PG 17.11**。
#   唯一一次 PG 18 的观察在别处（append 后真实恢复 0、数据只剩 2 张表），
#   没有任何仓内证据。本 job 在 `postgres:18-alpine` service 上把每一条判据跑一遍，
#   把「判据名 / 期望 / 实际」打进 CI 日志。
#
# 用法：
#   run-criteria.sh positive   # 正向 + 判据边界观察（observed-only，不计入失败）
#   run-criteria.sh negative   # 负向注入（gating，任一期望不成立即 exit 1）
#
# 环境变量见 lib.sh；另可用 WORKDIR 指定工作目录（默认 mktemp -d）。
#
# ⚠️ 与真实链路的差异（如实，不得表述为「备份脚本已在 CI 里跑过」）：
#   本 job **不**跑 `backup-all.sh` 本体——它要 docker compose 整栈（postgres / auth-postgres /
#   auth-redis / auth / app）。本 job 用与它**同形的 pg_dump / pg_restore 调用**
#   （--format=custom --no-owner --no-privileges），在 service 容器内执行，
#   **逐条覆盖它用到的完整性判据**。真 compose 全链是第三层，本提交不含。
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd -P)"
# shellcheck source=tests/ci/pg-dump-criteria/lib.sh
source "$SCRIPT_DIR/lib.sh"

MODE="${1:?usage: run-criteria.sh <positive|negative>}"
WORKDIR="${WORKDIR:-$(mktemp -d -t pg-dump-criteria.XXXXXX)}"
mkdir -p "$WORKDIR"

MAIN_DB="knowtrace_ci"
AUTH_DB="go_user_system_ci"
RESTORE_MAIN_DB="knowtrace_ci_restore"
RESTORE_AUTH_DB="go_user_system_ci_restore"

# ---------------------------------------------------------------------------
# 判据记账。每个用例打印「判据名 / 期望 / 实际」，并计入 failed。
# ---------------------------------------------------------------------------
failed=0
checked=0

check() {
  local name="$1" expected="$2" actual="$3"
  checked=$((checked + 1))
  if [[ "$actual" == "$expected" ]]; then
    printf 'PASS  %-52s expected=%-6s actual=%s\n' "$name" "$expected" "$actual"
  else
    printf 'FAIL  %-52s expected=%-6s actual=%s\n' "$name" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

observe() {
  # 只记录、不计分。用于「期望值本身要在 PG 18 上先测出来」的项。
  printf 'OBS   %-52s actual=%s\n' "$1" "$2"
}

die() {
  printf 'ERROR %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 判据实现：与 scripts/linux/backup-all.sh 的 4 道门逐条对应。
#
# ⚠️ 全部写成 `if <command>; then echo 0; else echo 1; fi`，**不写** `<command>; echo $?`：
#    这些函数是在 `$(...)` 里被调用的，而 `set -e` 会被带进命令替换的子 shell——
#    裸的失败命令会让子 shell 当场退出，`echo $?` 根本执行不到，返回值变成空串。
#    （本仓库的其它脚本在同一处踩过同类坑，见 docs/changes 里「退出码被吞」的记载。）
# ---------------------------------------------------------------------------
list_rc() { if pg_restore_in_container --list <"$1" >/dev/null 2>&1; then echo 0; else echo 1; fi; }
data_only_rc() { if pg_restore_in_container --data-only --file=/dev/null <"$1" >/dev/null 2>&1; then echo 0; else echo 1; fi; }
full_rc() { if pg_restore_in_container --file=/dev/null <"$1" >/dev/null 2>&1; then echo 0; else echo 1; fi; }

# 真实恢复验证（对应 scripts/linux/backup-all.sh 的 verify_dump_by_real_restore）：
#   在**真实库**里恢复 + 逐表计数与正向阶段产出的 main-counts.tsv 逐字节 cmp。
# 返回 0 = 验证通过（恢复成功且计数一致），非 0 = 不通过。
#
# ⚠️ 这是**唯一**能证明「数据区损坏」的判据：
#    CI run 39258948661（PG 18）实测——数据区翻 1 字节后
#    `--list`=0 / `--data-only --file=/dev/null`=0 / 全量 `--file=/dev/null`=**0**；
#    而同一注入在 PG 17.11 上是 1。⇒ 那三条是「快速失败前置」，不是完整性证据。
real_restore_verify_rc() {
  local dump="$1" log_name="$2"
  local db="knowtrace_ci_verify_negative" rc=0
  create_database "$db"
  if pg_restore_in_container --dbname="$db" --no-owner --no-privileges \
      --exit-on-error <"$dump" >"$WORKDIR/$log_name.log" 2>&1; then
    table_counts "$db" >"$WORKDIR/$log_name.counts.tsv"
    if cmp -s "$WORKDIR/main-counts.tsv" "$WORKDIR/$log_name.counts.tsv"; then
      rc=0
    else
      rc=1
    fi
  else
    rc=$?
  fi
  run_psql postgres --command="DROP DATABASE IF EXISTS \"$db\";" >/dev/null
  echo "$rc"
}

# 逐字对应 backup-all.sh 的 custom_archive_tail_ok：
#   [[ "$(tail -c 5 "$dump_path" | od -An -tx1 | tr -d ' \n')" == "0000000000" ]]
# 返回 0 = 通过（末 5 字节全 NUL），1 = 不通过。实际观测值打到 stderr，留在 CI 日志里。
tail_ok() {
  local observed
  observed="$(tail -c 5 "$1" | od -An -tx1 | tr -d ' \n')"
  printf 'TAIL  %-52s observed=%s\n' "$(basename "$1")" "$observed" >&2
  [[ "$observed" == "0000000000" ]]
}
tail_rc() { if tail_ok "$1"; then echo 0; else echo 1; fi; }

# 逐表计数（与 backup-all.sh 的 emit_pg_table_counts_sql 同一段 SQL）。
table_counts() {
  local tab=$'\t'
  emit_pg_table_counts_sql | run_psql "$1" --tuples-only --no-align --field-separator="$tab" |
    sed '/^[[:space:]]*$/d' | sort
}

# dump 自述的库名（verify-restore.sh 的判据 ②：TOC 头 `;     dbname:`）。
dump_dbname() {
  pg_restore_in_container --list <"$1" | awk '/^; *dbname:/ {print $3; exit}' | tr -d '\r'
}

# ---------------------------------------------------------------------------
# 建库 / 迁移 / 夹具
# ---------------------------------------------------------------------------
create_database() {
  local database="$1"
  run_psql postgres --command="DROP DATABASE IF EXISTS \"$database\";" >/dev/null
  run_psql postgres --command="CREATE DATABASE \"$database\";" >/dev/null
}

apply_migrations() {
  local flavor="$1" directory="$2" database="$3"
  # flavor 为空串时（drizzle）刻意不加引号：展开成零个参数。
  "$PYTHON_BIN" "$SCRIPT_DIR/apply-migrations.py" $flavor "$directory" "$database"
}

seed_main_fixtures() {
  run_psql "$MAIN_DB" --file=- <"$SCRIPT_DIR/fixtures/main-app.sql" >/dev/null
}

seed_auth_fixtures() {
  # 认证库夹具：主键是 IDENTITY，status 是 smallint（00001_create_users.sql:6-13）。
  # 刻意**不写 email**：该表没有这一列。
  run_psql "$AUTH_DB" --command="
    INSERT INTO users (username, password_hash, nickname, status)
    VALUES ('ci-fixture-user', 'not-a-real-hash', 'CI 夹具', 1);
  " >/dev/null
}

# ---------------------------------------------------------------------------
# self-check：**不需要 Docker** 的纯逻辑自检。
# 本机可跑，CI 在进 PG 之前先跑一遍 —— 它保证「判据本身」没坏，
# 这样 PG 阶段红了就只可能是 PG 行为变了，而不是注入器/解析器写错。
# ---------------------------------------------------------------------------
self_check() {
  echo "=== self-check（不需要 Docker）==="

  # 1) 仓库结构 + 迁移解析
  check "S1a/drizzle dir exists" "yes" "$([[ -d "$REPO_ROOT/drizzle" ]] && echo yes || echo no)"
  check "S1b/goose migrations dir exists" "yes" \
    "$([[ -d "$REPO_ROOT/services/go-user-system/migrations" ]] && echo yes || echo no)"
  check "S1c/main fixtures exist" "yes" "$([[ -s "$SCRIPT_DIR/fixtures/main-app.sql" ]] && echo yes || echo no)"
  if "$PYTHON_BIN" "$SCRIPT_DIR/apply-migrations.py" --check "$REPO_ROOT/drizzle" >"$WORKDIR/s1-drizzle.log" 2>&1; then
    check "S1d/drizzle migrations parse" "0" "0"
  else
    check "S1d/drizzle migrations parse" "0" "$?"
  fi
  if "$PYTHON_BIN" "$SCRIPT_DIR/apply-migrations.py" --check --goose \
      "$REPO_ROOT/services/go-user-system/migrations" >"$WORKDIR/s1-goose.log" 2>&1; then
    check "S1e/goose migrations parse" "0" "0"
  else
    check "S1e/goose migrations parse" "0" "$?"
  fi

  # 2) 注入器：确定性 + 大小/尾字节的形状
  local synthetic="$WORKDIR/synthetic.dump"
  "$PYTHON_BIN" - "$synthetic" <<'PY'
import pathlib, sys
# 4 KiB 的确定性填充；末 5 字节刻意写成 NUL，模拟一个"健康"的 custom 归档尾部。
data = bytearray((i % 251) for i in range(4096))
data[-5:] = b"\x00\x00\x00\x00\x00"
pathlib.Path(sys.argv[1]).write_bytes(bytes(data))
PY
  local base_size
  base_size="$(stat -c %s "$synthetic")"

  "$PYTHON_BIN" "$SCRIPT_DIR/mutate.py" copy "$synthetic" "$WORKDIR/s-copy.dump" >/dev/null
  check "S2a/copy is byte-identical" "0" \
    "$(cmp -s "$synthetic" "$WORKDIR/s-copy.dump" && echo 0 || echo 1)"

  "$PYTHON_BIN" "$SCRIPT_DIR/mutate.py" append-random-128 "$synthetic" "$WORKDIR/s-append.dump" >/dev/null
  check "S2b/append-random-128 grows by 128" "$((base_size + 128))" "$(stat -c %s "$WORKDIR/s-append.dump")"
  check "S2c/append-random-128 breaks the tail criterion" "1" "$(tail_rc "$WORKDIR/s-append.dump")"

  "$PYTHON_BIN" "$SCRIPT_DIR/mutate.py" append-random-128 "$synthetic" "$WORKDIR/s-append2.dump" >/dev/null
  check "S2d/append-random-128 is deterministic (same seed)" "0" \
    "$(cmp -s "$WORKDIR/s-append.dump" "$WORKDIR/s-append2.dump" && echo 0 || echo 1)"

  "$PYTHON_BIN" "$SCRIPT_DIR/mutate.py" append-zeros-128 "$synthetic" "$WORKDIR/s-zeros.dump" >/dev/null
  # 已知盲区：追加**全 0** 时末 5 字节仍是 NUL ⇒ 尾判据**看不见**它。
  # 这里把它**钉成一条用例**：将来有人"顺手加一道全 0 检查"会在这里红，
  # 从而必须回来更新 backup-all.sh 的注释与本文件。它不是缺陷，是已知边界。
  check "S2e/append-zeros-128 is invisible to the tail criterion" "0" "$(tail_rc "$WORKDIR/s-zeros.dump")"

  "$PYTHON_BIN" "$SCRIPT_DIR/mutate.py" truncate-128 "$synthetic" "$WORKDIR/s-truncate.dump" >/dev/null
  check "S2f/truncate-128 shrinks by 128" "$((base_size - 128))" "$(stat -c %s "$WORKDIR/s-truncate.dump")"
  check "S2g/truncate-128 breaks the tail criterion" "1" "$(tail_rc "$WORKDIR/s-truncate.dump")"

  "$PYTHON_BIN" "$SCRIPT_DIR/mutate.py" flip-fraction 1/2 "$synthetic" "$WORKDIR/s-flip.dump" >/dev/null
  check "S2h/flip-fraction keeps size" "$base_size" "$(stat -c %s "$WORKDIR/s-flip.dump")"
  check "S2i/flip-fraction changes exactly 1 byte" "1" \
    "$(cmp -l "$synthetic" "$WORKDIR/s-flip.dump" | wc -l | tr -d ' ')"

  # 3) 注入器缺针时必须报错（不是静默产出未修改的文件）
  if "$PYTHON_BIN" "$SCRIPT_DIR/mutate.py" flip-needle "THIS-NEEDLE-DOES-NOT-EXIST" \
      "$synthetic" "$WORKDIR/s-miss.dump" >/dev/null 2>&1; then
    check "S3/flip-needle missing needle fails" "nonzero" "0"
  else
    check "S3/flip-needle missing needle fails" "nonzero" "nonzero"
  fi
  check "S3b/no output file on missing needle" "no" \
    "$([[ -e "$WORKDIR/s-miss.dump" ]] && echo yes || echo no)"

  # 4) 逐表计数 SQL 的两份副本必须逐字相同（D4：同一事实不做两处副本）
  #    lib.sh 里的是 backup-all.sh 的**逐字复制**；一旦上游改了，这里立刻红。
  local upstream_sql="$WORKDIR/counts-upstream.sql" local_sql="$WORKDIR/counts-local.sql"
  sed -n "/^emit_pg_table_counts_sql() {/,/^}/p" "$REPO_ROOT/scripts/linux/backup-all.sh" |
    sed -n "/cat <<'SQL'/,/^SQL$/p" | sed '1d;$d' >"$upstream_sql"
  emit_pg_table_counts_sql >"$local_sql"
  check "S4a/upstream counts SQL extracted" "yes" \
    "$([[ -s "$upstream_sql" ]] && echo yes || echo no)"
  check "S4b/counts SQL matches scripts/linux/backup-all.sh" "0" \
    "$(cmp -s "$upstream_sql" "$local_sql" && echo 0 || echo 1)"

  echo
  printf 'self-check: checked=%s failed=%s\n' "$checked" "$failed"
  if [[ "$failed" -ne 0 ]]; then
    echo "PG_DUMP_CRITERIA_SELF_CHECK=FAIL"
    exit 1
  fi
  echo "PG_DUMP_CRITERIA_SELF_CHECK=PASS"
}

# ---------------------------------------------------------------------------
# 正向
# ---------------------------------------------------------------------------
positive() {
  echo "=== 正向：迁移后的 schema + 夹具数据 -> pg_dump -Fc ==="
  create_database "$MAIN_DB"
  apply_migrations "" "$REPO_ROOT/drizzle" "$MAIN_DB"
  seed_main_fixtures

  create_database "$AUTH_DB"
  apply_migrations "--goose" "$REPO_ROOT/services/go-user-system/migrations" "$AUTH_DB"
  seed_auth_fixtures

  local main_dump="$WORKDIR/main.dump" auth_dump="$WORKDIR/auth.dump"
  pg_dump_db "$MAIN_DB" >"$main_dump"
  pg_dump_db "$AUTH_DB" >"$auth_dump"

  check "O1a/main dump non-empty" "yes" "$([[ -s "$main_dump" ]] && echo yes || echo no)"
  check "O1b/auth dump non-empty" "yes" "$([[ -s "$auth_dump" ]] && echo yes || echo no)"
  echo "      main dump bytes=$(stat -c %s "$main_dump") auth dump bytes=$(stat -c %s "$auth_dump")"

  local main_tables auth_tables main_captures
  main_tables="$(table_counts "$MAIN_DB" | wc -l | tr -d ' ')"
  auth_tables="$(table_counts "$AUTH_DB" | wc -l | tr -d ' ')"
  main_captures="$(run_psql "$MAIN_DB" --tuples-only --no-align --command='SELECT count(*) FROM captures;' | tr -d '[:space:]')"
  observe "O2a/main tables with fixtures" "$main_tables"
  observe "O2b/auth tables with fixtures" "$auth_tables"
  check "O2c/main table count > 0 (empty denominator)" "yes" "$([[ "$main_tables" -gt 0 ]] && echo yes || echo no)"
  check "O2d/auth table count > 0 (empty denominator)" "yes" "$([[ "$auth_tables" -gt 0 ]] && echo yes || echo no)"
  check "O2e/main captures rows == 3" "3" "$main_captures"

  # 三道门 + 尾判据（backup-all.sh 的 4 门）
  check "O3a/main  --list exit" "0" "$(list_rc "$main_dump")"
  check "O3b/main  --data-only --file=/dev/null exit" "0" "$(data_only_rc "$main_dump")"
  check "O3c/main  full --file=/dev/null exit" "0" "$(full_rc "$main_dump")"
  check "O3d/main  tail 5 bytes are NUL" "0" "$(tail_rc "$main_dump")"

  check "O3e/auth  --list exit" "0" "$(list_rc "$auth_dump")"
  check "O3f/auth  --data-only --file=/dev/null exit" "0" "$(data_only_rc "$auth_dump")"
  check "O3g/auth  full --file=/dev/null exit" "0" "$(full_rc "$auth_dump")"
  check "O3h/auth  tail 5 bytes are NUL" "0" "$(tail_rc "$auth_dump")"

  # TOC 头自述库名（verify-restore.sh 的 A1/A2 判据的数据来源）
  check "O3i/main  TOC head dbname" "$MAIN_DB" "$(dump_dbname "$main_dump")"
  check "O3j/auth  TOC head dbname" "$AUTH_DB" "$(dump_dbname "$auth_dump")"

  # 真实恢复 + 逐表计数逐字节比对（verify-restore.sh 的核心判据）
  local restore_rc
  create_database "$RESTORE_MAIN_DB"
  if pg_restore_in_container --dbname="$RESTORE_MAIN_DB" --no-owner --no-privileges \
      --exit-on-error <"$main_dump" >"$WORKDIR/main-restore.log" 2>&1; then
    restore_rc=0
  else
    restore_rc=$?
  fi
  check "O4a/main  real restore exit" "0" "$restore_rc"
  table_counts "$MAIN_DB" >"$WORKDIR/main-counts.tsv"
  table_counts "$RESTORE_MAIN_DB" >"$WORKDIR/main-restored-counts.tsv"
  check "O4b/main  counts cmp (backup vs restored)" "0" \
    "$(cmp -s "$WORKDIR/main-counts.tsv" "$WORKDIR/main-restored-counts.tsv" && echo 0 || echo 1)"
  check "O4c/main  restored captures rows == 3" "3" \
    "$(run_psql "$RESTORE_MAIN_DB" --tuples-only --no-align --command='SELECT count(*) FROM captures;' | tr -d '[:space:]')"

  create_database "$RESTORE_AUTH_DB"
  if pg_restore_in_container --dbname="$RESTORE_AUTH_DB" --no-owner --no-privileges \
      --exit-on-error <"$auth_dump" >"$WORKDIR/auth-restore.log" 2>&1; then
    restore_rc=0
  else
    restore_rc=$?
  fi
  check "O4d/auth  real restore exit" "0" "$restore_rc"
  table_counts "$AUTH_DB" >"$WORKDIR/auth-counts.tsv"
  table_counts "$RESTORE_AUTH_DB" >"$WORKDIR/auth-restored-counts.tsv"
  check "O4e/auth  counts cmp (backup vs restored)" "0" \
    "$(cmp -s "$WORKDIR/auth-counts.tsv" "$WORKDIR/auth-restored-counts.tsv" && echo 0 || echo 1)"

  echo "--- 主应用逐表计数清单（备份端）---"
  cat "$WORKDIR/main-counts.tsv"

  cp "$main_dump" "$WORKDIR/base.dump"
}

# 把「某个注入文件在 4 条路径上的退出码」一次性打出来。供观察与失败诊断。
report_all_doors() {
  local label="$1" file="$2"
  printf 'DOORS %-28s list=%s data_only=%s full=%s tail=%s\n' \
    "$label" "$(list_rc "$file")" "$(data_only_rc "$file")" "$(full_rc "$file")" "$(tail_rc "$file")"
}

observed_tail_append() {
  echo
  echo "=== 观察：尾部追加（判据边界，**不断言**三条 pg_restore 路径会失败）==="
  local random_file="$WORKDIR/append-random.dump" zeros_file="$WORKDIR/append-zeros.dump"
  "$PYTHON_BIN" "$SCRIPT_DIR/mutate.py" append-random-128 "$WORKDIR/base.dump" "$random_file"
  "$PYTHON_BIN" "$SCRIPT_DIR/mutate.py" append-zeros-128 "$WORKDIR/base.dump" "$zeros_file"

  report_all_doors "append-random-128" "$random_file"
  report_all_doors "append-zeros-128" "$zeros_file"

  # 关键观察：PG 18 上「追加后真实恢复」到底成不成功、数据是否完整。
  # backup-all.sh 的注释引用了「权威验证方在 PG 18 上观察到数据只剩 2 张表」。
  local observed_db="knowtrace_ci_append_observed" restore_rc=0 counts_cmp="n/a"
  run_psql postgres --command="DROP DATABASE IF EXISTS \"$observed_db\";" >/dev/null
  run_psql postgres --command="CREATE DATABASE \"$observed_db\";" >/dev/null
  if pg_restore_in_container --dbname="$observed_db" --no-owner --no-privileges \
      --exit-on-error <"$random_file" >"$WORKDIR/append-restore.log" 2>&1; then
    restore_rc=0
  else
    restore_rc=$?
  fi
  table_counts "$observed_db" >"$WORKDIR/append-restored-counts.tsv"
  if cmp -s "$WORKDIR/main-counts.tsv" "$WORKDIR/append-restored-counts.tsv"; then
    counts_cmp=0
  else
    counts_cmp=1
  fi
  observe "O5a/append-random real restore exit" "$restore_rc"
  observe "O5b/append-random restored table count" "$(wc -l <"$WORKDIR/append-restored-counts.tsv" | tr -d ' ')"
  observe "O5c/append-random counts cmp vs backup" "$counts_cmp"
  echo "--- append-random 真实恢复日志（末尾 10 行）---"
  tail -n 10 "$WORKDIR/append-restore.log" || true

  # TOC 头部区域翻 1 字节：backup-all.sh 注释里写明「未覆盖」的那一类。
  local header_file="$WORKDIR/header-flip.dump"
  "$PYTHON_BIN" "$SCRIPT_DIR/mutate.py" flip-fraction 1/100 "$WORKDIR/base.dump" "$header_file"
  report_all_doors "flip-fraction-1/100" "$header_file"

  # 压缩开关的观察：-Z0 的 dump 里能直接看到 TOC 明文，用于证明
  # 「负向 3 的 needle 定位在这份 dump 上是否可用」。
  local no_compress="$WORKDIR/main-z0.dump"
  pg_exec pg_dump --host="$PGHOST_IN_CONTAINER" --port="$PGPORT_IN_CONTAINER" \
    --username="$PGUSER" --dbname="$MAIN_DB" --format=custom --no-owner --no-privileges \
    --compress=0 >"$no_compress"
  observe "O6a/-Z0 dump contains plaintext 'TABLE DATA public captures'" \
    "$(if grep -a -q 'TABLE DATA public captures' "$no_compress"; then echo yes; else echo no; fi)"
}

# ---------------------------------------------------------------------------
# 负向
# ---------------------------------------------------------------------------
negative() {
  [[ -s "$WORKDIR/base.dump" ]] || die "negative mode needs $WORKDIR/base.dump from the positive step"

  echo
  echo "=== 负向 1：尾部追加 128B 固定种子随机字节 -> 末 5 字节判据必须失败 ==="
  local append_file="$WORKDIR/neg-append.dump"
  "$PYTHON_BIN" "$SCRIPT_DIR/mutate.py" append-random-128 "$WORKDIR/base.dump" "$append_file"
  check "N1/appended dump is larger" "yes" \
    "$([[ "$(stat -c %s "$append_file")" -gt "$(stat -c %s "$WORKDIR/base.dump")" ]] && echo yes || echo no)"
  check "N1/tail-5-bytes criterion rejects append" "1" "$(tail_rc "$append_file")"
  report_all_doors "N1-append-128" "$append_file"

  echo
  echo "=== 负向 2：尾部截断 128B -> --data-only 或全量必须失败 ==="
  local truncate_file="$WORKDIR/neg-truncate.dump"
  "$PYTHON_BIN" "$SCRIPT_DIR/mutate.py" truncate-128 "$WORKDIR/base.dump" "$truncate_file"
  local data_only truncate_full truncate_list
  data_only="$(data_only_rc "$truncate_file")"
  truncate_full="$(full_rc "$truncate_file")"
  truncate_list="$(list_rc "$truncate_file")"
  check "N2/data-only or full rejects truncation" "yes" \
    "$(if [[ "$data_only" -ne 0 || "$truncate_full" -ne 0 ]]; then echo yes; else echo no; fi)"
  observe "N2a/truncate --list exit" "$truncate_list"
  observe "N2b/truncate --data-only exit" "$data_only"
  observe "N2c/truncate full exit" "$truncate_full"

  echo
  echo "=== 负向 3：数据区翻 1 字节 -> **真实恢复验证**必须失败 ==="
  # 注入点：**压缩后的** base.dump 的 9/10 处。理由（为什么不按 needle 精确定位）：
  #   custom 归档的 TOC 在文件开头、数据块在其后；TOC 只有几 KB，而本 dump 的 schema
  #   与数据块占绝大部分，9/10 处必然落在某个**压缩数据块**内。
  #   ⚠️ needle 模式只对 `-Z0` 的 dump 可用，而 `-Z0` 没有压缩、**没有完整性校验**，
  #      在那种 dump 上翻数据字节**不会**让任何读取路径失败 —— 那会把用例变成一个假的期望。
  #   注入与偏移都是**确定性**的（固定文件 + 固定比例），故结果可稳定复现。
  #
  # 期望值为什么改成「真实恢复」而不是「全量 --file=/dev/null」（2026-10-19）：
  #   CI run 39258948661（PG 18）实测 `full=0` —— 全量 `--file=/dev/null` **不报**数据区损坏
  #   （同一注入在 PG 17.11 上是 1）。把这条件当判据，等于让一份坏归档在 PG 18 上放行。
  #   真正能拦住它的是「把数据灌进一个库，再逐表 count(*) 比对」—— 与
  #   `scripts/linux/backup-all.sh` 的 verify_dump_by_real_restore 同一口径。
  #   `full` 与另外两条结构路径**只观察**（打印在 DOORS 行里，不计失败）。
  local data_flip_file="$WORKDIR/neg-dataflip.dump"
  "$PYTHON_BIN" "$SCRIPT_DIR/mutate.py" flip-fraction 9/10 "$WORKDIR/base.dump" "$data_flip_file"
  check "N3/injection produced a mutated dump of same size" "yes" \
    "$([[ "$(stat -c %s "$data_flip_file")" -eq "$(stat -c %s "$WORKDIR/base.dump")" ]] && echo yes || echo no)"
  check "N3/real restore verification rejects data flip" "1" \
    "$(real_restore_verify_rc "$data_flip_file" "neg-dataflip-restore")"
  report_all_doors "N3-data-flip" "$data_flip_file"
  observe "N3-note/reason" "PG 18 上全量 --file=/dev/null 不报数据区损坏（见 run-criteria.sh 注释），故必须靠真实恢复"
  echo "--- 数据区翻转后真实恢复日志（末尾 10 行）---"
  tail -n 10 "$WORKDIR/neg-dataflip-restore.log" || true

  echo
  echo "=== 负向 4：空库 dump -> *-counts.tsv 为空 -> 备份端必须拒绝 ==="
  # 对应 backup-all.sh 的判据：
  #   [[ -s "$incomplete_dir/postgres-counts.tsv" ]] || die "…逐表计数为空…"
  local empty_db="knowtrace_ci_empty" empty_dump="$WORKDIR/neg-empty.dump" backup_gate
  create_database "$empty_db"
  pg_dump_db "$empty_db" >"$empty_dump"
  table_counts "$empty_db" | sed '/^[[:space:]]*$/d' | sort >"$WORKDIR/neg-empty-counts.tsv"
  check "N4a/empty dump is non-empty (a dump was produced)" "yes" \
    "$([[ -s "$empty_dump" ]] && echo yes || echo no)"
  check "N4b/empty db table count" "0" "$(wc -l <"$WORKDIR/neg-empty-counts.tsv" | tr -d ' ')"
  # 复刻备份端的判据：`-s` 为假即拒绝落归档。
  if [[ -s "$WORKDIR/neg-empty-counts.tsv" ]]; then backup_gate=0; else backup_gate=1; fi
  check "N4c/backup gate rejects empty counts" "1" "$backup_gate"
  observe "N4d/empty dump --list exit" "$(list_rc "$empty_dump")"
  observe "N4e/empty dump tail-5-bytes exit" "$(tail_rc "$empty_dump")"

  echo
  echo "=== 汇总 ==="
  printf 'checked=%s failed=%s\n' "$checked" "$failed"
  if [[ "$failed" -ne 0 ]]; then
    echo "PG_DUMP_CRITERIA=FAIL"
    exit 1
  fi
  echo "PG_DUMP_CRITERIA=PASS"
}

case "$MODE" in
  self-check)
    self_check
    ;;
  positive)
    positive
    observed_tail_append
    printf '\npositive phase done: checked=%s failed=%s\n' "$checked" "$failed"
    if [[ "$failed" -ne 0 ]]; then
      echo "PG_DUMP_CRITERIA_POSITIVE=FAIL"
      exit 1
    fi
    echo "PG_DUMP_CRITERIA_POSITIVE=PASS"
    ;;
  negative)
    negative
    ;;
  *)
    die "unknown mode: $MODE"
    ;;
esac
