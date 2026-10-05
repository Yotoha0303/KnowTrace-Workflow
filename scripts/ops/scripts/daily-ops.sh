#!/usr/bin/env bash
# ============================================================================
# KnowTrace-Workflow 每日运维（只读 + 可选生成当日巡检记录）
# ============================================================================
#
# 对应文档：
#   docs/日常运维/日常运维清单.md（第 160-164 行「日常频率建议」的每日部分）
#   docs/日常运维/2026-09-19-日常巡检记录.md（记录格式来源）
#
# 每日清单（原文）：
#   资源、磁盘、容器、健康接口、监控 Targets
#
# 与线上 scripts/linux/daily-check.sh 的关系
# -----------------------------------------
# daily-check.sh 已经覆盖了资源/磁盘/容器/健康接口，本脚本在此基础上：
#   1. 补上「监控 Targets」——清单里归在每日，但 daily-check.sh 没有查；
#   2. 统一用 lib/ 的公共库与退出码约定，和 weekly/monthly 一致；
#   3. --record 时生成符合 docs/日常运维/ 格式的当日记录到 logs-records 目录。
#
# 本脚本不替代 daily-check.sh：两者可以并存，daily-check.sh 作为「原始数据采集」，
# 本脚本作为「带结论与记录闭环的日巡检」。需要哪一个由使用者决定。
#
# 只读保证：不执行任何修改性动作。唯一写入是报告与 --record 的记录文件。
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
KnowTrace-Workflow 每日运维（只读）

用法:
  ./scripts/daily-ops.sh [选项]

选项:
  --conf <文件>      指定 ops.conf
  --json <文件>      写出 JSON 报告
  --markdown <文件>  写出 Markdown 报告
  --no-json          不写 JSON 报告
  --record           额外生成当日巡检记录（Markdown），路径见 RECORD_DIR
  --quiet, -q        只输出 WARN/FAIL
  --no-color         关闭彩色输出
  --help, -h         显示本帮助

覆盖范围（对应清单「每天」一栏）:
  主机资源（CPU/内存/Swap/负载）  磁盘与 inode   Docker 容器
  业务健康端点（live/ready/auth/nginx）  监控 Targets 与告警

退出码:
  0 未发现异常   1 存在 WARN   2 存在 FAIL
EOF
}

DAILY_RECORD=0
_dargs=()
while (( $# )); do
    case "$1" in
        --record) DAILY_RECORD=1; shift ;;
        *)        _dargs+=("$1"); shift ;;
    esac
done
ops_parse_common_args "${_dargs[@]}"
[[ "${OPS_SHOW_HELP:-0}" == "1" ]] && { usage; exit 0; }
if (( ${#OPS_REMAINING_ARGS[@]} > 0 )); then
    printf '未知参数: %s\n\n' "${OPS_REMAINING_ARGS[*]}" >&2
    usage >&2
    exit 3
fi

ops_require_cmds date hostname awk sed grep stat find df head tail jq
ops_load_conf

# ----------------------------------------------------------------------------
# 配置
# ----------------------------------------------------------------------------
PROJECT_DIR="$(ops_conf_get PROJECT_DIR /opt/knowtrace)"
UPLOAD_DIR="$(ops_conf_get UPLOAD_DIR "$PROJECT_DIR/data/uploads")"
BACKUP_ROOT="$(ops_conf_get BACKUP_ROOT /var/backups/knowtrace)"
DOCKER_DATA_DIR="$(ops_conf_get DOCKER_DATA_DIR /var/lib/docker)"
REPORTS_DIR="$(ops_conf_get REPORTS_DIR /var/lib/knowtrace/reports)"
RECORD_DIR="$(ops_conf_get RECORD_DIR /var/log/knowtrace-logs)"
LOG_ARCHIVE_DIR="$(ops_conf_get LOG_ARCHIVE_DIR /var/log/knowtrace-logs)"

APP_HEALTH_BASE="$(ops_conf_get APP_HEALTH_BASE http://127.0.0.1:3000)"
NGINX_HEALTH_URL="$(ops_conf_get NGINX_HEALTH_URL http://127.0.0.1:8080/api/health/ready)"
AUTH_HEALTH_URL="$(ops_conf_get AUTH_HEALTH_URL http://127.0.0.1:8082/readyz)"
PUBLIC_HEALTH_URL="$(ops_conf_get PUBLIC_HEALTH_URL "")"
PROMETHEUS_BASE="$(ops_conf_get PROMETHEUS_BASE http://127.0.0.1:9090)"
ALERTMANAGER_BASE="$(ops_conf_get ALERTMANAGER_BASE http://127.0.0.1:9093)"

THRESH_DISK_WARN="$(ops_conf_int THRESHOLD_DISK_WARN 80)"
THRESH_DISK_FAIL="$(ops_conf_int THRESHOLD_DISK_FAIL 90)"
THRESH_INODE_WARN="$(ops_conf_int THRESHOLD_INODE_WARN 80)"
THRESH_INODE_FAIL="$(ops_conf_int THRESHOLD_INODE_FAIL 90)"
THRESH_MEM_WARN="$(ops_conf_int THRESHOLD_MEM_WARN 15)"
THRESH_MEM_FAIL="$(ops_conf_int THRESHOLD_MEM_FAIL 8)"
THRESH_SWAP_WARN="$(ops_conf_int THRESHOLD_SWAP_WARN 50)"
THRESH_SWAP_FAIL="$(ops_conf_int THRESHOLD_SWAP_FAIL 80)"
THRESH_LOAD_FACTOR="$(ops_conf_int THRESHOLD_LOAD_WARN_FACTOR 2)"

have_docker=0; ops_have_cmd docker && have_docker=1

# ============================================================================
ops_section "KnowTrace-Workflow 每日运维  主机=$OPS_HOSTNAME  用户=$OPS_USER_NAME  目录=$OPS_CWD"
printf '执行时间(UTC): %s\n' "$OPS_RUN_UTC"
printf '保证        : 本脚本只读，不修改任何服务、容器、配置或数据。\n'

# ----------------------------------------------------------------------------
# 1. 主机资源
# ----------------------------------------------------------------------------
ops_section "1. 主机资源（CPU / 内存 / Swap / 负载）"

cpu_count="$(nproc 2>/dev/null || printf '1')"
[[ "$cpu_count" =~ ^[0-9]+$ && "$cpu_count" -gt 0 ]] || cpu_count=1

if [[ -r /proc/loadavg ]]; then
    read -r load1 load5 load15 _rest < /proc/loadavg
    load1_int="$(awk -v v="$load1" 'BEGIN{printf "%.0f", v}')"
    warn_at=$(( cpu_count * THRESH_LOAD_FACTOR ))
    if (( load1_int >= warn_at * 2 )); then
        ops_fail "host.load1" "1 分钟负载 ${load1} 达到 ${cpu_count} vCPU 的 $(( THRESH_LOAD_FACTOR * 2 )) 倍"
    elif (( load1_int >= warn_at )); then
        ops_warn "host.load1" "1 分钟负载 ${load1} 超过 ${cpu_count} vCPU 的 ${THRESH_LOAD_FACTOR} 倍"
    else
        ops_ok "host.load1" "1 分钟负载 ${load1}（vCPU ${cpu_count}，5/15 分钟 ${load5}/${load15}）"
    fi
else
    ops_warn "host.load1" "无法读取 /proc/loadavg"
fi

mem_total_mib="$(awk '/^MemTotal:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || printf '0')"
mem_avail_mib="$(awk '/^MemAvailable:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || printf '0')"
swap_total_mib="$(awk '/^SwapTotal:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || printf '0')"
swap_free_mib="$(awk '/^SwapFree:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || printf '0')"

if [[ "$mem_total_mib" =~ ^[0-9]+$ && "$mem_total_mib" -gt 0 ]]; then
    mem_avail_pct="$(ops_int_div "$(( mem_avail_mib * 100 ))" "$mem_total_mib")"
    detail="可用 ${mem_avail_mib}MiB / 共 ${mem_total_mib}MiB（${mem_avail_pct}%）"
    if (( mem_avail_pct < THRESH_MEM_FAIL )); then
        ops_fail "host.memory" "$detail，低于 ${THRESH_MEM_FAIL}%"
    elif (( mem_avail_pct < THRESH_MEM_WARN )); then
        ops_warn "host.memory" "$detail，低于 ${THRESH_MEM_WARN}%"
    else
        ops_ok "host.memory" "$detail"
    fi
else
    ops_warn "host.memory" "无法解析内存信息"
fi

if [[ "$swap_total_mib" =~ ^[0-9]+$ && "$swap_total_mib" -gt 0 ]]; then
    swap_used_mib=$(( swap_total_mib - swap_free_mib ))
    swap_used_pct="$(ops_int_div "$(( swap_used_mib * 100 ))" "$swap_total_mib")"
    detail="已用 ${swap_used_mib}MiB / 共 ${swap_total_mib}MiB（${swap_used_pct}%）"
    if (( swap_used_pct >= THRESH_SWAP_FAIL )); then
        ops_fail "host.swap" "$detail，swap 压力过大"
    elif (( swap_used_pct >= THRESH_SWAP_WARN )); then
        ops_warn "host.swap" "$detail，先确认是否由 Loki/Alloy / 构建 / 日志堆积引起"
    else
        ops_ok "host.swap" "$detail"
    fi
else
    ops_info "host.swap" "未配置 swap（运维清单要求至少 2GiB swap，请确认）"
fi

# 需要重启内核时提醒（阶段一的遗留项）
if [[ -f /var/run/reboot-required ]]; then
    ops_warn "host.reboot-required" "/var/run/reboot-required 存在，需要计划重启"
else
    ops_ok "host.reboot-required" "当前不需要重启"
fi

if [[ "$OPS_QUIET" != "1" ]]; then
    printf '       --- 占用最高的进程（CPU）---\n'
    ps -eo pid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -n 6 | ops_indent
fi

# ----------------------------------------------------------------------------
# 2. 磁盘与 inode
# ----------------------------------------------------------------------------
ops_section "2. 磁盘与 inode"

check_fs() {
    local label="$1" path="$2"
    if [[ ! -d "$path" ]]; then
        ops_info "disk.$label" "路径不存在，跳过: $path"
        return 0
    fi
    local usage avail
    usage="$(df -P -- "$path" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
    avail="$(df -h -- "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ ! "$usage" =~ ^[0-9]+$ ]]; then
        ops_warn "disk.$label" "无法读取 $path 的使用率"
        return 0
    fi
    local detail="已用 ${usage}%（可用 ${avail}）: $path"
    if (( usage >= THRESH_DISK_FAIL )); then
        ops_fail "disk.$label" "$detail"
    elif (( usage >= THRESH_DISK_WARN )); then
        ops_warn "disk.$label" "$detail"
    else
        ops_ok "disk.$label" "$detail"
    fi
}

check_fs "root"        "/"
check_fs "docker-data" "$DOCKER_DATA_DIR"
check_fs "backup"      "$BACKUP_ROOT"
check_fs "project"     "$PROJECT_DIR"

if [[ -d "$UPLOAD_DIR" ]]; then
    ops_info "disk.uploads" "上传目录体积 $(du -sh "$UPLOAD_DIR" 2>/dev/null | awk '{print $1}')"
else
    ops_warn "disk.uploads" "上传目录不存在，备份范围可能不完整: $UPLOAD_DIR"
fi

inode_usage="$(df -Pi / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
if [[ "$inode_usage" =~ ^[0-9]+$ ]]; then
    if (( inode_usage >= THRESH_INODE_FAIL )); then
        ops_fail "disk.inode" "根分区 inode 已用 ${inode_usage}%"
    elif (( inode_usage >= THRESH_INODE_WARN )); then
        ops_warn "disk.inode" "根分区 inode 已用 ${inode_usage}%"
    else
        ops_ok "disk.inode" "根分区 inode 已用 ${inode_usage}%"
    fi
fi

# 日常清单明确关注 logs-records 目录的增长
if [[ -d "$LOG_ARCHIVE_DIR" ]]; then
    ops_info "disk.log-archive" "日志存档 $(du -sh "$LOG_ARCHIVE_DIR" 2>/dev/null | awk '{print $1}')，文件数 $(find "$LOG_ARCHIVE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
fi

# ----------------------------------------------------------------------------
# 3. Docker 容器
# ----------------------------------------------------------------------------
ops_section "3. Docker 容器"

if (( have_docker == 0 )); then
    ops_warn "docker" "docker 命令不可用，无法检查容器"
else
    running_names="$(docker ps --format '{{.Names}}' 2>/dev/null || printf '')"
    if [[ -z "$running_names" ]]; then
        ops_fail "docker.running" "没有运行中的容器"
    else
        ops_ok "docker.running" "$(printf '%s\n' "$running_names" | ops_count_lines) 个容器运行中"
    fi

    expected_missing=""
    for service in $(ops_conf_list EXPECTED_SERVICES "app auth postgres auth-mysql auth-redis"); do
        ops_service_running "$service" \
            || expected_missing="${expected_missing}${service} "
    done
    if [[ -z "$expected_missing" ]]; then
        ops_ok "docker.expected" "核心服务容器全部存在"
    else
        ops_fail "docker.expected" "缺少运行中的核心容器: ${expected_missing% }"
    fi

    optional_missing=""
    for service in $(ops_conf_list OPTIONAL_SERVICES "prometheus grafana alertmanager blackbox-exporter node-exporter"); do
        ops_service_running "$service" \
            || optional_missing="${optional_missing}${service} "
    done
    if [[ -z "$optional_missing" ]]; then
        ops_ok "docker.optional" "监控组件容器全部在运行"
    else
        ops_warn "docker.optional" "以下监控容器未运行: ${optional_missing% }"
    fi

    restarting="$(docker ps -a --filter 'status=restarting' --format '{{.Names}}' 2>/dev/null | tr '\n' ' ' || printf '')"
    if [[ -n "${restarting// /}" ]]; then
        ops_fail "docker.restarting" "容器处于反复重启状态: ${restarting% }"
    else
        ops_ok "docker.restarting" "没有处于 restarting 状态的容器"
    fi

    # Loki/Alloy 是常驻组件（不像 ELK 需按需启停），运行本身只记事实
    plg_running=""
    for service in loki alloy; do
        ops_service_running "$service" \
            && plg_running="${plg_running}${service} "
    done
    if [[ -n "${plg_running// /}" ]]; then
        ops_ok "docker.plg" "PLG 日志栈运行中（${plg_running% }）"
    else
        ops_warn "docker.plg" "Loki/Alloy 未运行 —— 日志将无法采集与查询"
    fi

    if [[ "$OPS_QUIET" != "1" ]]; then
        printf '       --- docker ps ---\n'
        docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null | ops_indent
    fi
fi

# ----------------------------------------------------------------------------
# 4. 业务健康端点
# ----------------------------------------------------------------------------
ops_section "4. 业务健康端点"

check_http() {
    local check="$1" label="$2" url="$3"
    [[ -n "$url" ]] || { ops_info "$check" "$label 未配置 URL，跳过"; return 0; }
    if ! ops_have_cmd curl; then
        ops_warn "$check" "curl 不可用，无法检查 $label"
        return 0
    fi
    local code total
    read -r code total < <(ops_http_probe "$url")
    if [[ "$code" == "000" ]]; then
        ops_fail "$check" "$label 无响应: $url（已重试 ${OPS_HTTP_RETRIES:-3} 次）"
    elif [[ "$code" == 2* ]]; then
        ops_ok "$check" "$label HTTP $code（${total}s）"
    else
        ops_fail "$check" "$label HTTP $code（期望 2xx），$url"
    fi
}

check_http "health.live"  "应用存活 /api/health/live"  "$APP_HEALTH_BASE/api/health/live"
check_http "health.ready" "应用就绪 /api/health/ready" "$APP_HEALTH_BASE/api/health/ready"
check_http "health.auth"  "认证就绪 /readyz"           "$AUTH_HEALTH_URL"
check_http "health.nginx" "Nginx 反向代理链路"          "$NGINX_HEALTH_URL"
check_http "health.public" "公网 HTTPS 就绪"           "$PUBLIC_HEALTH_URL"

ops_fact "提醒：/api/ready 不是本项目健康端点（会返回 401），不要用它作为故障证据。"
ops_fact "登录页/记录列表/附件读取属于人工验证项，脚本不做（无法在不写入数据的前提下验证）。"

# ----------------------------------------------------------------------------
# 5. 监控 Targets（清单归在每日）
# ----------------------------------------------------------------------------
ops_section "5. 监控 Targets 与告警"
ops_monitor_check "$PROMETHEUS_BASE" "$ALERTMANAGER_BASE"

# ----------------------------------------------------------------------------
# 5b. 主机 systemd 单元（关键服务 / 备份定时器 / failed 单元）
# ----------------------------------------------------------------------------
# 清单里归在每日。实测（2026-10-05）此前这条**不在任何按计划跑的判据里**：
# daily-check.sh 有这一节，但它**没有任何定时器**；跑着的是本脚本。
ops_section "5b. 主机 systemd 单元"
ops_systemd_check

# ----------------------------------------------------------------------------
# 6. 巡检闭环：报告是否在按时产出
# ----------------------------------------------------------------------------
ops_section "6. 巡检闭环"

if [[ -d "$REPORTS_DIR" ]]; then
    today_count="$(find "$REPORTS_DIR" -maxdepth 1 -type f -name 'daily-ops-*.json' -mtime -1 2>/dev/null | wc -l | tr -d ' ')"
    ops_info "reports.today" "最近 24 小时有 ${today_count} 份 daily-ops 报告"
else
    ops_info "reports.dir" "报告目录尚未创建: $REPORTS_DIR"
fi

# ----------------------------------------------------------------------------
# 7. 结束
# ----------------------------------------------------------------------------
ops_section "7. 每日运维结束"
ops_fact "日清单对照：资源 ✓  磁盘 ✓  容器 ✓  健康接口 ✓  监控 Targets ✓"
ops_fact "未自动验证的人工项：登录页、记录列表、记录详情、附件读取、数据库读写"

if (( DAILY_RECORD == 1 )); then
    ops_section "8. 生成当日巡检记录"
    if [[ ! -d "$RECORD_DIR" ]]; then
        if mkdir -p -- "$RECORD_DIR" 2>/dev/null; then
            ops_ok "record.dir" "已创建记录目录 $RECORD_DIR"
        else
            ops_warn "record.dir" "无法创建记录目录 $RECORD_DIR"
            RECORD_DIR=""
        fi
    fi
    if [[ -n "$RECORD_DIR" ]]; then
        record_date="$(date -u '+%Y-%m-%d')"
        year_month="$(date -u '+%Y%m')"
        record_path="$RECORD_DIR/${year_month}/${record_date}.md"
        if mkdir -p -- "$RECORD_DIR/$year_month" 2>/dev/null; then
            {
                printf '# %s 日常巡检记录\n\n' "$record_date"
                printf '> 由 daily-ops.sh 于 %s 生成骨架。**结论与证据需人工确认后再定稿**。\n\n' "$OPS_RUN_UTC"
                printf '## 基本信息\n\n'
                printf -- '- 主机：%s\n- 执行用户：%s\n- 执行时间(UTC)：%s\n' \
                    "$OPS_HOSTNAME" "$OPS_USER_NAME" "$OPS_RUN_UTC"
                printf -- '- 脚本结论：**%s**（FAIL=%s WARN=%s OK=%s INFO=%s）\n\n' \
                    "$(ops_worst_level)" "$(ops_count_level FAIL)" "$(ops_count_level WARN)" \
                    "$(ops_count_level OK)" "$(ops_count_level INFO)"
                printf '## 机器判定的结果\n\n| 级别 | 检查项 | 说明 |\n| --- | --- | --- |\n'
                r_i=0
                while (( r_i < ${#ops_finding_level[@]} )); do
                    printf '| %s | %s | %s |\n' \
                        "${ops_finding_level[$r_i]}" \
                        "${ops_finding_check[$r_i]}" \
                        "$(printf '%s' "${ops_finding_message[$r_i]}" | sed 's/|/\\|/g')"
                    (( r_i += 1 ))
                done
                printf '\n## 本次结论\n\n<!-- 人工填写：是否新增异常、是否影响可用性 -->\n\n'
                printf '## 本次已执行操作\n\n<!-- 人工填写；只读巡检应写「无修改性操作」 -->\n\n'
                printf '## 待补证据\n\n<!-- 人工填写：命令输出、截图路径（.\\images\\%s\\）-->\n\n' "$year_month"
                printf '## 下一步\n\n- [ ] 处理 FAIL 项\n- [ ] 确认 WARN 项是否需要跟进\n'
            } > "$record_path" 2>/dev/null
            if [[ -s "$record_path" ]]; then
                ops_ok "record.written" "已生成 $record_path（人工定稿后再提交）"
            else
                ops_warn "record.written" "无法写入 $record_path"
            fi
            # 保持 logs-records 目录下有一次「最新」的快捷入口
            latest_link="$RECORD_DIR/latest.md"
            rm -f -- "$latest_link" 2>/dev/null || true
            ln -s -- "${year_month}/${record_date}.md" "$latest_link" 2>/dev/null \
                && ops_info "record.latest" "已更新快捷链接 $latest_link" \
                || true
        else
            ops_warn "record.dir" "无法创建目录 $RECORD_DIR/$year_month"
        fi
    fi
else
    ops_fact "如需生成当日巡检记录，加 --record"
fi

ops_finish "daily-ops" "KnowTrace-Workflow 每日运维"
