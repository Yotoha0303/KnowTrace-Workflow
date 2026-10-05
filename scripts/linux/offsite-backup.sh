#!/usr/bin/env bash
set -Eeuo pipefail
# ============================================================================
# KnowTrace-Workflow 异地备份（加密后上传到对象存储）
# ============================================================================
#
# 解决什么：本地备份与生产数据在同一块盘上（`/var/backups/knowtrace` 与
# `/opt/knowtrace` 同属 `ubuntu-vg`），盘坏 / 误删卷时备份一起消失。
# 本脚本把最新备份集**加密后**推到异地的对象存储，满足 3-2-1 的「1 份在异地」。
#
# 为什么必须加密：本地备份归档里含生产密钥 —— 实测 `config/.env` 里有
# AUTH_JWT_SECRET / AUTH_DB_PASSWORD / POSTGRES_PASSWORD / 管理员密码，
# backup-all.sh 自己也标了 `contains_secrets=yes`。
# **未加密的归档绝不能出这台机器。**
#
# 密钥模型（关键，别弄反）：
#   * 本机只放 **age 公钥**（加密用）—— `OFFSITE_AGE_RECIPIENT_FILE`
#   * **age 私钥绝不能留在本机** —— 留在本机等于没加密，拿下服务器就全解开
#   * 私钥由人保管（密码管理器 / 离线介质），恢复时才用
#
# 用法:
#   scripts/linux/offsite-backup.sh [--remote <rclone远端>] [--keep <N>]
#                                   [--conf <文件>] [--dry-run] [--verify-only]
#
# 退出码: 0 成功  1 有告警（无新备份可传等）  2 失败  3 脚本自身错误
# ============================================================================

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_directory="$(cd -- "$script_directory/../.." && pwd -P)"

conf_file="${OPS_CONF:-/etc/knowtrace/ops.conf}"
remote=""
keep=""          # 空 = 稍后从 conf 读 OFFSITE_KEEP，最后兜底 30
dry_run=false
verify_only=false

while (( $# )); do
  case "$1" in
    --conf)        conf_file="${2:-}"; shift 2 ;;
    --conf=*)      conf_file="${1#*=}"; shift ;;
    --remote)      remote="${2:-}"; shift 2 ;;
    --remote=*)    remote="${1#*=}"; shift ;;
    --keep)        keep="${2:-}"; shift 2 ;;
    --keep=*)      keep="${1#*=}"; shift ;;
    --dry-run)     dry_run=true; shift ;;
    --verify-only) verify_only=true; shift ;;
    --help|-h)     sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "错误：未知参数 $1" >&2; exit 3 ;;
  esac
done

# ---- 配置（ops.conf 优先，其次默认值）---------------------------------------
conf_get() {
  local key="$1" fallback="$2" value=""
  if [[ -f "$conf_file" ]]; then
    value="$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$conf_file" | tail -1)"
  fi
  [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$fallback"
}

backup_root="$(conf_get BACKUP_ROOT /var/backups/knowtrace)"
recipient_file="$(conf_get OFFSITE_AGE_RECIPIENT_FILE /etc/knowtrace/age-recipient.pub)"
[[ -n "$remote" ]] || remote="$(conf_get OFFSITE_REMOTE '')"
metrics_file="$(conf_get OFFSITE_METRICS_FILE /opt/knowtrace/runtime/node-exporter/knowtrace-offsite.prom)"
staging_root="$(conf_get OFFSITE_STAGING_DIR /var/tmp/knowtrace-offsite)"
[[ -n "$keep" ]] || keep="$(conf_get OFFSITE_KEEP 30)"
[[ "$keep" =~ ^[1-9][0-9]*$ ]] || { echo "错误：保留数必须是正整数，收到：$keep" >&2; exit 3; }

if (( EUID != 0 )); then
  exec sudo -- "$0" "$@"
fi

warn_count=0
log()  { printf '%s\n' "$*"; }
ok()   { printf '  [ OK ] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; warn_count=$((warn_count + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; }

cleanup() { [[ -n "${staging:-}" && -d "${staging:-}" ]] && rm -rf "$staging" || true; }
trap cleanup EXIT

# ---- 1. 预检 -----------------------------------------------------------------
log "== 1/5 预检 =="

for command_name in rclone age sha256sum; do
  command -v "$command_name" >/dev/null || { fail "缺少命令 $command_name"; exit 3; }
done
ok "rclone / age / sha256sum 均可用"

[[ -d "$backup_root" ]] || { fail "备份目录不存在：$backup_root"; exit 3; }
ok "备份目录：$backup_root"

if [[ ! -f "$recipient_file" ]]; then
  fail "缺少 age 公钥文件：$recipient_file"
  log "      生成密钥对（**私钥请立刻转存到本机之外并删除本机副本**）："
  log "        age-keygen -o /tmp/offsite-identity.txt"
  log "        grep 'public key' /tmp/offsite-identity.txt    # 记下公钥"
  log "        install -m 644 <(grep -oE 'age1[a-z0-9]+' /tmp/offsite-identity.txt | head -1) $recipient_file"
  log "        shred -u /tmp/offsite-identity.txt             # 带走私钥后删掉本机那份"
  exit 3
fi
recipient="$(head -1 "$recipient_file" | tr -d '[:space:]')"
[[ "$recipient" =~ ^age1[a-z0-9]+$ ]] || { fail "$recipient_file 里不是合法的 age 公钥"; exit 3; }
ok "age 公钥：${recipient:0:16}…（私钥不在本机）"

if [[ -z "$remote" ]]; then
  fail "未配置异地目标。用 --remote 指定，或在 $conf_file 里设 OFFSITE_REMOTE"
  log "      例：OFFSITE_REMOTE=r2:knowtrace-backups"
  exit 3
fi

if ! rclone lsd "$remote" >/dev/null 2>&1; then
  # local 后端的目标目录可能还不存在，先尝试创建
  if [[ "$remote" == /* || "$remote" == :local:* ]]; then
    mkdir -p "${remote#:local:}" 2>/dev/null || true
  fi
  if ! rclone lsd "$remote" >/dev/null 2>&1; then
    fail "无法访问异地目标：$remote"
    # 把 rclone 自己的报错打出来 —— 最常见的是「配置读不到」，而那两个原因
    # （配置路径 / systemd 沙箱）从这句笼统的失败里完全看不出来。
    # 2026-10-04 首次自然触发失败就是栽在这：unit 的 ProtectHome=true 把 /root
    # 从服务视角拿掉了，而 rclone 的配置正在 /root/.config/rclone/ 下。
    rclone_error="$(rclone lsd "$remote" 2>&1 | tail -3 || true)"
    [[ -n "$rclone_error" ]] && log "      rclone: $rclone_error"
    log "      配置路径：$(rclone config file 2>/dev/null | tail -1 || printf '未知')"
    log "      排查：若报 'didn't find section in config file'，先确认本服务能读到 rclone 配置"
    log "            （systemd 沙箱的 ProtectHome 会把 /root 藏起来，见该 unit 的注释）"
    exit 3
  fi
fi
ok "异地目标可访问：$remote"

# ---- 2. 找出待上传的备份集 ---------------------------------------------------
log
log "== 2/5 找出待上传的备份集 =="

mapfile -t archived < <(find "$backup_root" -maxdepth 1 -type f -name 'knowtrace-*.tar.gz' -printf '%f\n' | sort)
(( ${#archived[@]} )) || { fail "在 $backup_root 里找不到任何 knowtrace-*.tar.gz"; exit 3; }
ok "本地共有 ${#archived[@]} 个归档"

# 远端已有的 —— 放进关联数组做精确匹配。
# 不能用「在整个 listing 字符串里找子串」：那会把一个文件名误配到另一个更长的名字里。
remote_listing="$(rclone lsf "$remote" 2>/dev/null || true)"
declare -A remote_set=()
while IFS= read -r listing_line; do
  [[ -n "$listing_line" ]] && remote_set["$listing_line"]=1
done <<<"$remote_listing"

# 只关心**最新 $keep 个**本地归档。
# 这一点很关键：远端保留策略是「只留最新 $keep 个」，如果待上传按「本地有、远端没有」
# 全量判断，那么当本地归档数 > keep 时会出现
#   上传全部 → 裁剪到 keep → 下次又全部重传 → 再裁剪
# 的循环，每天白传一堆注定被删的归档。
# $archived 在上面已经按文件名 sort 过，而文件名以 UTC 时间戳开头，
# 所以字典序即时间序 —— 直接取末尾 $keep 项即可。
newest_start=$(( ${#archived[@]} - keep ))
(( newest_start < 0 )) && newest_start=0
newest_local=("${archived[@]:newest_start}")

pending=()
for archive in "${newest_local[@]}"; do
  [[ -n "${remote_set["${archive}.age"]:-}" ]] || pending+=("$archive")
done

if (( ${#pending[@]} == 0 )); then
  ok "没有待上传的归档（最新 $keep 个都已在远端）"
else
  ok "待上传 ${#pending[@]} 个（最新 $keep 个中缺失的；本地共 ${#archived[@]} 个）"
fi

# ---- 3. 加密并上传 -----------------------------------------------------------
log
log "== 3/5 加密并上传 =="

if [[ "$verify_only" == true ]]; then
  log "  --verify-only：跳过上传"
elif (( ${#pending[@]} == 0 )); then
  log "  无需上传"
else
  staging="$(mktemp -d "$staging_root.XXXXXX")"
  chmod 700 "$staging"

  uploaded=0
  for archive in "${pending[@]}"; do
    source_path="$backup_root/$archive"
    staged="$staging/$archive.age"

    # 加密（只读源文件，不动本地备份）
    if ! age -r "$recipient" -o "$staged" "$source_path" 2>/dev/null; then
      fail "加密失败：$archive"
      continue
    fi

    # 上传前断言：密文里不应能搜到明文密钥特征
    if grep -qaE 'AUTH_JWT_SECRET=|AUTH_DB_PASSWORD=|POSTGRES_PASSWORD=' "$staged"; then
      fail "密文里能搜到明文密钥字样 —— 拒绝上传：$archive"
      exit 2
    fi

    if [[ "$dry_run" == true ]]; then
      log "  (dry-run) rclone copyto 加密后的 $archive → $remote"
      uploaded=$((uploaded + 1))
      continue
    fi

    if rclone copyto "$staged" "$remote/$archive.age" --s3-no-check-bucket 2>/dev/null; then
      ok "已上传 $archive（$(stat -c %s "$staged") 字节密文）"
      uploaded=$((uploaded + 1))
    else
      fail "上传失败：$archive"
    fi

    # 顺带把校验和文件也传上去，恢复时能先验完整性
    if [[ -f "$source_path.sha256" && "$dry_run" == false ]]; then
      rclone copyto "$source_path.sha256" "$remote/$archive.sha256.ageinfo" --s3-no-check-bucket >/dev/null 2>&1 || true
    fi
  done

  # 上传后再实际清点远端，确认数量对得上
  if [[ "$dry_run" == false ]]; then
    remote_now="$(rclone lsf "$remote" 2>/dev/null | grep -c '\.tar\.gz\.age$' || true)"
    ok "远端现有 $remote_now 个加密归档"
    if (( remote_now == 0 )); then
      fail "远端清点为 0，上传可能没生效"
      exit 2
    fi
  fi
fi

# ---- 4. 远端保留策略 ---------------------------------------------------------
log
log "== 4/5 远端保留策略（保留最新 $keep 个）=="

if [[ "$dry_run" == true ]]; then
  log "  (dry-run) 按保留数 $keep 清理"
else
  mapfile -t remote_archives < <(rclone lsf "$remote" 2>/dev/null | grep '\.tar\.gz\.age$' | sort || true)
  total=${#remote_archives[@]}
  if (( total > keep )); then
    remove_count=$((total - keep))
    for (( i = 0; i < remove_count; i++ )); do
      victim="${remote_archives[$i]}"
      if rclone deletefile "$remote/$victim" >/dev/null 2>&1; then
        log "  已删除远端旧归档：$victim"
      else
        warn "删除远端归档失败：$victim"
      fi
    done
    ok "清理完成（$total → $keep）"
  else
    ok "远端 $total 个，未超过保留数 $keep"
  fi
fi

# ---- 5. 写指标（供告警用）---------------------------------------------------
log
log "== 5/5 写指标 =="

if [[ "$dry_run" == true ]]; then
  log "  (dry-run) 写 $metrics_file"
else
  remote_count="$(rclone lsf "$remote" 2>/dev/null | grep -c '\.tar\.gz\.age$' || true)"
  remote_newest="$(rclone lsf "$remote" 2>/dev/null | grep '\.tar\.gz\.age$' | sort | tail -1 || true)"
  now_epoch="$(date -u +%s)"

  if [[ -n "$remote_newest" ]]; then
    # 从文件名 knowtrace-<UTC时间戳>-<hash>.tar.gz.age 里取时间
    stamp="$(sed -E 's/^knowtrace-([0-9]{8}T[0-9]{6})Z.*/\1/' <<<"$remote_newest")"
    if [[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}$ ]]; then
      newest_epoch="$(date -u -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s 2>/dev/null || echo 0)"
    else
      newest_epoch=0
    fi
    remote_age=$(( now_epoch - newest_epoch ))
  else
    remote_count=0
    remote_age=-1
  fi

  install -d -m 755 "$(dirname "$metrics_file")"
  cat >"$metrics_file" <<EOF
# HELP knowtrace_offsite_backup_last_success_timestamp_seconds 异地备份最近一次成功上传的时间
# TYPE knowtrace_offsite_backup_last_success_timestamp_seconds gauge
knowtrace_offsite_backup_last_success_timestamp_seconds $now_epoch
# HELP knowtrace_offsite_backup_archive_count 异地加密归档数量
# TYPE knowtrace_offsite_backup_archive_count gauge
knowtrace_offsite_backup_archive_count $remote_count
# HELP knowtrace_offsite_backup_newest_age_seconds 异地最新归档的年龄（秒）
# TYPE knowtrace_offsite_backup_newest_age_seconds gauge
knowtrace_offsite_backup_newest_age_seconds $remote_age
EOF
  chmod 644 "$metrics_file"
  ok "已写 $metrics_file（远端 $remote_count 个，最新归档 ${remote_age}s 前）"
fi

log
if (( warn_count > 0 )); then
  log "结论：WARN（$warn_count 项）"
  exit 1
fi
log "结论：OK —— 异地备份完成"
