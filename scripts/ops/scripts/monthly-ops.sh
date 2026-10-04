#!/usr/bin/env bash
# ============================================================================
# KnowTrace-Workflow 每月运维（默认只出计划，--apply 才执行写操作）
# ============================================================================
#
# 对应文档：
#   docs/日常运维/日常运维清单.md（第 160-164 行「日常频率建议」的每月部分）
#   docs/KnowTrace-Workflow-VPS-部署学习-2026-09-06/阶段二/文档/07-备份巡检与故障处理SOP.md
#
# 每月清单（原文）：
#   隔离恢复演练、依赖更新检查、故障记录复盘、文档更新
#
# ⚠ 安全模型（这是本脚本与 daily/weekly 最大的区别）
#   写操作必须同时满足四个条件才执行，缺一即降级为「只出计划」：
#     1. 命令行给了 --apply            （不带 = 演练模式，只检查不动作）
#     2. ops.conf 里对应开关为 1        （MONTHLY_RESTORE_DRILL / MONTHLY_PRUNE_BACKUPS / ...）
#     3. 没有用 --without-<动作> 关掉它  （--with-<动作> 可在本次强制打开）
#     4. 当前小时落在 MONTHLY_WRITE_WINDOW 内（若配置了窗口）
#   需要交互确认的动作还会先要求输入 yes（--yes 可跳过，供定时任务使用）。
#
#   写操作清单（都可单独开关）：
#     restore-drill  隔离恢复演练 -> verify-restore.sh（在 network none 的临时容器里做，不碰生产）
#     prune-backups  备份保留策略 -> prune-backups.sh（删除超过 RETENTION_DAYS 的备份）
#     stop-logs      停止日志栈      -> docker compose stop loki alloy（内存/磁盘吃紧时释放资源）
#     archive-logs   日志归档      （把报告与日志转到 LOG_ARCHIVE_DIR/<年月>/）
#     report         汇总报告      -> ops-report.py（只写报告文件）
#
#   刻意不做自动化的动作：
#     * apt 升级：即使 --apply 也要再加 --apply-updates 才会执行。依赖升级在生产上
#       属于高风险变更，本脚本默认只做「检查并列出」。
#     * 重启系统：只提示，不执行。
#
# 只读检查（任何模式下都做）：
#   演练前置条件、备份保留姿态、日志栈（PLG）资源占用、依赖更新检查、故障记录完整性、
#   文档新鲜度、报告闭环。
#
# 退出码：0=无异常  1=存在 WARN  2=存在 FAIL  3=脚本自身错误
# ============================================================================

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/ops-common.sh
source "$SCRIPT_DIR/../lib/ops-common.sh"

usage() {
    cat <<'EOF'
KnowTrace-Workflow 每月运维（默认演练模式）

用法:
  ./scripts/monthly-ops.sh [选项]

模式:
  （默认）        演练模式：只做只读检查并列出「将要执行」的动作，不改变任何东西
  --apply         真正执行写操作（还需满足 ops.conf 开关与时间窗口）

动作开关（在 --apply 下生效）:
  --with-restore-drill / --without-restore-drill     隔离恢复演练
  --with-prune-backups / --without-prune-backups     备份保留策略（会删除旧备份）
  --with-stop-logs / --without-stop-logs             停止日志栈（Loki+Alloy）
  --with-archive-logs / --without-archive-logs       日志与报告归档
  --with-report / --without-report                   汇总报告

更新相关:
  --apply-updates                    真的执行 apt 升级（未给则只检查并列出）

通用:
  --conf <文件>      指定 ops.conf
  --json <文件>      写出 JSON 报告
  --markdown <文件>  写出 Markdown 报告
  --no-json          不写 JSON 报告
  --yes              跳过交互确认（供定时任务使用）
  --quiet, -q        只输出 WARN/FAIL
  --no-color         关闭彩色输出
  --write-record     额外生成月度运维记录骨架
  --record           --write-record 的别名（与 daily-ops.sh 一致）
  --help, -h         显示本帮助

退出码:
  0 未发现异常   1 存在 WARN   2 存在 FAIL
EOF
}

MONTHLY_APPLY=0
MONTHLY_APPLY_UPDATES=0
MONTHLY_ASSUME_YES=0
MONTHLY_WRITE_RECORD=0
declare -A MONTHLY_OVERRIDE=()

_margs=()
while (( $# )); do
    case "$1" in
        --apply)            MONTHLY_APPLY=1; shift ;;
        --apply-updates)    MONTHLY_APPLY_UPDATES=1; shift ;;
        --yes|-y)           MONTHLY_ASSUME_YES=1; shift ;;
        --write-record)     MONTHLY_WRITE_RECORD=1; shift ;;
        --record)           MONTHLY_WRITE_RECORD=1; shift ;;   # 与 daily-ops.sh 保持一致
        --with-*)           MONTHLY_OVERRIDE["${1#--with-}"]=1; shift ;;
        --without-*)        MONTHLY_OVERRIDE["${1#--without-}"]=0; shift ;;
        --markdown)         ops_require_value "$@"; MONTHLY_MARKDOWN="$2"; shift 2 ;;
        --markdown=*)       MONTHLY_MARKDOWN="${1#*=}"; shift ;;
        *)                  _margs+=("$1"); shift ;;
    esac
done
MONTHLY_MARKDOWN="${MONTHLY_MARKDOWN:-}"
ops_parse_common_args "${_margs[@]}"
[[ "${OPS_SHOW_HELP:-0}" == "1" ]] && { usage; exit 0; }
if (( ${#OPS_REMAINING_ARGS[@]} > 0 )); then
    printf '未知参数: %s\n\n' "${OPS_REMAINING_ARGS[*]}" >&2
    usage >&2
    exit 3
fi
[[ -n "$MONTHLY_MARKDOWN" ]] && OPS_MARKDOWN_OUT="$MONTHLY_MARKDOWN"

ops_require_cmds date hostname awk sed grep stat find sort head tail jq
ops_load_conf

# ----------------------------------------------------------------------------
# 配置
# ----------------------------------------------------------------------------
PROJECT_DIR="$(ops_conf_get PROJECT_DIR /opt/knowtrace)"
BACKUP_ROOT="$(ops_conf_get BACKUP_ROOT /var/backups/knowtrace)"
REPORTS_DIR="$(ops_conf_get REPORTS_DIR /var/lib/knowtrace/reports)"
RECORD_DIR="$(ops_conf_get RECORD_DIR /var/log/knowtrace-logs)"
LOG_ARCHIVE_DIR="$(ops_conf_get LOG_ARCHIVE_DIR /var/log/knowtrace-logs)"
DOCS_DIR="$(ops_conf_get DOCS_DIR "$PROJECT_DIR/docs")"

BACKUP_ALL_SCRIPT="$(ops_conf_get BACKUP_ALL_SCRIPT /opt/knowtrace/scripts/linux/backup-all.sh)"
RESTORE_VERIFY_SCRIPT="$(ops_conf_get RESTORE_VERIFY_SCRIPT /opt/knowtrace/scripts/linux/verify-restore.sh)"
PRUNE_BACKUPS_SCRIPT="$(ops_conf_get PRUNE_BACKUPS_SCRIPT /opt/knowtrace/scripts/linux/prune-backups.sh)"
LOKI_PORT="$(ops_conf_int LOKI_PORT 3100)"
OPS_REPORT_SCRIPT="$(ops_conf_get OPS_REPORT_SCRIPT "$SCRIPT_DIR/ops-report.py")"

THRESH_RESTORE_DRILL_MAX_AGE_HOURS="$(ops_conf_int THRESHOLD_RESTORE_DRILL_MAX_AGE_HOURS 72)"
THRESH_APT_LIST_MAX_AGE_DAYS="$(ops_conf_int THRESHOLD_APT_LIST_MAX_AGE_DAYS 7)"
THRESH_APT_REBOOT_WARN="$(ops_conf_int THRESHOLD_APT_REBOOT_REQUIRED_WARN 1)"
BACKUP_RETENTION_DAYS="$(ops_conf_int BACKUP_RETENTION_DAYS 14)"
BACKUP_MIN_KEEP="$(ops_conf_int BACKUP_MIN_KEEP 7)"
WRITE_WINDOW="$(ops_conf_get MONTHLY_WRITE_WINDOW "")"
APPLY_TIMEOUT="$(ops_conf_int APPLY_TIMEOUT_SECONDS 1800)"
DOC_STALE_DAYS="$(ops_conf_int THRESHOLD_DOC_STALE_DAYS 35)"
THRESH_LYNIS_INDEX_OK="$(ops_conf_int THRESHOLD_LYNIS_INDEX_OK 80)"
THRESH_LYNIS_INDEX_WARN="$(ops_conf_int THRESHOLD_LYNIS_INDEX_WARN 60)"

is_root=0
[[ "${EUID:-$(id -u 2>/dev/null || printf '1')}" == "0" ]] && is_root=1
have_docker=0; ops_have_cmd docker && have_docker=1

# ----------------------------------------------------------------------------
# 写操作开关判定
# ----------------------------------------------------------------------------

# 动作是否被允许：config 默认值 + 命令行覆盖
action_enabled() {
    local name="$1" conf_key="$2"
    if [[ -n "${MONTHLY_OVERRIDE[$name]+set}" ]]; then
        [[ "${MONTHLY_OVERRIDE[$name]}" == "1" ]]
        return
    fi
    [[ "$(ops_conf_int "$conf_key" 1)" == "1" ]]
}

# 是否在允许的写时间窗内
in_write_window() {
    [[ -z "$WRITE_WINDOW" ]] && return 0
    local hour start end
    hour="$(date -u '+%-H')"
    start="${WRITE_WINDOW%%-*}"
    end="${WRITE_WINDOW##*-}"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || return 0
    if (( start <= end )); then
        (( hour >= start && hour <= end ))
    else
        # 跨零点，例 22-4
        (( hour >= start || hour <= end ))
    fi
}

# 交互确认；--yes 时直接通过
confirm() {
    local prompt="$1"
    (( MONTHLY_ASSUME_YES == 1 )) && return 0
    if [[ ! -t 0 ]]; then
        printf '  → 非交互环境且未给 --yes，跳过该动作\n'
        return 1
    fi
    local reply=""
    read -r -p "  → ${prompt} 输入 yes 继续: " reply
    [[ "$reply" == "yes" ]]
}

# 写操作的两道闸：时间窗 + 人工确认。
# 返回 0 = 允许继续；非 0 = 应当放弃本次动作（已经记录过原因）。
# 所有写操作都必须先过这里——包括那些不走 apply_run 的动作（如归档）。
apply_guard() {
    local check="$1" label="$2" prompt="$3"
    if ! in_write_window; then
        ops_warn "$check" "当前小时不在允许的写时间窗（MONTHLY_WRITE_WINDOW=$WRITE_WINDOW），跳过 $label"
        return 1
    fi
    if ! confirm "$prompt"; then
        ops_warn "$check" "$label 已取消（未确认）"
        return 1
    fi
    return 0
}

# 统一的写操作执行入口
# apply_run <检查项ID> <人类可读说明> <确认提示> <命令...>
apply_run() {
    local check="$1" label="$2" prompt="$3"
    shift 3
    local cmd_display="$*"

    if (( MONTHLY_APPLY == 0 )); then
        ops_info "$check" "[演练] 将执行: $cmd_display"
        return 0
    fi
    apply_guard "$check" "$label" "$prompt" || return 0

    printf '  → 实际执行: %s\n' "$cmd_display"

    local rc=0 output=""
    output="$(timeout --signal=TERM "$APPLY_TIMEOUT" "$@" 2>&1)"; rc=$?
    if (( rc == 0 )); then
        ops_ok "$check" "$label 执行成功"
        [[ "$OPS_QUIET" != "1" ]] && printf '%s\n' "$output" | tail -n 20 | ops_indent
    elif (( rc == 124 )); then
        ops_fail "$check" "$label 超时（${APPLY_TIMEOUT}s）被终止"
    else
        ops_fail "$check" "$label 执行失败（退出码 $rc）"
        printf '%s\n' "$output" | tail -n 20 | ops_indent
    fi
    return 0
}

# ============================================================================
ops_section "KnowTrace-Workflow 每月运维  主机=$OPS_HOSTNAME  用户=$OPS_USER_NAME  目录=$OPS_CWD"
printf '执行时间(UTC): %s\n' "$OPS_RUN_UTC"
printf '模式        : %s\n' "$([[ "$MONTHLY_APPLY" == "1" ]] && printf 'APPLY（会执行写操作）' || printf '演练（只出计划，不改变任何东西）')"
printf '权限级别    : %s\n' "$([[ "$is_root" == "1" ]] && printf 'root' || printf '普通用户（恢复演练需要 root）')"
printf '写时间窗    : %s\n' "${WRITE_WINDOW:-未限制}"
printf '确认方式    : %s\n' "$([[ "$MONTHLY_ASSUME_YES" == "1" ]] && printf '--yes 已给出，不再交互' || printf '交互确认（需输入 yes）')"

if (( MONTHLY_APPLY == 0 )); then
    ops_fact "这是演练模式。要真正执行写操作，请加 --apply（并确认 ops.conf 里的 MONTHLY_* 开关）。"
fi

# ----------------------------------------------------------------------------
# 1. 动作计划
# ----------------------------------------------------------------------------
ops_section "1. 本月动作计划"

print_action() {
    local name="$1" conf_key="$2" desc="$3"
    if action_enabled "$name" "$conf_key"; then
        ops_ok "plan.$name" "启用：$desc"
    else
        ops_info "plan.$name" "已关闭（ops.conf $conf_key=0 或命令行 --without-$name）"
    fi
}

print_action "restore-drill"  MONTHLY_RESTORE_DRILL  "隔离恢复演练（verify-restore.sh）"
print_action "prune-backups"  MONTHLY_PRUNE_BACKUPS  "备份保留策略（prune-backups.sh，会删除旧备份）"
print_action "stop-logs"      MONTHLY_STOP_LOKI      "停止日志栈（Loki+Alloy，释放内存/磁盘）"
print_action "archive-logs"   MONTHLY_ARCHIVE_LOGS   "日志与报告归档"
print_action "report"         MONTHLY_BUILD_REPORT   "汇总报告（ops-report.py）"

if (( MONTHLY_APPLY_UPDATES == 1 )); then
    ops_warn "plan.apt-upgrade" "本次会真的执行 apt 升级（--apply-updates）"
else
    ops_info "plan.apt-upgrade" "依赖更新只检查不升级（要升级请显式加 --apply-updates）"
fi

# ----------------------------------------------------------------------------
# 2. 隔离恢复演练的前置条件
# ----------------------------------------------------------------------------
ops_section "2. 恢复演练前置条件"

newest_archive=""
newest_epoch=0
find_newest_backup() {
    local archive epoch
    while IFS= read -r archive; do
        [[ -n "$archive" ]] || continue
        epoch="$(ops_mtime "$archive")"
        if (( epoch > newest_epoch )); then
            newest_epoch="$epoch"
            newest_archive="$archive"
        fi
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -type f -name 'knowtrace-*.tar.gz' 2>/dev/null | sort)
}
[[ -d "$BACKUP_ROOT" ]] && find_newest_backup

drill_ready=0
if [[ -z "$newest_archive" ]]; then
    ops_fail "drill.backup" "$BACKUP_ROOT 下没有可用的 *.tar.gz 归档，无法做恢复演练"
else
    drill_age_hours="$(ops_age_hours "$newest_epoch")"
    drill_age_int="$(
        [[ "$drill_age_hours" == "unknown" ]] && printf '99999' \
            || awk -v v="$drill_age_hours" 'BEGIN{printf "%.0f", v}'
    )"
    if (( drill_age_int > THRESH_RESTORE_DRILL_MAX_AGE_HOURS )); then
        ops_fail "drill.backup" \
            "最新归档 ${drill_age_hours} 小时前，超过 ${THRESH_RESTORE_DRILL_MAX_AGE_HOURS} 小时，恢复演练会拒绝执行（拿过期备份演练等于自欺）"
    else
        ops_ok "drill.backup" "最新归档 $(basename -- "$newest_archive")（${drill_age_hours} 小时前）"
        drill_ready=1
    fi

    # 先校验再演练：坏归档练出来的「成功」没有意义
    if [[ -f "${newest_archive}.sha256" ]] && ops_have_cmd sha256sum; then
        exp="$(awk '{print $1}' "${newest_archive}.sha256" 2>/dev/null | head -n 1)"
        act="$(sha256sum -- "$newest_archive" 2>/dev/null | awk '{print $1}')"
        if [[ -n "$exp" && "$exp" == "$act" ]]; then
            ops_ok "drill.checksum" "归档 SHA-256 校验通过"
        else
            ops_fail "drill.checksum" "归档 SHA-256 校验失败，先修备份再做演练"
            drill_ready=0
        fi
    else
        ops_warn "drill.checksum" "缺少 ${newest_archive}.sha256 或 sha256sum 不可用，无法先行校验"
    fi
fi

# 磁盘：解包 + 起三个临时容器需要空间
tmp_free_kib="$(df --output=avail -k /tmp 2>/dev/null | tail -n 1 | tr -d ' ')"
if [[ "$tmp_free_kib" =~ ^[0-9]+$ ]]; then
    tmp_free_gib="$(awk -v k="$tmp_free_kib" 'BEGIN{printf "%.1f", k/1048576}')"
    if (( tmp_free_kib < 3 * 1048576 )); then
        ops_warn "drill.disk" "/tmp 可用 ${tmp_free_gib} GiB，低于建议的 3 GiB"
    else
        ops_ok "drill.disk" "/tmp 可用 ${tmp_free_gib} GiB"
    fi
fi

# 内存：演练要同时起 postgres / mysql / redis 三个临时容器
mem_avail_mib="$(awk '/^MemAvailable:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || printf '0')"
if [[ "$mem_avail_mib" =~ ^[0-9]+$ && "$mem_avail_mib" -gt 0 ]]; then
    if (( mem_avail_mib < 500 )); then
        ops_warn "drill.memory" "可用内存 ${mem_avail_mib}MiB，低于建议的 500MiB，演练可能触发 OOM"
    else
        ops_ok "drill.memory" "可用内存 ${mem_avail_mib}MiB"
    fi
fi

# 演练所需镜像必须已在本地（verify-restore.sh 会自己检查，这里先提示）
if (( have_docker == 1 )); then
    missing_images=""
    for image in "postgres:18-alpine" "mysql:8.0" "redis:7.4-alpine"; do
        docker image inspect "$image" >/dev/null 2>&1 || missing_images="${missing_images}${image} "
    done
    if [[ -z "$missing_images" ]]; then
        ops_ok "drill.images" "演练所需镜像已存在"
    else
        ops_warn "drill.images" "缺少演练镜像（离线环境会失败）: ${missing_images% }"
    fi
fi

if [[ ! -f "$RESTORE_VERIFY_SCRIPT" ]]; then
    ops_warn "drill.script" "未找到 $RESTORE_VERIFY_SCRIPT"
    drill_ready=0
fi

# ----------------------------------------------------------------------------
# 3. 备份保留策略姿态
# ----------------------------------------------------------------------------
ops_section "3. 备份保留策略"

if [[ -d "$BACKUP_ROOT" ]]; then
    total_bundles="$(find "$BACKUP_ROOT" -maxdepth 1 -type f -name 'knowtrace-*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')"
    old_bundles="$(find "$BACKUP_ROOT" -maxdepth 1 -type f -name 'knowtrace-*.tar.gz' -mtime "+${BACKUP_RETENTION_DAYS}" 2>/dev/null | wc -l | tr -d ' ')"
    bundle_bytes="$(du -sb -- "$BACKUP_ROOT" 2>/dev/null | awk '{print $1}')"

    ops_info "prune.count" "共 ${total_bundles} 份归档，占用 $(printf '%s' "$bundle_bytes" | awk '{printf "%.1f GiB", $1/1073741824}' 2>/dev/null)"
    ops_info "prune.policy" "保留策略 RETENTION_DAYS=${BACKUP_RETENTION_DAYS} MIN_KEEP=${BACKUP_MIN_KEEP}"

    if (( old_bundles > 0 )); then
        # 会保留 MIN_KEEP，所以「过期数 > 超出部分」才是真正会被删的
        deletable=$(( total_bundles - BACKUP_MIN_KEEP ))
        (( deletable < 0 )) && deletable=0
        (( deletable > old_bundles )) && deletable="$old_bundles"
        ops_info "prune.candidates" "过期归档 ${old_bundles} 份，其中最多 ${deletable} 份会被删除（MIN_KEEP=${BACKUP_MIN_KEEP} 保底）"
    else
        ops_ok "prune.candidates" "没有超过 ${BACKUP_RETENTION_DAYS} 天的归档，无需清理"
    fi

    incomplete_count="$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name '.incomplete-*' 2>/dev/null | ops_count_lines)"
    if (( incomplete_count > 0 )); then
        ops_warn "prune.incomplete" "存在 ${incomplete_count} 个 .incomplete-* 目录，先排查失败原因再清理"
    fi

    # 备份锁存在说明有备份正在跑，此时绝不能动备份目录
    if [[ -f "$BACKUP_ROOT/.backup.lock" ]] && [[ -s "$BACKUP_ROOT/.backup.lock" ]]; then
        ops_warn "prune.lock" ".backup.lock 非空，可能有备份正在执行；清理动作应推迟"
    fi
else
    ops_fail "prune.root" "备份目录不存在: $BACKUP_ROOT"
fi

# ----------------------------------------------------------------------------
# 4. 日志栈资源占用（Loki + Alloy）
# ----------------------------------------------------------------------------
ops_section "4. 日志栈状态（PLG）"

plg_running=""
if (( have_docker == 1 )); then
    running_names="$(docker ps --format '{{.Names}}' 2>/dev/null || printf '')"
    for service in loki alloy; do
        ops_service_running "$service" \
            && plg_running="${plg_running}${service} "
    done
fi

if [[ -z "${plg_running// /}" ]]; then
    # 与 ELK 不同：Loki/Alloy 是**常驻**组件，没跑就是真问题（日志会断）
    ops_warn "plg.state" "Loki/Alloy 未运行 —— 日志将无法采集与查询"
else
    ops_ok "plg.state" "日志栈运行中: ${plg_running% }"
    plg_stats="$(docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}' \
        $(printf 'knowtrace-%s-1 ' loki alloy) 2>/dev/null || printf '')"
    [[ -n "$plg_stats" && "$OPS_QUIET" != "1" ]] && printf '%s\n' "$plg_stats" | ops_indent

    # 内存吃紧时，停日志栈是正确动作（PLG 比 ELK 轻得多，阈值也相应下调）
    if [[ "$mem_avail_mib" =~ ^[0-9]+$ ]]; then
        if (( mem_avail_mib < 400 )); then
            ops_warn "plg.pressure" "可用内存仅 ${mem_avail_mib}MiB，建议停掉 Loki/Alloy 释放资源"
        else
            ops_info "plg.pressure" "可用内存 ${mem_avail_mib}MiB，暂无压力"
        fi
    fi
fi

# ----------------------------------------------------------------------------
# 5. 依赖更新检查
# ----------------------------------------------------------------------------
ops_section "5. 依赖更新检查"

if [[ "$is_root" != "1" ]]; then
    ops_info "dep.check" "非 root，跳过 apt 检查"
elif ! ops_have_cmd apt-get; then
    ops_info "dep.check" "未使用 apt，跳过"
else
    # `; true` 而不是 `|| printf '0'`：见 weekly-check.sh 同处的说明（0 匹配会让 || 补出 "0\n0"）
    updatable="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' 2>/dev/null; true)"
    upgradable_list="$(apt-get -s upgrade 2>/dev/null | grep '^Inst ' || printf '')"
    security_list="$(printf '%s' "$upgradable_list" | grep -iE 'security|ubuntu-security' || printf '')"

    if [[ "$updatable" =~ ^[0-9]+$ ]]; then
        if (( updatable == 0 )); then
            ops_ok "dep.upgradable" "没有可升级的软件包"
        else
            ops_info "dep.upgradable" "有 ${updatable} 个可升级软件包"
            if [[ -n "$security_list" ]]; then
                sec_count="$(printf '%s\n' "$security_list" | ops_count_lines)"
                ops_warn "dep.security" "其中 ${sec_count} 个来自安全源，建议优先安排升级"
            fi
        fi
        [[ "$OPS_QUIET" != "1" && -n "$upgradable_list" ]] && \
            printf '%s\n' "$upgradable_list" | head -n 12 | ops_indent
    fi

    # 需要重启才生效的包
    reboot_pkgs="$(printf '%s\n' "$upgradable_list" | grep -E '^Inst (linux-image|linux-headers|linux-generic|libc6|libssl[0-9]|docker|containerd)' || printf '')"
    if [[ -n "$reboot_pkgs" ]]; then
        reboot_count="$(printf '%s\n' "$reboot_pkgs" | ops_count_lines)"
        if (( reboot_count >= THRESH_APT_REBOOT_WARN )); then
            ops_warn "dep.reboot-needed" "${reboot_count} 个更新需要重启服务或系统才生效，请安排维护窗口"
            printf '%s\n' "$reboot_pkgs" | ops_indent
        fi
    fi

    if [[ -f /var/run/reboot-required ]]; then
        ops_warn "dep.reboot-flag" "/var/run/reboot-required 存在（重启动作需人工执行，本脚本不做）"
    fi

    # apt 列表新鲜度
    if [[ -f /var/lib/apt/periodic/update-stamp ]]; then
        stamp_mtime="$(ops_mtime /var/lib/apt/periodic/update-stamp)"
        if [[ "$stamp_mtime" =~ ^[0-9]+$ && "$stamp_mtime" -gt 0 ]]; then
            stamp_days="$(awk -v h="$(ops_age_hours "$stamp_mtime")" 'BEGIN{printf "%.0f", h/24}')"
            if (( stamp_days > THRESH_APT_LIST_MAX_AGE_DAYS )); then
                ops_warn "dep.apt-list" "软件包列表 ${stamp_days} 天未更新（阈值 ${THRESH_APT_LIST_MAX_AGE_DAYS} 天）"
            else
                ops_ok "dep.apt-list" "软件包列表 ${stamp_days} 天前更新过"
            fi
        fi
    fi
fi

# ----------------------------------------------------------------------------
# 6. 主机基线审计（Lynis）
# ----------------------------------------------------------------------------
ops_section "6. 主机基线审计（Lynis）"

if ! ops_have_cmd lynis; then
    ops_info "lynis" "未安装 lynis，跳过主机基线审计"
else
    # 每月跑一次完整审计（约 1-2 分钟），解析硬化指数
    lynis_out="$(lynis audit system --no-colors 2>/dev/null || printf '')"
    index="$(printf '%s\n' "$lynis_out" | sed -n 's/^[[:space:]]*Hardening index[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"
    if [[ "$index" =~ ^[0-9]+$ ]]; then
        if (( index >= THRESH_LYNIS_INDEX_OK )); then
            ops_ok "lynis.index" "硬化指数 ${index}（≥ ${THRESH_LYNIS_INDEX_OK}）"
        elif (( index >= THRESH_LYNIS_INDEX_WARN )); then
            ops_warn "lynis.index" "硬化指数 ${index}（建议 ≥ ${THRESH_LYNIS_INDEX_OK}）"
        else
            ops_fail "lynis.index" "硬化指数 ${index}（低于 ${THRESH_LYNIS_INDEX_WARN}）"
        fi
        [[ "$OPS_QUIET" != "1" ]] && printf '%s\n' "$lynis_out" | grep -E '\[[A-Z]+-[0-9]+\]' | head -n 15 | ops_indent
    else
        ops_warn "lynis.index" "无法解析硬化指数（lynis 输出异常）"
    fi
fi

# ----------------------------------------------------------------------------
# 7. 故障记录复盘
# ----------------------------------------------------------------------------
ops_section "7. 故障记录复盘"

# 记录可能在两处：仓库 docs/日常运维/ 与 RECORD_DIR
scan_record_dirs=()
[[ -d "$DOCS_DIR/日常运维" ]] && scan_record_dirs+=("$DOCS_DIR/日常运维")
[[ -d "$RECORD_DIR" ]] && scan_record_dirs+=("$RECORD_DIR")

if (( ${#scan_record_dirs[@]} == 0 )); then
    ops_info "postmortem" "未找到记录目录（$DOCS_DIR/日常运维 与 $RECORD_DIR 都不存在）"
else
    record_total=0
    incomplete_records=""
    last_record_mtime=0
    last_record_name=""

    for dir in "${scan_record_dirs[@]}"; do
        while IFS= read -r doc; do
            [[ -n "$doc" ]] || continue
            (( record_total += 1 ))
            mtime="$(ops_mtime "$doc")"
            if (( mtime > last_record_mtime )); then
                last_record_mtime="$mtime"
                last_record_name="${doc#"$dir"/}"
            fi
            # 判定「未定稿」：还留着人工填写占位符，或缺少必需字段
            if grep -q '<!-- 人工填写' "$doc" 2>/dev/null \
                || { grep -qE '^## (处理动作|验证结果)' "$doc" 2>/dev/null \
                     && ! grep -qE '^## (后续改进|遗留风险)' "$doc" 2>/dev/null; }; then
                incomplete_records="${incomplete_records}${doc} "
            fi
        done < <(find "$dir" -maxdepth 1 -type f -name '*运维*.md' 2>/dev/null | sort)
    done

    ops_info "postmortem.count" "找到 ${record_total} 份运维记录"

    if (( record_total == 0 )); then
        ops_warn "postmortem.count" "没有找到任何运维记录，月度清单的「故障记录复盘」没有素材"
    elif [[ -n "${last_record_name// /}" ]]; then
        record_age_days="$(awk -v h="$(ops_age_hours "$last_record_mtime")" 'BEGIN{printf "%.0f", h/24}')"
        ops_info "postmortem.latest" "最近一份：$last_record_name（${record_age_days} 天前）"
        if (( record_age_days > DOC_STALE_DAYS )); then
            ops_warn "postmortem.stale" "最近 ${record_age_days} 天没有新的运维记录，记录习惯可能已中断"
        fi
    fi

    if [[ -n "${incomplete_records// /}" ]]; then
        inc_count="$(printf '%s\n' $incomplete_records | ops_count_lines)"
        ops_warn "postmortem.incomplete" "${inc_count} 份记录未定稿（还有人工填写占位符或缺少字段），复盘时补齐"
        printf '%s\n' $incomplete_records | head -n 8 | ops_indent
    else
        ops_ok "postmortem.incomplete" "没有发现未定稿的记录"
    fi
fi

# 故障记录字段完整性（清单第 144-158 行要求 11 个字段）
ops_fact "复盘要求字段：时间/现象/影响范围/首次发现方式/排查命令/关键证据/根因或当前推断/处理动作/验证结果/遗留风险/后续改进"

# ----------------------------------------------------------------------------
# 8. 文档更新检查
# ----------------------------------------------------------------------------
ops_section "8. 文档更新检查"

if [[ -d "$PROJECT_DIR/.git" ]]; then
    dirty="$(git -C "$PROJECT_DIR" status --short 2>/dev/null | ops_count_lines)"
    if (( dirty > 0 )); then
        ops_warn "docs.git-dirty" "生产仓库工作区有 ${dirty} 项未提交改动，文档更新应走本地提交再部署"
        [[ "$OPS_QUIET" != "1" ]] && git -C "$PROJECT_DIR" status --short 2>/dev/null | head -n 10 | ops_indent
    else
        ops_ok "docs.git-dirty" "生产仓库工作区干净"
    fi
else
    ops_info "docs.git" "$PROJECT_DIR 不是 git 工作区"
fi

if [[ -d "$DOCS_DIR" ]]; then
    # 文档多久没更新了
    newest_doc=""
    newest_doc_mtime=0
    while IFS= read -r doc; do
        [[ -n "$doc" ]] || continue
        mtime="$(ops_mtime "$doc")"
        if (( mtime > newest_doc_mtime )); then
            newest_doc_mtime="$mtime"
            newest_doc="${doc#"$DOCS_DIR"/}"
        fi
    done < <(find "$DOCS_DIR" -maxdepth 2 -type f -name '*.md' 2>/dev/null)

    if [[ -n "$newest_doc" ]]; then
        doc_age_days="$(awk -v h="$(ops_age_hours "$newest_doc_mtime")" 'BEGIN{printf "%.0f", h/24}')"
        if (( doc_age_days > DOC_STALE_DAYS )); then
            ops_warn "docs.stale" "文档 ${doc_age_days} 天未更新（阈值 ${DOC_STALE_DAYS} 天），最近一份：$newest_doc"
        else
            ops_ok "docs.stale" "文档最近 ${doc_age_days} 天内有更新（$newest_doc）"
        fi
    fi
else
    ops_warn "docs.dir" "文档目录不存在: $DOCS_DIR"
fi

# 报告闭环
if [[ -d "$REPORTS_DIR" ]]; then
    report_total="$(find "$REPORTS_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
    ops_info "docs.reports" "报告目录 ${REPORTS_DIR} 共 ${report_total} 份 JSON"
    if [[ -f "$OPS_REPORT_SCRIPT" ]]; then
        ops_info "docs.report-script" "汇总入口: python3 $OPS_REPORT_SCRIPT"
    else
        ops_info "docs.report-script" "未找到 ops-report.py，无法生成汇总"
    fi
else
    ops_info "docs.reports" "报告目录尚未创建: $REPORTS_DIR"
fi

# ----------------------------------------------------------------------------
# 8. 执行写操作
# ----------------------------------------------------------------------------
ops_section "9. 执行计划中的动作"

# ---- 8.1 停止日志栈（Loki + Alloy）----
if action_enabled "stop-logs" MONTHLY_STOP_LOKI; then
    if [[ -z "${plg_running// /}" ]]; then
        ops_ok "apply.stop-logs" "日志栈未运行，无需停止"
    elif [[ ! -d "$PROJECT_DIR" ]]; then
        ops_warn "apply.stop-logs" "项目目录不存在：$PROJECT_DIR"
    else
        apply_run "apply.stop-logs" "停止日志栈" \
            "确认停止 Loki 与 Alloy（数据卷保留）？" \
            bash -c "cd \"$PROJECT_DIR\" && docker compose                 --env-file .env --env-file .env.observability                 -f compose.yaml -f compose.production.yaml -f compose.observability.yaml                 stop loki alloy"
    fi
else
    ops_info "apply.stop-logs" "动作已关闭"
fi

# ---- 8.2 备份保留策略 ----
if action_enabled "prune-backups" MONTHLY_PRUNE_BACKUPS; then
    if [[ ! -f "$PRUNE_BACKUPS_SCRIPT" ]]; then
        ops_warn "apply.prune" "未找到 $PRUNE_BACKUPS_SCRIPT"
    else
        apply_run "apply.prune" "清理超过 ${BACKUP_RETENTION_DAYS} 天的备份（保底 ${BACKUP_MIN_KEEP} 份）" \
            "确认删除过期备份？此操作不可逆" \
            env BACKUP_ROOT="$BACKUP_ROOT" \
                RETENTION_DAYS="$BACKUP_RETENTION_DAYS" \
                MIN_KEEP="$BACKUP_MIN_KEEP" \
                bash "$PRUNE_BACKUPS_SCRIPT"
    fi
else
    ops_info "apply.prune" "动作已关闭"
fi

# ---- 8.3 隔离恢复演练 ----
if action_enabled "restore-drill" MONTHLY_RESTORE_DRILL; then
    if (( drill_ready == 0 )); then
        ops_fail "apply.drill" "前置条件不满足（见第 2 节），已阻止执行恢复演练"
    elif [[ -z "$newest_archive" ]]; then
        ops_fail "apply.drill" "没有可用归档"
    else
        apply_run "apply.drill" "隔离恢复演练：$(basename -- "$newest_archive")" \
            "确认在隔离容器中恢复该备份？（不会改动生产数据）" \
            bash "$RESTORE_VERIFY_SCRIPT" "$newest_archive"
    fi
else
    ops_info "apply.drill" "动作已关闭"
fi

# ---- 8.4 日志与报告归档 ----
if action_enabled "archive-logs" MONTHLY_ARCHIVE_LOGS; then
    # 用 %Y%m 而不是 %Y-%m：同一个 LOG_ARCHIVE_DIR 下，记录骨架走的是 <年月>（见
    # daily-ops.sh 的 record 段），归档若走 <年-月> 就会出现 202609/ 与 2026-09/ 两个
    # 描述同一个月的目录。项目自己的约定也是 YYYYMM（docs/日常运维/images/202609/）。
    archive_month="$(date -u '+%Y%m')"
    archive_path="$LOG_ARCHIVE_DIR/$archive_month"
    if [[ ! -d "$LOG_ARCHIVE_DIR" ]]; then
        ops_warn "apply.archive" "归档根目录不存在: $LOG_ARCHIVE_DIR"
    elif [[ ! -d "$REPORTS_DIR" ]]; then
        ops_info "apply.archive" "没有报告目录可归档: $REPORTS_DIR"
    elif (( MONTHLY_APPLY == 0 )); then
        ops_info "apply.archive" "[演练] 将把 $REPORTS_DIR 的报告归档到 $archive_path/reports.tar.gz"
    elif ! apply_guard "apply.archive" "日志与报告归档" "确认把报告归档到 $archive_path ？"; then
        : # apply_guard 已记录取消原因
    else
        if mkdir -p -- "$archive_path" 2>/dev/null; then
            if tar --create --gzip --file "$archive_path/reports.tar.gz" \
                    --directory "$(dirname -- "$REPORTS_DIR")" "$(basename -- "$REPORTS_DIR")" 2>/dev/null; then
                report_count="$(tar --list --gzip --file "$archive_path/reports.tar.gz" 2>/dev/null | grep -c '\.json$' 2>/dev/null; true)"
                [[ "$report_count" =~ ^[0-9]+$ ]] || report_count=0
                ops_ok "apply.archive" "已归档 $report_count 份报告到 $archive_path/reports.tar.gz"
            else
                ops_fail "apply.archive" "归档失败: $archive_path/reports.tar.gz"
            fi
        else
            ops_warn "apply.archive" "无法创建归档目录 $archive_path"
        fi
    fi
else
    ops_info "apply.archive" "动作已关闭"
fi

# ---- 8.5 依赖更新（双重开关）----
if (( MONTHLY_APPLY == 1 && MONTHLY_APPLY_UPDATES == 1 )); then
    if ! in_write_window; then
        ops_warn "apply.apt" "不在写时间窗内，跳过 apt 升级"
    else
        apply_run "apply.apt" "apt 升级（生产变更，请确保已备份）" \
            "确认执行 apt-get upgrade？建议先手工确认变更清单" \
            bash -c 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade'
    fi
elif (( MONTHLY_APPLY_UPDATES == 1 )); then
    ops_warn "apply.apt" "--apply-updates 已给出但没有 --apply，仍只做检查"
else
    ops_info "apply.apt" "依赖更新只检查不升级（--apply-updates 才会执行）"
fi

# ---- 8.6 汇总报告 ----
if action_enabled "report" MONTHLY_BUILD_REPORT; then
    if [[ ! -f "$OPS_REPORT_SCRIPT" ]]; then
        ops_warn "apply.report" "未找到 $OPS_REPORT_SCRIPT"
    elif ! ops_have_cmd python3; then
        ops_warn "apply.report" "python3 不可用"
    else
        out_json="$(mktemp /tmp/knowtrace-monthly-report.XXXXXX.json 2>/dev/null || printf '')"
        args=(--reports-dir "$REPORTS_DIR")
        [[ -n "${OPS_CONF:-}" ]] && args+=(--conf "$OPS_CONF")
        [[ -n "$out_json" ]] && args+=(--json "$out_json")
        if python3 "$OPS_REPORT_SCRIPT" "${args[@]}" --no-color --quiet >/dev/null 2>&1; then
            ops_ok "apply.report" "汇总报告已生成"
            if [[ -n "$out_json" ]]; then
                jq -r '.findings[]? | "  [\(.level)] \(.check): \(.message)"' "$out_json" 2>/dev/null \
                    | head -n 10 | ops_indent
            fi
        else
            ops_warn "apply.report" "汇总报告生成失败，请手动运行 python3 $OPS_REPORT_SCRIPT"
        fi
        [[ -n "$out_json" ]] && rm -f -- "$out_json" 2>/dev/null
    fi
else
    ops_info "apply.report" "动作已关闭"
fi

# ----------------------------------------------------------------------------
# 9. 结束
# ----------------------------------------------------------------------------
ops_section "10. 月运维结束"

ops_fact "月清单对照：隔离恢复演练 / 依赖更新检查 / 故障记录复盘 / 文档更新"
ops_fact "本次未执行的动作（演练模式或被开关关闭）请对照第 1 节计划人工确认"
ops_fact "恢复演练通过 ≠ 备份一定能恢复生产；演练环境的验证结论需在记录中写明范围"

if (( MONTHLY_WRITE_RECORD == 1 )); then
    ops_section "11. 生成月度记录骨架"
    record_dir="$RECORD_DIR"
    if [[ -d "$record_dir" ]] || mkdir -p -- "$record_dir" 2>/dev/null; then
        year_month="$(date -u '+%Y%m')"
        mkdir -p -- "$record_dir/$year_month" 2>/dev/null || true
        record_path="$record_dir/$year_month/$(date -u '+%Y-%m')-月度运维记录.md"
        {
            printf '# %s 月度运维记录\n\n' "$(date -u '+%Y-%m')"
            printf '> 由 monthly-ops.sh 于 %s 生成骨架（模式：%s）。\n\n' \
                "$OPS_RUN_UTC" "$([[ "$MONTHLY_APPLY" == "1" ]] && printf 'APPLY' || printf '演练')"
            printf '## 基本信息\n\n'
            printf -- '- 主机：%s\n- 执行时间(UTC)：%s\n- 结论：**%s**\n\n' \
                "$OPS_HOSTNAME" "$OPS_RUN_UTC" "$(ops_worst_level)"
            printf '## 机器判定的结果\n\n| 级别 | 检查项 | 说明 |\n| --- | --- | --- |\n'
            m_idx=0
            while (( m_idx < ${#ops_finding_level[@]} )); do
                printf '| %s | %s | %s |\n' \
                    "${ops_finding_level[$m_idx]}" \
                    "${ops_finding_check[$m_idx]}" \
                    "$(printf '%s' "${ops_finding_message[$m_idx]}" | sed 's/|/\\|/g')"
                (( m_idx += 1 ))
            done
            printf '\n## 恢复演练结果\n\n<!-- 人工填写：用了哪个归档、验证了哪些数据、是否通过 -->\n\n'
            printf '## 依赖更新处理\n\n<!-- 人工填写：升了哪些包、是否需要重启 -->\n\n'
            printf '## 故障复盘\n\n<!-- 人工填写：本月故障、根因、改进项是否落地 -->\n\n'
            printf '## 文档更新\n\n<!-- 人工填写：本次更新了哪些文档 -->\n'
        } > "$record_path" 2>/dev/null
        if [[ -s "$record_path" ]]; then
            ops_ok "record.written" "已生成 $record_path（人工定稿后再归档）"
        else
            ops_warn "record.written" "无法写入 $record_path"
        fi
    else
        ops_warn "record.dir" "无法创建 $record_dir"
    fi
else
    ops_fact "如需生成月度记录骨架，加 --write-record"
fi

ops_finish "monthly-ops" "KnowTrace-Workflow 每月运维"
