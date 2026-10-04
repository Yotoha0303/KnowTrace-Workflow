#!/usr/bin/env bash
set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_directory="${PROJECT_DIR:-$(cd -- "$script_directory/../.." && pwd -P)}"
backup_root="${BACKUP_ROOT:-/var/backups/knowtrace}"
textfile_directory="$project_directory/runtime/node-exporter"

install -d -m 755 "$textfile_directory"
output_path="$textfile_directory/knowtrace-backup.prom"
temporary_path="$(mktemp "$textfile_directory/.knowtrace-backup.XXXXXX")"
trap 'rm -f -- "$temporary_path"' EXIT

mapfile -t archives < <(find "$backup_root" -maxdepth 1 -type f -name 'knowtrace-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn)
archive_count="${#archives[@]}"
latest_timestamp=0
latest_size=0

if (( archive_count > 0 )); then
  latest_path="${archives[0]#* }"
  latest_timestamp="$(stat -c %Y -- "$latest_path")"
  latest_size="$(stat -c %s -- "$latest_path")"
fi

{
  echo '# HELP knowtrace_backup_last_success_timestamp_seconds Unix timestamp of the newest complete KnowTrace backup archive.'
  echo '# TYPE knowtrace_backup_last_success_timestamp_seconds gauge'
  echo "knowtrace_backup_last_success_timestamp_seconds $latest_timestamp"
  echo '# HELP knowtrace_backup_archive_count Number of complete KnowTrace backup archives on the VPS.'
  echo '# TYPE knowtrace_backup_archive_count gauge'
  echo "knowtrace_backup_archive_count $archive_count"
  echo '# HELP knowtrace_backup_latest_size_bytes Size of the newest complete KnowTrace backup archive.'
  echo '# TYPE knowtrace_backup_latest_size_bytes gauge'
  echo "knowtrace_backup_latest_size_bytes $latest_size"
} >"$temporary_path"

chmod 644 "$temporary_path"
mv -f -- "$temporary_path" "$output_path"
trap - EXIT
echo "已更新 Node Exporter 备份指标：$output_path"
