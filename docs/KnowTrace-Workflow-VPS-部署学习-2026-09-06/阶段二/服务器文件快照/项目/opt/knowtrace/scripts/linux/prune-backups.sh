#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/knowtrace}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
MIN_KEEP="${MIN_KEEP:-7}"

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

for command_name in find flock sort awk rm readlink; do
  command -v "$command_name" >/dev/null 2>&1 || die "缺少命令: $command_name"
done

[[ "$BACKUP_ROOT" = /* ]] || die "BACKUP_ROOT 必须是绝对路径"
[[ -d "$BACKUP_ROOT" ]] || die "备份目录不存在: $BACKUP_ROOT"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "RETENTION_DAYS 必须是非负整数"
[[ "$MIN_KEEP" =~ ^[1-9][0-9]*$ ]] || die "MIN_KEEP 必须是正整数"

resolved_root="$(readlink -f -- "$BACKUP_ROOT")"
[[ -n "$resolved_root" && "$resolved_root" != "/" ]] || die "拒绝在根目录执行保留策略"

exec 9>"$resolved_root/.backup.lock"
flock -n 9 || die "备份或保留任务正在运行"

mapfile -t archives < <(
  find "$resolved_root" -mindepth 1 -maxdepth 1 -type f \
    -name 'knowtrace-*.tar.gz' -printf '%T@\t%f\n' \
    | sort -n \
    | awk -F '\t' '{print $2}'
)

remaining="${#archives[@]}"
deleted=0

for archive_name in "${archives[@]}"; do
  (( remaining > MIN_KEEP )) || break
  [[ "$archive_name" =~ ^knowtrace-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\.tar\.gz$ ]] \
    || die "发现不符合命名规则的候选归档: $archive_name"

  archive_path="$resolved_root/$archive_name"
  if [[ -z "$(find "$archive_path" -maxdepth 0 -type f -mtime "+$RETENTION_DAYS" -print)" ]]; then
    continue
  fi

  backup_id="${archive_name%.tar.gz}"
  bundle_dir="$resolved_root/$backup_id"
  [[ "$bundle_dir" == "$resolved_root"/knowtrace-* ]] || die "拒绝删除越界目录: $bundle_dir"

  log "删除超过 ${RETENTION_DAYS} 天的备份集: $backup_id"
  rm -f -- \
    "$archive_path" \
    "$archive_path.sha256" \
    "$archive_path.age" \
    "$archive_path.age.sha256"
  if [[ -d "$bundle_dir" ]]; then
    rm -rf -- "$bundle_dir"
  fi

  ((remaining -= 1))
  ((deleted += 1))
done

log "保留策略完成: deleted=$deleted remaining=$remaining minimum=$MIN_KEEP retention_days=$RETENTION_DAYS"
