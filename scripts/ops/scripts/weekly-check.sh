#!/usr/bin/env bash
# ============================================================================
# KnowTrace-Workflow 每周运维（只读 + 可选生成记录）
# ============================================================================
#
# 对应文档：
#   docs/日常运维/日常运维清单.md（第 160-164 行「日常频率建议」的每周部分）
#   docs/日常运维/2026-09-21-运维回顾.md（下一期目标）
#
# 每周清单（原文）：
#   备份校验、日志错误模式、证书有效期、异常登录
#
# 本脚本的职责划分：
#   自己实现（清单里有、但此前没有脚本覆盖的）：
#     1. 备份完整性校验    —— 重算 SHA-256，不把「有备份文件」当成「可恢复」
#     2. 监控 Targets      —— Prometheus 抓取面 / 探测 / 告警状态 / 告警链路新鲜度
#     3. 日志错误模式      —— 调用 log_analyzer.py（聚类 + 与上周基线对比）
#     4. 系统补丁与磁盘趋势 —— 只读检查更新状态，不做升级（升级属于月运维）
#     5. 报告本身的新鲜度  —— 确认每日巡检在按周期产出
#   委派给既有脚本（不重复实现）：
#     6. 证书有效期        -> cert_check.py
#     7. 异常登录与安全访问 -> security-check.sh
#
# 只读保证：本脚本不执行任何修改性动作（不 restart / stop / rm / upgrade），
# 唯一写入是 JSON/Markdown 报告，以及 --write-record 时的运维记录骨架。
#
# 退出码：0=无异常  1=存在 WARN  2=存在 FAIL  3=脚本自身错误
# ============================================================================

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/ops-common.sh
source "$SCRIPT_DIR/../lib/ops-common.sh"
# shellcheck source=../lib/ops-monitor.sh
source "$SCRIPT_DIR/../lib/ops-monitor.sh"

usage() {
    cat <<'EOF'
KnowTrace-Workflow 每周运维（只读）

用法:
  ./scripts/weekly-check.sh [选项]

选项:
  --conf <文件>      指定 ops.conf
  --json <文件>      写出 JSON 报告
  --markdown <文件>  写出 Markdown 报告
  --no-json          不写 JSON 报告
  --quiet, -q        只输出 WARN/FAIL
  --no-color         关闭彩色输出
  --write-record     额外生成运维记录骨架（Markdown），路径见 RECORD_DIR
  --record           --write-record 的别名（与 daily-ops.sh 一致）
  --skip-delegate    不调用 cert_check.py / security-check.sh（单独调试用）
  --help, -h         显示本帮助

说明:
  本脚本只做只读检查。备份校验采用「重算 SHA-256」而不是「看文件是否存在」；
  判定为 OK 的项必须实际验证通过，未验证的事实一律记为 INFO。
  调用 cert_check.py / security-check.sh 时，它们的结论会以 INFO 形式带过来，
  本脚本仍然独立保留自己的判定（避免子脚本失败被静默吞掉）。

退出码:
  0 未发现异常   1 存在 WARN   2 存在 FAIL
EOF
}

# 本脚本自己解析 --markdown / --write-record / --skip-delegate，
# 其余交给公共库（--conf / --json / --no-json / --quiet / --no-color / --help）
WEEKLY_MARKDOWN=""
WEEKLY_WRITE_RECORD=0
WEEKLY_SKIP_DELEGATE=0
_weekly_args=()
while (( $# )); do
    case "$1" in
        --markdown)      ops_require_value "$@"; WEEKLY_MARKDOWN="$2"; shift 2 ;;
        --markdown=*)    WEEKLY_MARKDOWN="${1#*=}"; shift ;;
        --write-record)  WEEKLY_WRITE_RECORD=1; shift ;;
        --record)        WEEKLY_WRITE_RECORD=1; shift ;;   # 与 daily-ops.sh 保持一致
        --skip-delegate) WEEKLY_SKIP_DELEGATE=1; shift ;;
        *)               _weekly_args+=("$1"); shift ;;
    esac
done
ops_parse_common_args "${_weekly_args[@]}"
[[ "${OPS_SHOW_HELP:-0}" == "1" ]] && { usage; exit 0; }
if (( ${#OPS_REMAINING_ARGS[@]} > 0 )); then
    printf '未知参数: %s\n\n' "${OPS_REMAINING_ARGS[*]}" >&2
    usage >&2
    exit 3
fi

ops_require_cmds date hostname awk sed grep stat find sort head tail jq
ops_load_conf

# ----------------------------------------------------------------------------
# 配置
# ----------------------------------------------------------------------------
PROJECT_DIR="$(ops_conf_get PROJECT_DIR /opt/knowtrace)"
BACKUP_ROOT="$(ops_conf_get BACKUP_ROOT /var/backups/knowtrace)"
BACKUP_LOG="$(ops_conf_get BACKUP_LOG /var/log/knowtrace-workflow-backup.log)"
REPORTS_DIR="$(ops_conf_get REPORTS_DIR /var/lib/knowtrace/reports)"
RECORD_DIR="$(ops_conf_get RECORD_DIR /var/log/knowtrace-logs)"
CERT_SCRIPT="$(ops_conf_get CERT_SCRIPT "$SCRIPT_DIR/cert_check.py")"
SECURITY_SCRIPT="$(ops_conf_get SECURITY_SCRIPT "$SCRIPT_DIR/security-check.sh")"
LOG_ANALYZER="$SCRIPT_DIR/log_analyzer.py"

# --markdown 由公共库解析（OPS_MARKDOWN_OUT），这里改成用公共库的输出，
# 保证 weekly-check 自己的报告也带 Markdown 版本
[[ -n "$WEEKLY_MARKDOWN" ]] && OPS_MARKDOWN_OUT="$WEEKLY_MARKDOWN"

PROMETHEUS_BASE="$(ops_conf_get PROMETHEUS_BASE http://127.0.0.1:9090)"
ALERTMANAGER_BASE="$(ops_conf_get ALERTMANAGER_BASE http://127.0.0.1:9093)"

THRESH_BACKUP_WARN_HOURS="$(ops_conf_int THRESHOLD_BACKUP_WARN_HOURS 26)"
THRESH_BACKUP_FAIL_HOURS="$(ops_conf_int THRESHOLD_BACKUP_FAIL_HOURS 48)"
THRESH_BACKUP_AGE_WARN_DAYS="$(ops_conf_int THRESHOLD_BACKUP_AGE_WARN_DAYS 14)"
BACKUP_CHECKSUM_MAX_ITEMS="$(ops_conf_int BACKUP_CHECKSUM_MAX_ITEMS 200)"
BACKUP_MEMBER_LIST_LIMIT="$(ops_conf_int BACKUP_MEMBER_LIST_LIMIT 50)"

THRESH_TARGETS_MIN="$(ops_conf_int THRESHOLD_TARGETS_MIN 10)"
THRESH_TARGETS_DOWN_MAX="$(ops_conf_int THRESHOLD_TARGETS_DOWN_MAX 0)"
THRESH_ALERTS_WARN="$(ops_conf_int THRESHOLD_ALERTS_FIRING_WARN 0)"
THRESH_ALERTS_STALE_HOURS="$(ops_conf_int THRESHOLD_ALERTS_STALE_HOURS 2)"
THRESH_BLACKBOX_MEDIAN_MS="$(ops_conf_int THRESHOLD_BLACKBOX_MEDIAN_MS 2000)"
PROM_TIMEOUT="$(ops_conf_int PROM_QUERY_TIMEOUT 8)"

CONTAINER_LOG_WINDOW="$(ops_conf_get CONTAINER_LOG_WINDOW 168h)"
REPORT_STALE_FACTOR="$(ops_conf_int REPORT_STALE_FACTOR 2)"
THRESH_APT_LIST_MAX_AGE_DAYS="$(ops_conf_int THRESHOLD_APT_LIST_MAX_AGE_DAYS 7)"

is_root=0
[[ "${EUID:-$(id -u 2>/dev/null || printf '1')}" == "0" ]] && is_root=1

have_curl=0; ops_have_cmd curl && have_curl=1
have_docker=0; ops_have_cmd docker && have_docker=1

# ============================================================================
ops_section "KnowTrace-Workflow 每周运维  主机=$OPS_HOSTNAME  用户=$OPS_USER_NAME  目录=$OPS_CWD"
printf '执行时间(UTC): %s\n' "$OPS_RUN_UTC"
printf '权限级别    : %s\n' "$([[ "$is_root" == "1" ]] && printf 'root' || printf '普通用户（部分检查需要 sudo 才完整）')"
printf '保证        : 本脚本只读，不修改任何服务、容器、配置或数据。\n'

# ----------------------------------------------------------------------------
# 1. 备份完整性校验（重算 SHA-256）
# ----------------------------------------------------------------------------
ops_section "1. 备份完整性校验（重算 SHA-256）"

newest_archive=""
newest_epoch=0
archive_count=0
newest_sha256_file=""

find_newest_archive() {
    local archive epoch
    while IFS= read -r archive; do
        [[ -n "$archive" ]] || continue
        (( archive_count += 1 ))
        epoch="$(ops_mtime "$archive")"
        if (( epoch > newest_epoch )); then
            newest_epoch="$epoch"
            newest_archive="$archive"
        fi
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -type f -name 'knowtrace-*.tar.gz' 2>/dev/null | sort)
}

if [[ ! -d "$BACKUP_ROOT" ]]; then
    ops_fail "backup.root" "备份目录不存在: $BACKUP_ROOT"
else
    find_newest_archive

    if (( archive_count == 0 )); then
        ops_fail "backup.exists" "$BACKUP_ROOT 下没有 knowtrace-*.tar.gz 归档，无法做任何校验"
    else
        newest_name="$(basename -- "$newest_archive")"
        newest_sha256_file="${newest_archive}.sha256"
        age_hours="$(ops_age_hours "$newest_epoch")"
        newest_size="$(du -h -- "$newest_archive" 2>/dev/null | awk '{print $1}')"
        ops_info "backup.count" "共 ${archive_count} 份归档，最新 ${newest_name}（${newest_size:-?}）"

        # 新鲜度（与每日巡检同一套阈值）
        if [[ "$age_hours" == "unknown" ]]; then
            ops_info "backup.freshness" "无法确定最新归档的时间"
        else
            age_int="$(awk -v v="$age_hours" 'BEGIN{printf "%.0f", v}')"
            if (( age_int > THRESH_BACKUP_FAIL_HOURS )); then
                ops_fail "backup.freshness" "最新归档 ${age_hours} 小时前，已超过 ${THRESH_BACKUP_FAIL_HOURS} 小时"
            elif (( age_int > THRESH_BACKUP_WARN_HOURS )); then
                ops_warn "backup.freshness" "最新归档 ${age_hours} 小时前，已超过 ${THRESH_BACKUP_WARN_HOURS} 小时"
            else
                ops_ok "backup.freshness" "最新归档 ${age_hours} 小时前（阈值 ${THRESH_BACKUP_WARN_HOURS}h）"
            fi
        fi

        # ---- 真正做校验：外层的 .sha256 与内部的 SHA256SUMS 都重算 ----
        if [[ ! -f "$newest_sha256_file" ]]; then
            ops_fail "backup.checksum-file" "缺少 ${newest_name}.sha256，无法校验归档完整性"
        elif ! ops_have_cmd sha256sum; then
            ops_warn "backup.checksum-file" "sha256sum 不可用，无法重算校验值"
        else
            expected="$(awk '{print $1}' "$newest_sha256_file" 2>/dev/null | head -n 1)"
            actual="$(sha256sum -- "$newest_archive" 2>/dev/null | awk '{print $1}')"
            if [[ -z "$expected" || -z "$actual" ]]; then
                ops_warn "backup.checksum" "无法读取校验值（expected='${expected:0:12}' actual='${actual:0:12}'）"
            elif [[ "$expected" == "$actual" ]]; then
                ops_ok "backup.checksum" "归档 SHA-256 重算一致（${actual:0:12}…）"
            else
                ops_fail "backup.checksum" "归档 SHA-256 不一致！文件已损坏或被篡改，禁止用于恢复演练"
                printf '       expected: %s\n       actual  : %s\n' "$expected" "$actual"
            fi
        fi

        # ---- 解包校验内部 SHA256SUMS（只解到临时目录，不改动原归档）----
        if ops_have_cmd tar && [[ -f "$newest_sha256_file" ]]; then
            tmp_extract=""
            tmp_extract="$(mktemp -d /tmp/knowtrace-workflow-weekly-check.XXXXXX 2>/dev/null || printf '')"
            if [[ -z "$tmp_extract" ]]; then
                ops_warn "backup.inner-checksum" "无法创建临时目录，跳过后备包内部校验"
            elif [[ "$tmp_extract" != /tmp/knowtrace-workflow-weekly-check.* ]]; then
                ops_warn "backup.inner-checksum" "临时目录不符合安全前缀，跳过：$tmp_extract"
            else
                if tar --extract --gzip --file "$newest_archive" \
                        --directory "$tmp_extract" --warning=no-unknown-keyword 2>/dev/null; then
                    bundle_dir="$(find "$tmp_extract" -mindepth 1 -maxdepth 2 -type f -name SHA256SUMS -printf '%h\n' 2>/dev/null | head -n 1)"
                    if [[ -z "$bundle_dir" ]]; then
                        ops_info "backup.inner-checksum" "归档内未找到 SHA256SUMS（可能不是 backup-all.sh 产物）"
                    else
                        member_count="$(find "$bundle_dir" -type f ! -name SHA256SUMS 2>/dev/null | wc -l | tr -d ' ')"
                        if (( member_count > BACKUP_CHECKSUM_MAX_ITEMS )); then
                            ops_warn "backup.inner-checksum" \
                                "归档内含 ${member_count} 个文件，超过逐项校验上限 ${BACKUP_CHECKSUM_MAX_ITEMS}；本次只校验前 ${BACKUP_CHECKSUM_MAX_ITEMS} 项（未被静默跳过）"
                            head -n "$BACKUP_CHECKSUM_MAX_ITEMS" "$bundle_dir/SHA256SUMS" \
                                > "$tmp_extract/HEAD_SUMS" 2>/dev/null
                            checksum_input="$tmp_extract/HEAD_SUMS"
                        else
                            checksum_input="$bundle_dir/SHA256SUMS"
                        fi

                        if (cd "$bundle_dir" && sha256sum --check --status "$checksum_input" 2>/dev/null); then
                            ops_ok "backup.inner-checksum" "归档内 SHA256SUMS 校验通过（${member_count} 个文件）"
                        else
                            failed_list="$(cd "$bundle_dir" && sha256sum --check "$checksum_input" 2>/dev/null \
                                | grep -E 'FAILED|WARNING' | head -n 5 || printf '')"
                            ops_fail "backup.inner-checksum" "归档内 SHA256SUMS 校验失败，具体见下"
                            [[ -n "$failed_list" ]] && printf '%s\n' "$failed_list" | ops_indent
                        fi
                    fi
                else
                    ops_warn "backup.inner-checksum" "归档无法解包（tar -xzf 失败），可能本身已损坏"
                fi
                rm -rf -- "$tmp_extract" 2>/dev/null || true
            fi
        fi

        # 权限：归档含账号哈希与会话元数据
        if ops_is_group_or_other_readable "$newest_archive"; then
            ops_warn "backup.permissions" "${newest_name} 对同组或其他用户可读，建议 0600"
        else
            ops_ok "backup.permissions" "最新归档权限已收紧"
        fi
    fi

    # 半成品目录与失败现场
    incomplete_count="$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name '.incomplete-*' 2>/dev/null | ops_count_lines)"
    if (( incomplete_count > 0 )); then
        ops_warn "backup.incomplete" "存在 ${incomplete_count} 个 .incomplete-* 目录，说明有备份失败，先排查再清理"
    else
        ops_ok "backup.incomplete" "没有遗留的 .incomplete-* 目录"
    fi

    # 保留策略姿态（只读判断，不删除）
    if [[ -n "${BACKUP_RETENTION_DAYS:-}" || -n "${BACKUP_MIN_KEEP:-}" ]]; then
        ops_fact "保留策略期望：RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-14} MIN_KEEP=${BACKUP_MIN_KEEP:-7}（删除动作在 monthly-ops.sh）"
    fi
fi

if [[ -f "$BACKUP_LOG" ]]; then
    log_age="$(ops_age_hours "$(ops_mtime "$BACKUP_LOG")")"
    ops_info "backup.log" "$BACKUP_LOG 最后更新于 ${log_age} 小时前"
fi

# ----------------------------------------------------------------------------
# 2. 监控 Targets / 探测 / 告警
#
# 逻辑放在 lib/ops-monitor.sh，与 daily-ops.sh 共用同一份实现，
# 避免两个脚本各写一遍 Prometheus 解析而慢慢跑偏。
# ----------------------------------------------------------------------------
ops_section "2. 监控系统（Prometheus / Alertmanager）"

ops_monitor_check "$PROMETHEUS_BASE" "$ALERTMANAGER_BASE"

# 主机 systemd 单元（关键服务 / 备份定时器 / failed 单元）。
# 与 daily-ops 共用同一个函数 —— 判据只有一处实现，避免两份漂移。
ops_systemd_check
# ----------------------------------------------------------------------------
# 3. 日志错误模式（委派 log_analyzer.py）
# ----------------------------------------------------------------------------
ops_section "3. 日志错误模式（聚类 + 基线对比）"

if [[ ! -f "$LOG_ANALYZER" ]]; then
    ops_warn "logs.analyzer" "未找到 $LOG_ANALYZER，跳过日志分析"
elif ! ops_have_cmd python3; then
    ops_warn "logs.analyzer" "python3 不可用，跳过日志分析"
else
    log_json="$(mktemp /tmp/knowtrace-weekly-logs.XXXXXX.json 2>/dev/null || printf '')"
    if [[ -z "$log_json" ]]; then
        ops_warn "logs.analyzer" "无法创建临时文件，跳过日志分析"
    else
        python3 "$LOG_ANALYZER" --since "$CONTAINER_LOG_WINDOW" \
            --json "$log_json" --no-color ${OPS_CONF:+--conf "$OPS_CONF"} >/dev/null 2>&1
        log_rc=$?
        log_worst="$(jq -r '.worst // "unknown"' "$log_json" 2>/dev/null)"
        log_err="$(jq -r '.counts.fail // 0' "$log_json" 2>/dev/null)"
        log_warn="$(jq -r '.counts.warn // 0' "$log_json" 2>/dev/null)"
        log_lines="$(jq -r '[.findings[]? | select(.check == "log.totals")][0].message // empty' "$log_json" 2>/dev/null)"
        log_new="$(jq -r '[.findings[]? | select(.check == "log.new-error-patterns")][0].message // empty' "$log_json" 2>/dev/null)"

        case "$log_worst" in
            FAIL) ops_fail "logs.window" "日志分析结论 FAIL（FAIL=$log_err WARN=$log_warn）${log_lines:+；$log_lines}" ;;
            WARN) ops_warn "logs.window" "日志分析结论 WARN（FAIL=$log_err WARN=$log_warn）${log_lines:+；$log_lines}" ;;
            OK)   ops_ok   "logs.window" "日志分析结论 OK（窗口 ${CONTAINER_LOG_WINDOW}）${log_lines:+；$log_lines}" ;;
            *)    ops_warn "logs.window" "日志分析未产出可解析结论（退出码 $log_rc），请手动运行 python3 $LOG_ANALYZER" ;;
        esac
        [[ -n "$log_new" ]] && ops_warn "logs.new-patterns" "$log_new"

        # TOP 模式作为证据带进来（归一化后的模式串，不含原始数字）
        if [[ "$OPS_QUIET" != "1" ]]; then
            top_patterns="$(jq -r '
                [.findings[]? | select(.check == "log.totals")] | length' "$log_json" 2>/dev/null)"
            printf '       --- 日志报告摘要（完整内容见 %s）---\n' "$log_json"
            jq -r '.findings[]? | select(.level == "FAIL" or .level == "WARN") | "  [\(.level)] \(.check): \(.message)"' \
                "$log_json" 2>/dev/null | head -n 8 | ops_indent
        fi
        rm -f -- "$log_json" 2>/dev/null || true
    fi
fi

# ----------------------------------------------------------------------------
# 4. 系统补丁与磁盘趋势（只读；升级动作属于月运维）
# ----------------------------------------------------------------------------
ops_section "4. 系统补丁与磁盘趋势"

if [[ -f /var/run/reboot-required ]]; then
    ops_warn "patch.reboot-required" "/var/run/reboot-required 存在，需要计划重启（月运维执行）"
else
    ops_ok "patch.reboot-required" "当前不需要重启"
fi

if ops_have_cmd apt-get && [[ -f /var/lib/apt/periodic/update-stamp ]]; then
    stamp_age_days="$(find /var/lib/apt/periodic/update-stamp -maxdepth 0 -mtime +0 -printf '%A@\n' 2>/dev/null | head -n 1)"
    list_mtime="$(ops_mtime /var/lib/apt/periodic/update-stamp)"
    if [[ "$list_mtime" =~ ^[0-9]+$ && "$list_mtime" -gt 0 ]]; then
        list_age_hours="$(ops_age_hours "$list_mtime")"
        list_age_days_int="$(awk -v h="$list_age_hours" 'BEGIN{printf "%.0f", h/24}')"
        if (( list_age_days_int > THRESH_APT_LIST_MAX_AGE_DAYS )); then
            ops_warn "patch.apt-list" "apt 软件包列表已 ${list_age_days_int} 天未更新（阈值 ${THRESH_APT_LIST_MAX_AGE_DAYS} 天）"
        else
            ops_ok "patch.apt-list" "apt 软件包列表 ${list_age_days_int} 天前更新过"
        fi
    fi
else
    ops_info "patch.apt-list" "无法读取 apt 更新戳（或未使用 apt）"
fi

# 待升级包数量（只读：apt-get -s 模拟）
if ops_have_cmd apt-get && [[ "$is_root" == "1" ]]; then
    # `; true` 而不是 `|| printf '0'`：grep -c 在 0 匹配时也打印 "0"（退出码 1），
    # 用 || 会再补一个 0，变成 "0\n0" 让 (( )) 语法错误。
    upgradable="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' 2>/dev/null; true)"
    if [[ "$upgradable" =~ ^[0-9]+$ ]]; then
        if (( upgradable > 0 )); then
            ops_info "patch.upgradable" "有 ${upgradable} 个可升级软件包（升级在 monthly-ops.sh 执行）"
            if [[ "$OPS_QUIET" != "1" ]]; then
                apt-get -s upgrade 2>/dev/null | grep '^Inst ' | head -n 8 | ops_indent
            fi
        else
            ops_ok "patch.upgradable" "没有可升级的软件包"
        fi
    fi
    # 需要重启才算生效的包（内核/glibc/DB 等）
    reboot_pkgs="$(apt-get -s upgrade 2>/dev/null | grep -E '^Inst (linux-image|linux-headers|libc6|libssl|docker|containerd)' | head -n 5 || printf '')"
    if [[ -n "$reboot_pkgs" ]]; then
        ops_warn "patch.reboot-packages" "以下更新需要重启或重启服务才生效，请在月运维安排："
        printf '%s\n' "$reboot_pkgs" | ops_indent
    fi
elif [[ "$is_root" != "1" ]]; then
    ops_info "patch.upgradable" "非 root，跳过可升级包检查（sudo 后重跑可获取）"
fi

# 磁盘/备份目录的增长趋势：用 sysstat 的 sar 拿一周对比（有就报，没有就说没有）
if ops_have_cmd sar; then
    sar_root="$(sar -F 2>/dev/null | awk 'NR<=2 || /^\//' | tail -n 3 || printf '')"
    if [[ -n "$sar_root" ]]; then
        ops_fact "文件系统增长（sar -F 尾部记录）："
        printf '%s\n' "$sar_root" | ops_indent
    fi
else
    ops_info "disk.trend" "未安装 sysstat/sar，无法给出磁盘增长趋势（建议 apt install sysstat）"
fi

# ----------------------------------------------------------------------------
# 5. 巡检报告自身的新鲜度（确认每日巡检在按周期产出）
# ----------------------------------------------------------------------------
ops_section "5. 巡检闭环：报告新鲜度"

if [[ -d "$REPORTS_DIR" ]]; then
    # 每日巡检有两个脚本：daily-ops.sh（本工具包）与线上既有的 daily-check.sh。
    # 两个名字都要算，否则 daily-ops 产出的报告会被判成「今天没有日报」。
    daily_reports="$(find "$REPORTS_DIR" -maxdepth 1 -type f \( -name 'daily-ops-*.json' -o -name 'daily-check-*.json' \) -mtime -1 2>/dev/null | wc -l | tr -d ' ')"
    weekly_reports="$(find "$REPORTS_DIR" -maxdepth 1 -type f -name 'weekly-check-*.json' -mtime -8 2>/dev/null | wc -l | tr -d ' ')"
    total_reports="$(find "$REPORTS_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"

    if (( daily_reports > 0 )); then
        ops_ok "reports.daily" "最近 24 小时内产出 ${daily_reports} 份每日巡检报告"
    else
        # 这是最典型失效模式：定时器悄悄停了，没人知道
        last_daily="$(find "$REPORTS_DIR" -maxdepth 1 -type f \( -name 'daily-ops-*.json' -o -name 'daily-check-*.json' \) -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 || printf '')"
        if [[ -z "$last_daily" ]]; then
            ops_warn "reports.daily" "$REPORTS_DIR 下没有任何每日巡检报告，每日巡检可能还没挂定时任务"
        else
            last_epoch="${last_daily%% *}"
            last_name="$(basename -- "${last_daily#* }")"
            ops_warn "reports.daily" "最近 24 小时没有每日巡检报告；最后一份是 ${last_name}（$(ops_age_hours "$last_epoch") 小时前）"
        fi
    fi

    if (( weekly_reports > 1 )); then
        ops_ok "reports.weekly" "最近 8 天有 ${weekly_reports} 份 weekly-check 报告"
    else
        ops_info "reports.weekly" "最近 8 天只有 ${weekly_reports} 份 weekly-check 报告（本次是首期时可忽略）"
    fi

    ops_info "reports.total" "$REPORTS_DIR 共 ${total_reports} 份 JSON 报告"
else
    ops_info "reports.dir" "报告目录尚未创建: $REPORTS_DIR（首次运行后会创建）"
fi

# ----------------------------------------------------------------------------
# 6~7. 委派既有脚本：证书有效期 / 异常登录
# ----------------------------------------------------------------------------
ops_section "6. 证书有效期与安全访问（委派既有脚本）"
ops_fact "证书检查: $CERT_SCRIPT"
ops_fact "安全访问: $SECURITY_SCRIPT"

delegate_script() {
    local label="$1" checker="$2" path="$3"
    shift 3
    if (( WEEKLY_SKIP_DELEGATE == 1 )); then
        ops_info "$checker" "已用 --skip-delegate 跳过 ${label}"
        return 0
    fi
    if [[ ! -f "$path" ]]; then
        ops_warn "$checker" "未找到 ${label} 脚本: $path"
        return 0
    fi

    local interpreter=()
    case "$path" in
        *.py) ops_have_cmd python3 || { ops_warn "$checker" "python3 不可用，跳过 $label"; return 0; }
              interpreter=(python3) ;;
        *.sh) interpreter=(bash) ;;
    esac

    local out; out="$(mktemp "/tmp/knowtrace-${checker}.XXXXXX.json" 2>/dev/null || printf '')"
    if [[ -z "$out" ]]; then
        ops_warn "$checker" "无法创建临时文件，跳过 $label"
        return 0
    fi

    # 子脚本各自独立；失败不能污染本脚本的结论，因此只记录事实。
    # 参数顺序：脚本 -> 自身参数 -> 通用参数（子脚本的 argparse 不区分位置，但这样更清晰）
    local rc=0
    local argv=("${interpreter[@]}" "$path" "$@" --json "$out" --no-color --quiet)
    [[ -n "${OPS_CONF:-}" ]] && argv+=(--conf "$OPS_CONF")
    "${argv[@]}" >/dev/null 2>&1
    rc=$?

    local worst counts fail_n warn_n
    worst="$(jq -r '.worst // "unknown"' "$out" 2>/dev/null)"
    fail_n="$(jq -r '.counts.fail // 0' "$out" 2>/dev/null)"
    warn_n="$(jq -r '.counts.warn // 0' "$out" 2>/dev/null)"

    case "$worst" in
        FAIL) ops_fail "$checker" "${label} 结论 FAIL（FAIL=$fail_n WARN=$warn_n）" ;;
        WARN) ops_warn "$checker" "${label} 结论 WARN（FAIL=$fail_n WARN=$warn_n）" ;;
        OK)   ops_ok   "$checker" "${label} 结论 OK" ;;
        *)    ops_warn "$checker" "${label} 未产出可解析结论（退出码 $rc），请手动运行 $path" ;;
    esac

    if [[ "$OPS_QUIET" != "1" && -n "$worst" && "$worst" != "OK" ]]; then
        jq -r '.findings[]? | select(.level == "FAIL" or .level == "WARN") | "  [\(.level)] \(.check): \(.message)"' \
            "$out" 2>/dev/null | head -n 8 | ops_indent
    fi
    rm -f -- "$out" 2>/dev/null || true
    return 0
}

delegate_script "证书有效期" "cert" "$CERT_SCRIPT"
delegate_script "安全与访问" "security" "$SECURITY_SCRIPT"

# ----------------------------------------------------------------------------
# 8. 结束
# ----------------------------------------------------------------------------
ops_section "8. 周运维结束"

ops_fact "周清单对照：备份校验 ✓  日志错误模式 ✓  证书有效期 ✓  异常登录 ✓"
ops_fact "未自动验证的项（需人工）：登录后核心页面读写、附件读取 —— 见日常运维清单「KnowTrace-Workflow 业务健康」"
ops_fact "记录建议：现象 / 命令 / 关键证据 / 初步推断 / 处理动作 / 验证结果 / 遗留风险"
ops_fact "失败项请建独立故障记录，模板见 docs/日常运维/ 的 2026-09-20 记录"

# 可选：生成运维记录骨架
if (( WEEKLY_WRITE_RECORD == 1 )); then
    ops_section "9. 生成运维记录骨架"

    record_dir="$RECORD_DIR"
    if [[ ! -d "$record_dir" ]]; then
        if mkdir -p -- "$record_dir" 2>/dev/null; then
            ops_ok "record.dir" "已创建记录目录 $record_dir"
        else
            ops_warn "record.dir" "无法创建记录目录 $record_dir（本脚本不会提权）"
            record_dir=""
        fi
    fi

    if [[ -n "$record_dir" ]]; then
        record_date="$(date -u '+%Y-%m-%d')"
        year_month="$(date -u '+%Y%m')"
        # 与 daily-ops.sh 保持同一套目录结构：<年月>/<日期>-<类型>.md
        if ! mkdir -p -- "$record_dir/$year_month" 2>/dev/null; then
            ops_warn "record.dir" "无法创建记录子目录 $record_dir/$year_month"
        fi
        record_path="$record_dir/$year_month/${record_date}-周运维记录.md"
        worst_now="$(ops_worst_level)"

        {
            printf '# %s 周运维记录\n\n' "$record_date"
            printf '> 由 weekly-check.sh 于 %s 生成骨架。**结论与证据需要人工确认后再定稿**，\n' "$OPS_RUN_UTC"
            printf '> 生成器只预填了机器可判定的部分，不会替你把推断写成结论。\n\n'
            printf '## 基本信息\n\n'
            printf -- '- 主机：%s\n' "$OPS_HOSTNAME"
            printf -- '- 执行用户：%s\n' "$OPS_USER_NAME"
            printf -- '- 执行时间(UTC)：%s\n' "$OPS_RUN_UTC"
            printf -- '- 脚本结论：**%s**\n' "$worst_now"
            printf -- '- 明细：FAIL=%s WARN=%s OK=%s INFO=%s\n' \
                "$(ops_count_level FAIL)" "$(ops_count_level WARN)" \
                "$(ops_count_level OK)" "$(ops_count_level INFO)"
            printf -- '- 窗口：日志 %s / 登录 %s 小时\n\n' "$CONTAINER_LOG_WINDOW" "24"

            printf '## 机器判定的结果\n\n'
            printf '| 级别 | 检查项 | 说明 |\n| --- | --- | --- |\n'
            record_idx=0
            while (( record_idx < ${#ops_finding_level[@]} )); do
                printf '| %s | %s | %s |\n' \
                    "${ops_finding_level[$record_idx]}" \
                    "${ops_finding_check[$record_idx]}" \
                    "$(printf '%s' "${ops_finding_message[$record_idx]}" | sed 's/|/\\|/g')"
                (( record_idx += 1 ))
            done
            printf '\n'

            printf '## 本次结论\n\n'
            printf '<!-- 人工填写：本周是否新增异常、是否影响可用性 -->\n\n'
            printf '## 待补证据\n\n'
            printf '<!-- 人工填写：命令输出、截图路径、报告文件名 -->\n\n'
            printf '## 处理动作\n\n'
            printf '<!-- 人工填写：改了什么、原值/新值、重载命令、回滚方法 -->\n\n'
            printf '## 验证结果\n\n'
            printf '<!-- 人工填写：处理后如何确认恢复；未验证的一律写「未验证」 -->\n\n'

            printf '## 若本周发生故障，按以下字段补一条记录\n\n'
            printf -- '- 时间：\n- 现象：\n- 影响范围：\n- 首次发现方式：\n'
            printf -- '- 排查命令：\n- 关键证据：\n- 根因或当前推断：\n- 处理动作：\n'
            printf -- '- 验证结果：\n- 遗留风险：\n- 后续改进：\n\n'

            printf '## 下一步\n\n'
            printf -- '- [ ] 处理上表所有 FAIL 项\n'
            printf -- '- [ ] 确认 WARN 项是否需要跟进\n'
            printf -- '- [ ] 把本记录归档到 docs/日常运维/\n'
        } > "$record_path" 2>/dev/null

        if [[ -s "$record_path" ]]; then
            ops_ok "record.written" "已生成 $record_path（记得人工定稿后再提交）"
        else
            ops_warn "record.written" "无法写入 $record_path"
        fi
    fi
else
    ops_fact "如需生成运维记录骨架，加 --write-record"
fi

ops_finish "weekly-check" "KnowTrace-Workflow 每周运维"
