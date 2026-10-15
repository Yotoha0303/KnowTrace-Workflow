#!/usr/bin/env bash
# ============================================================================
# KnowTrace-Workflow 日常巡检（只读）
# ============================================================================
#
# 对应文档：
#   docs/日常运维/日常运维清单.md
#   KnowTrace-ops/archive/docs/KnowTrace-Workflow-VPS-部署学习-2026-09-06/阶段二/文档/07-备份巡检与故障处理SOP.md（6.1 每日五分钟巡检）
#
# 职责（Bash 的系统操作层）：
#   主机身份 / 运行时间 / 负载 / CPU / 内存 / Swap / 磁盘 / inode
#   关键 systemd 服务 / Docker 容器与重启次数 / 容器日志错误扫描
#   KnowTrace-Workflow 与应用链路健康端点 / 备份新鲜度与权限 / 监听端口 / UFW
#
# 不做（这些属于 Python 自动化逻辑层）：
#   证书剩余天数计算  -> scripts/cert_check.py
#   备份 SHA-256 重算  -> scripts/backup_check.py
#   日志聚类与趋势统计 -> scripts/log_analyzer.py
#
# 只读保证：本脚本不执行 stop/start/restart/rm/down 等任何修改性 Docker 或
# systemctl 动作，也不会删除文件。唯一写入是 JSON 报告（可用 --no-json 关闭）。
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
KnowTrace-Workflow 日常巡检（只读）

用法:
  ./scripts/daily-check.sh [选项]

选项:
  --conf <文件>   指定 ops.conf（默认 <仓库根>/ops.conf，其次 /etc/knowtrace/ops.conf）
  --json <文件>   写出 JSON 报告到指定路径
  --markdown <文件>  写出 Markdown 报告到指定路径（与 daily-ops.sh 格式一致）
  --no-json       不写 JSON 报告
  --quiet, -q     只输出 WARN/FAIL，用于定时任务与告警
  --no-color      关闭彩色输出
  --help, -h      显示本帮助

退出码:
  0 未发现异常   1 存在 WARN   2 存在 FAIL

示例:
  ./scripts/daily-check.sh | tee /var/log/knowtrace-daily-check.log
  ./scripts/daily-check.sh --quiet --json /var/lib/knowtrace/reports/daily.json
  ./scripts/daily-check.sh --quiet --json /var/lib/knowtrace/reports/       --markdown /var/lib/knowtrace/reports/
EOF
}

ops_parse_common_args "$@"
[[ "${OPS_SHOW_HELP:-0}" == "1" ]] && { usage; exit 0; }
if (( ${#OPS_REMAINING_ARGS[@]} > 0 )); then
    printf '未知参数: %s\n\n' "${OPS_REMAINING_ARGS[*]}" >&2
    usage >&2
    exit 3
fi

# 注意：内存信息直接读 /proc/meminfo，因此不把 free 列为硬依赖
# （最小化系统或容器镜像里可能没有 procps 包）。
ops_require_cmds date hostname awk sed grep stat find df ps tail head
ops_load_conf

# ----------------------------------------------------------------------------
# 配置（默认值刻意沿用服务器现有部署，全部可在 ops.conf 覆盖）
# ----------------------------------------------------------------------------
PROJECT_DIR="$(ops_conf_get PROJECT_DIR /opt/knowtrace)"
COMPOSE_OVERLAY="$(ops_conf_get COMPOSE_OVERLAY compose.production.yaml)"
BACKUP_ROOT="$(ops_conf_get BACKUP_ROOT /var/backups/knowtrace)"
UPLOAD_DIR="$(ops_conf_get UPLOAD_DIR "$PROJECT_DIR/data/uploads")"
DOCKER_DATA_DIR="$(ops_conf_get DOCKER_DATA_DIR /var/lib/docker)"
APP_HEALTH_BASE="$(ops_conf_get APP_HEALTH_BASE http://127.0.0.1:3000)"
NGINX_HEALTH_URL="$(ops_conf_get NGINX_HEALTH_URL http://127.0.0.1:8080/api/health/ready)"
AUTH_HEALTH_URL="$(ops_conf_get AUTH_HEALTH_URL http://127.0.0.1:8082/readyz)"
PUBLIC_HEALTH_URL="$(ops_conf_get PUBLIC_HEALTH_URL "")"
BACKUP_LOG="$(ops_conf_get BACKUP_LOG /var/log/knowtrace-workflow-backup.log)"
BACKUP_TIMER_UNIT="$(ops_conf_get BACKUP_TIMER_UNIT knowtrace-workflow-backup.timer)"
# 让工具包公共库的默认报告目录跟随 ops.conf，与 daily-ops/weekly-check 落到同一个
# REPORTS_DIR。不设这一项时，ops_write_json 的兜底路径是 <工具包>/reports/，
# 于是同一批巡检的报告会分裂成两份互不可见的目录，汇总与新鲜度判定都会看漏。
export REPORTS_DIR="$(ops_conf_get REPORTS_DIR /var/lib/knowtrace/reports)"
LOG_SCAN_LINES="$(ops_conf_int LOG_SCAN_LINES 100)"
CONTAINER_LOG_KEYWORDS="$(ops_conf_get CONTAINER_LOG_KEYWORDS 'error|panic|timeout|connection refused|permission denied')"

# 阈值
THRESH_DISK_WARN="$(ops_conf_int THRESHOLD_DISK_WARN 80)"
THRESH_DISK_FAIL="$(ops_conf_int THRESHOLD_DISK_FAIL 90)"
THRESH_INODE_WARN="$(ops_conf_int THRESHOLD_INODE_WARN 80)"
THRESH_INODE_FAIL="$(ops_conf_int THRESHOLD_INODE_FAIL 90)"
THRESH_MEM_WARN="$(ops_conf_int THRESHOLD_MEM_WARN 15)"
THRESH_MEM_FAIL="$(ops_conf_int THRESHOLD_MEM_FAIL 8)"
THRESH_SWAP_WARN="$(ops_conf_int THRESHOLD_SWAP_WARN 50)"
THRESH_SWAP_FAIL="$(ops_conf_int THRESHOLD_SWAP_FAIL 80)"
THRESH_LOAD_WARN_FACTOR="$(ops_conf_int THRESHOLD_LOAD_WARN_FACTOR 2)"
THRESH_BACKUP_WARN_HOURS="$(ops_conf_int THRESHOLD_BACKUP_WARN_HOURS 26)"
THRESH_BACKUP_FAIL_HOURS="$(ops_conf_int THRESHOLD_BACKUP_FAIL_HOURS 48)"

COMPOSE_FILES=(-f "$PROJECT_DIR/compose.yaml")
[[ -n "$COMPOSE_OVERLAY" && -f "$PROJECT_DIR/$COMPOSE_OVERLAY" ]] && COMPOSE_FILES+=(-f "$PROJECT_DIR/$COMPOSE_OVERLAY")

have_docker=0
ops_have_cmd docker && have_docker=1

compose() {
    docker compose --project-directory "$PROJECT_DIR" "${COMPOSE_FILES[@]}" "$@" 2>/dev/null
}

compose_available() {
    (( have_docker == 1 )) || return 1
    [[ -f "$PROJECT_DIR/compose.yaml" ]] || return 1
    compose version >/dev/null 2>&1
}

# ============================================================================
ops_section "KnowTrace-Workflow 日常巡检  主机=$OPS_HOSTNAME  用户=$OPS_USER_NAME  目录=$OPS_CWD"
printf '巡检时间(UTC): %s\n' "$OPS_RUN_UTC"
printf '说明: 以下结论只覆盖本次执行时刻。修改任何服务前请先保存现场证据。\n'

# ----------------------------------------------------------------------------
# 1. 主机身份与运行时间
# ----------------------------------------------------------------------------
ops_section "1. 主机与运行时间"

uptime_text="$(uptime 2>/dev/null || printf '')"
if [[ -n "$uptime_text" ]]; then
    ops_info "host.uptime" "$uptime_text"
fi

boot_time="$(uptime -s 2>/dev/null || printf '')"
if [[ -n "$boot_time" ]]; then
    boot_epoch="$(date -d "$boot_time" '+%s' 2>/dev/null || printf '0')"
    if [[ "$boot_epoch" =~ ^[0-9]+$ && "$boot_epoch" -gt 0 ]]; then
        ops_info "host.uptime-hours" "$(ops_age_hours "$boot_epoch") 小时（启动于 $boot_time）"
    fi
fi

# 内核与发行版（只读事实）
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    ops_fact "$(. /etc/os-release 2>/dev/null; printf '%s %s' "${PRETTY_NAME:-unknown}" "$(uname -r 2>/dev/null)")"
fi

# 需要重启加载新内核时给出提醒（阶段一记录过这个遗留项）
if [[ -f /var/run/reboot-required ]]; then
    ops_warn "host.reboot-required" "/var/run/reboot-required 存在，系统需要计划重启"
fi

# ----------------------------------------------------------------------------
# 2. 负载与 CPU
# ----------------------------------------------------------------------------
ops_section "2. 负载与 CPU"

cpu_count="$(nproc 2>/dev/null || printf '1')"
[[ "$cpu_count" =~ ^[0-9]+$ && "$cpu_count" -gt 0 ]] || cpu_count=1

if [[ -r /proc/loadavg ]]; then
    read -r load1 load5 load15 _rest < /proc/loadavg
    ops_fact "vCPU=$cpu_count  load1=$load1 load5=$load5 load15=$load15"
    load1_int="$(awk -v v="$load1" 'BEGIN{printf "%.0f", v**1}')"
    warn_threshold="$(awk -v c="$cpu_count" -v f="$THRESH_LOAD_WARN_FACTOR" 'BEGIN{printf "%.0f", c*f}')"
    if (( load1_int >= warn_threshold * 2 )); then
        ops_fail "host.load1" "1 分钟负载 ${load1} 达到 ${cpu_count} vCPU 的 $(( THRESH_LOAD_WARN_FACTOR * 2 )) 倍"
    elif (( load1_int >= warn_threshold )); then
        ops_warn "host.load1" "1 分钟负载 ${load1} 超过 vCPU 的 ${THRESH_LOAD_WARN_FACTOR} 倍"
    else
        ops_ok "host.load1" "1 分钟负载 ${load1}（vCPU ${cpu_count}）"
    fi
else
    ops_warn "host.load1" "无法读取 /proc/loadavg"
fi

if [[ "$OPS_QUIET" != "1" ]]; then
    printf '\n       --- 占用最高的进程（CPU）---\n'
    ps -eo pid,ppid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -n 8 | ops_indent
fi

# ----------------------------------------------------------------------------
# 3. 内存与 Swap
# ----------------------------------------------------------------------------
ops_section "3. 内存与 Swap"

if [[ "$OPS_QUIET" != "1" ]] && ops_have_cmd free; then
    printf '       --- free -h ---\n'
    free -h | ops_indent
fi

mem_total_mib="$(awk '/^MemTotal:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || printf '0')"
mem_avail_mib="$(awk '/^MemAvailable:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || printf '0')"
swap_total_mib="$(awk '/^SwapTotal:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || printf '0')"
swap_free_mib="$(awk '/^SwapFree:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || printf '0')"

if [[ "$mem_total_mib" =~ ^[0-9]+$ && "$mem_total_mib" -gt 0 && "$mem_avail_mib" =~ ^[0-9]+$ ]]; then
    mem_avail_pct="$(ops_int_div "$(( mem_avail_mib * 100 ))" "$mem_total_mib")"
    mem_detail="可用 ${mem_avail_mib}MiB / 共 ${mem_total_mib}MiB（${mem_avail_pct}%）"
    if (( mem_avail_pct < THRESH_MEM_FAIL )); then
        ops_fail "host.memory" "$mem_detail，低于 ${THRESH_MEM_FAIL}%"
    elif (( mem_avail_pct < THRESH_MEM_WARN )); then
        ops_warn "host.memory" "$mem_detail，低于 ${THRESH_MEM_WARN}%"
    else
        ops_ok "host.memory" "$mem_detail"
    fi
else
    ops_warn "host.memory" "无法解析内存信息"
fi

if [[ "$swap_total_mib" =~ ^[0-9]+$ && "$swap_total_mib" -gt 0 ]]; then
    swap_used_mib=$(( swap_total_mib - swap_free_mib ))
    swap_used_pct="$(ops_int_div "$(( swap_used_mib * 100 ))" "$swap_total_mib")"
    swap_detail="已用 ${swap_used_mib}MiB / 共 ${swap_total_mib}MiB（${swap_used_pct}%）"
    if (( swap_used_pct >= THRESH_SWAP_FAIL )); then
        ops_fail "host.swap" "$swap_detail，swap 压力过大"
    elif (( swap_used_pct >= THRESH_SWAP_WARN )); then
        ops_warn "host.swap" "$swap_detail，先确认是否由 Loki/Alloy / 构建 / 日志堆积引起"
    else
        ops_ok "host.swap" "$swap_detail"
    fi
elif [[ "$swap_total_mib" == "0" ]]; then
    ops_info "host.swap" "未配置 swap（本项目文档要求至少 2GiB swap，请确认）"
fi

# ----------------------------------------------------------------------------
# 4. 磁盘与 inode
# ----------------------------------------------------------------------------
ops_section "4. 磁盘与 inode"

check_filesystem() {
    local label="$1" path="$2" warn="$3" fail="$4"
    [[ -d "$path" ]] || { ops_info "disk.$label" "路径不存在，跳过: $path"; return 0; }

    local usage avail
    usage="$(df -P -- "$path" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
    avail="$(df -h -- "$path" 2>/dev/null | awk 'NR==2 {print $4}')"

    if [[ ! "$usage" =~ ^[0-9]+$ ]]; then
        ops_warn "disk.$label" "无法读取 $path 的使用率"
        return 0
    fi

    local detail="已用 ${usage}%（可用 ${avail}）: $path"
    if (( usage >= fail )); then
        ops_fail "disk.$label" "$detail"
    elif (( usage >= warn )); then
        ops_warn "disk.$label" "$detail"
    else
        ops_ok "disk.$label" "$detail"
    fi
}

check_filesystem "root"             "/"                        "$THRESH_DISK_WARN"  "$THRESH_DISK_FAIL"
check_filesystem "docker-data"      "$DOCKER_DATA_DIR"         "$THRESH_DISK_WARN"  "$THRESH_DISK_FAIL"
check_filesystem "backup"           "$BACKUP_ROOT"             "$THRESH_DISK_WARN"  "$THRESH_DISK_FAIL"
check_filesystem "project"          "$PROJECT_DIR"             "$THRESH_DISK_WARN"  "$THRESH_DISK_FAIL"

# 上传目录增长是磁盘的主要变量之一，单独记录体积
if [[ -d "$UPLOAD_DIR" ]]; then
    upload_size="$(du -sh "$UPLOAD_DIR" 2>/dev/null | awk '{print $1}')"
    ops_info "disk.uploads" "上传目录体积 ${upload_size:-unknown}: $UPLOAD_DIR"
else
    ops_warn "disk.uploads" "上传目录不存在，备份范围可能不完整: $UPLOAD_DIR"
fi

# inode 用尽时磁盘看起来还有空间却写不进去，必须单独检查
if [[ "$OPS_QUIET" != "1" ]]; then
    printf '       --- df -i / ---\n'
    df -i / 2>/dev/null | ops_indent
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

if (( have_docker == 1 )); then
    docker_df="$(docker system df 2>/dev/null || printf '')"
    if [[ -n "$docker_df" && "$OPS_QUIET" != "1" ]]; then
        printf '       --- docker system df ---\n'
        printf '%s\n' "$docker_df" | ops_indent
    fi
fi

# ----------------------------------------------------------------------------
# 5. 关键 systemd 服务
# ----------------------------------------------------------------------------
ops_section "5. 关键 systemd 服务"

if ops_have_cmd systemctl; then
    for unit in $(ops_conf_list SYSTEMD_UNITS "docker nginx caddy ssh"); do
        state="$(systemctl is-active "$unit" 2>/dev/null || printf 'unknown')"
        enabled="$(systemctl is-enabled "$unit" 2>/dev/null || printf 'unknown')"
        if [[ "$state" == "active" ]]; then
            ops_ok "systemd.$unit" "active / $enabled"
        elif [[ "$state" == "unknown" ]]; then
            ops_info "systemd.$unit" "未找到该 unit（可能未安装）"
        else
            ops_fail "systemd.$unit" "$state / $enabled"
        fi
    done

    # 备份定时器：只有在实际使用 systemd timer 的环境才检查
    if systemctl list-unit-files "$BACKUP_TIMER_UNIT" >/dev/null 2>&1 \
        && [[ -n "$(systemctl list-unit-files "$BACKUP_TIMER_UNIT" 2>/dev/null | grep -F "$BACKUP_TIMER_UNIT" || true)" ]]; then
        timer_state="$(systemctl is-active "$BACKUP_TIMER_UNIT" 2>/dev/null || printf 'unknown')"
        next_run="$(systemctl list-timers "$BACKUP_TIMER_UNIT" --all --no-pager 2>/dev/null | awk 'NR==2 {print $1" "$2" "$3}')"
        if [[ "$timer_state" == "active" ]]; then
            ops_ok "systemd.$BACKUP_TIMER_UNIT" "active，下次执行: ${next_run:-unknown}"
        else
            ops_fail "systemd.$BACKUP_TIMER_UNIT" "$timer_state，自动备份可能没有在运行"
        fi
    else
        ops_info "systemd.$BACKUP_TIMER_UNIT" "未安装该定时器（若用 cron 备份可忽略）"
    fi
else
    ops_info "systemd.services" "systemctl 不可用，跳过"
fi

# ----------------------------------------------------------------------------
# 6. Docker 容器
# ----------------------------------------------------------------------------
ops_section "6. Docker 容器"

if (( have_docker == 1 )); then
    if [[ "$OPS_QUIET" != "1" ]]; then
        printf '       --- docker ps ---\n'
        docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | ops_indent
    fi

    running_names="$(docker ps --format '{{.Names}}' 2>/dev/null || printf '')"
    if [[ -z "$running_names" ]]; then
        ops_fail "docker.running" "没有运行中的容器"
    else
        running_count="$(printf '%s\n' "$running_names" | ops_count_lines)"
        ops_ok "docker.running" "${running_count} 个容器运行中"
    fi

    # 期望存在的容器（服务名 -> 容器名前缀 knowtrace-<service>-1）
    expected_missing=""
    for service in $(ops_conf_list EXPECTED_SERVICES "app auth postgres auth-mysql auth-redis"); do
        if ! ops_service_running "$service"; then
            expected_missing="${expected_missing}${service} "
        fi
    done
    if [[ -z "$expected_missing" ]]; then
        ops_ok "docker.expected" "核心服务容器全部存在"
    else
        ops_fail "docker.expected" "缺少运行中的核心容器: ${expected_missing% }"
    fi

    # 监控组件是可选常驻的，缺失记为 WARN 而不是 FAIL
    optional_missing=""
    for service in $(ops_conf_list OPTIONAL_SERVICES "prometheus grafana alertmanager blackbox-exporter node-exporter"); do
        if ! ops_service_running "$service"; then
            optional_missing="${optional_missing}${service} "
        fi
    done
    if [[ -z "$optional_missing" ]]; then
        ops_ok "docker.optional" "监控组件容器全部在运行"
    else
        ops_warn "docker.optional" "以下监控容器未运行: ${optional_missing% }"
    fi

    plg_running=""
    for service in loki alloy; do
        ops_service_running "$service" \
            && plg_running="${plg_running}${service} "
    done
    if [[ -n "$plg_running" ]]; then
        ops_ok "docker.plg" "PLG 日志栈运行中（${plg_running% }）"
    else
        ops_warn "docker.plg" "Loki/Alloy 未运行 —— 日志将无法采集与查询"
    fi

    # 频繁重启：Restarting 状态或启动不足 2 分钟的可疑容器
    restarting="$(docker ps -a --filter 'status=restarting' --format '{{.Names}}' 2>/dev/null | tr '\n' ' ' || printf '')"
    if [[ -n "${restarting// /}" ]]; then
        ops_fail "docker.restarting" "容器处于反复重启状态: ${restarting% }"
    else
        ops_ok "docker.restarting" "没有处于 restarting 状态的容器"
    fi

    # 非 running 的已退出容器，仅提示（退出的一次性任务属于正常）
    exited="$(docker ps -a --filter 'status=exited' --format '{{.Names}}' 2>/dev/null | tr '\n' ' ' || printf '')"
    if [[ -n "${exited// /}" ]]; then
        ops_info "docker.exited" "已退出容器: ${exited% }"
    fi
else
    ops_warn "docker" "docker 命令不可用，无法检查容器"
fi

# ----------------------------------------------------------------------------
# 7. 容器日志错误扫描
# ----------------------------------------------------------------------------
ops_section "7. 容器日志关键错误扫描（最近 ${LOG_SCAN_LINES} 行）"

if (( have_docker == 1 )) && [[ -n "$running_names" ]]; then
    hit_containers=""
    while IFS= read -r container; do
        [[ -n "$container" ]] || continue
        matches="$(docker logs --tail "$LOG_SCAN_LINES" "$container" 2>&1 \
            | grep -Ei "$CONTAINER_LOG_KEYWORDS" \
            | tail -n 8 || true)"
        if [[ -n "$matches" ]]; then
            hit_containers="${hit_containers}${container} "
            if [[ "$OPS_QUIET" != "1" ]]; then
                printf '       --- %s ---\n' "$container"
                printf '%s\n' "$matches" | ops_indent
            fi
        fi
    done <<<"$running_names"

    if [[ -z "$hit_containers" ]]; then
        ops_ok "logs.error-scan" "运行中的容器日志未匹配到 error/panic/timeout 等关键字"
    else
        # 「匹配到关键字」不是故障结论，只是需要人工确认的线索
        ops_warn "logs.error-scan" "以下容器日志出现可疑关键字，需人工确认: ${hit_containers% }"
    fi
else
    ops_info "logs.error-scan" "无运行中容器或 docker 不可用，跳过"
fi

# 更深一层的「错误聚类 + 时间趋势」请使用 Python 脚本：
ops_fact "如需错误聚类统计与标记解读，请运行: scripts/log_analyzer.py --containers app,auth --since 24h"

# ----------------------------------------------------------------------------
# 8. 应用与链路健康端点
# ----------------------------------------------------------------------------
ops_section "8. 应用与链路健康端点"

check_http() {
    local check="$1" label="$2" url="$3" expect="${4:-2}"
    [[ -n "$url" ]] || { ops_info "$check" "$label 未配置 URL，跳过"; return 0; }

    if ! ops_have_cmd curl; then
        ops_warn "$check" "curl 不可用，无法检查 $label"
        return 0
    fi

    local code total
    read -r code total < <(ops_http_probe "$url" "$expect")

    if [[ "$code" == "000" ]]; then
        ops_fail "$check" "$label 无响应: $url（已重试 ${OPS_HTTP_RETRIES:-3} 次）"
        return 0
    fi

    case "$expect" in
        2)  if [[ "$code" == 2* ]]; then ops_ok "$check" "$label HTTP $code（${total}s）"; else ops_fail "$check" "$label HTTP $code（期望 2xx），$url"; fi ;;
        *)  if [[ "$code" == "$expect" ]]; then ops_ok "$check" "$label HTTP $code"; else ops_warn "$check" "$label HTTP $code（期望 $expect），$url"; fi ;;
    esac
    return 0
}

check_http "health.live"       "应用存活 /api/health/live"   "$APP_HEALTH_BASE/api/health/live"  2
check_http "health.ready"      "应用就绪 /api/health/ready"  "$APP_HEALTH_BASE/api/health/ready" 2
check_http "health.auth"       "认证就绪 /readyz"            "$AUTH_HEALTH_URL"                  2

# Nginx 127.0.0.1:8080 的正代链路（注意：/api/metrics 被 Nginx 固定返回 404 是设计如此）
check_http "health.nginx"      "Nginx 反向代理链路"          "$NGINX_HEALTH_URL"                 2

# 公网端点：只做只读探测，不做压测；压测请用 load-baseline.py
if [[ -n "$PUBLIC_HEALTH_URL" ]]; then
    check_http "health.public" "公网 HTTPS 就绪"  "$PUBLIC_HEALTH_URL" 2
else
    ops_fact "未配置 PUBLIC_HEALTH_URL，跳过公网端点检查（如需请设置其为 https://<域名>/api/health/ready）"
fi

ops_fact "提醒：/api/ready 不是本项目健康端点（会返回 401），不要用它作为故障证据。"

# ----------------------------------------------------------------------------
# 9. 备份新鲜度与权限
# ----------------------------------------------------------------------------
ops_section "9. 备份新鲜度与权限"

if [[ -d "$BACKUP_ROOT" ]]; then
    newest_archive=""
    newest_epoch=0
    archive_count=0
    while IFS= read -r archive; do
        [[ -n "$archive" ]] || continue
        (( archive_count += 1 ))
        epoch="$(ops_mtime "$archive")"
        if (( epoch > newest_epoch )); then
            newest_epoch="$epoch"
            newest_archive="$archive"
        fi
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -type f -name 'knowtrace-*.tar.gz' 2>/dev/null)

    if (( archive_count == 0 )); then
        ops_fail "backup.exists" "$BACKUP_ROOT 下没有 knowtrace-*.tar.gz 归档"
    else
        age_hours="$(ops_age_hours "$newest_epoch")"
        newest_name="$(basename -- "$newest_archive")"
        newest_size="$(du -h -- "$newest_archive" 2>/dev/null | awk '{print $1}')"
        detail="最新归档 ${newest_name}（${newest_size:-?}，${age_hours} 小时前），共 ${archive_count} 份"

        if [[ "$age_hours" == "unknown" ]]; then
            ops_info "backup.freshness" "$detail"
        else
            age_int="$(awk -v v="$age_hours" 'BEGIN{printf "%.0f", v}')"
            if (( age_int > THRESH_BACKUP_FAIL_HOURS )); then
                ops_fail "backup.freshness" "$detail，已超过 ${THRESH_BACKUP_FAIL_HOURS} 小时"
            elif (( age_int > THRESH_BACKUP_WARN_HOURS )); then
                ops_warn "backup.freshness" "$detail，已超过 ${THRESH_BACKUP_WARN_HOURS} 小时"
            else
                ops_ok "backup.freshness" "$detail"
            fi
        fi

        # 校验文件是否存在（重算哈希属于 backup_check.py 的职责）
        if [[ -f "${newest_archive}.sha256" ]]; then
            ops_ok "backup.checksum-file" "存在 ${newest_name}.sha256"
        else
            ops_fail "backup.checksum-file" "缺少 ${newest_name}.sha256，无法做完整性校验"
        fi

        # 归档含全部知识内容、账号哈希与会话元数据，权限必须收紧
        if ops_is_group_or_other_readable "$newest_archive"; then
            ops_warn "backup.permissions" "$(basename -- "$newest_archive") 对同组或其他用户可读，建议 0600"
        else
            ops_ok "backup.permissions" "最新归档权限已收紧"
        fi
    fi

    # 失败留下的 .incomplete-* 现场目录绝不能当成有效备份
    incomplete_count="$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name '.incomplete-*' 2>/dev/null | ops_count_lines)"
    if (( incomplete_count > 0 )); then
        ops_warn "backup.incomplete" "存在 ${incomplete_count} 个 .incomplete-* 目录，说明有备份失败，请先排查再清理"
    fi
else
    ops_fail "backup.root" "备份目录不存在: $BACKUP_ROOT"
fi

# 备份执行日志（systemd 单元的日志位置）
if [[ -f "$BACKUP_LOG" ]]; then
    log_age="$(ops_age_hours "$(ops_mtime "$BACKUP_LOG")")"
    ops_info "backup.log" "$BACKUP_LOG 最后更新于 ${log_age} 小时前"
fi

ops_fact "完整性校验（重算 SHA-256）请运行: scripts/backup_check.py"

# ----------------------------------------------------------------------------
# 10. 监听端口与防火墙
# ----------------------------------------------------------------------------
ops_section "10. 监听端口与防火墙"

if [[ "$OPS_QUIET" != "1" ]] && ops_have_cmd ss; then
    printf '       --- ss -lntup ---\n'
    ss -lntup 2>/dev/null | ops_indent
fi

# 管理端口必须只绑定 127.0.0.1：9090 Prometheus、3001 Grafana、9093 Alertmanager、
# 3100 Loki、5000 Alloy（Loki push 入口）、8082 auth
# （2026-10-03：ELK 的 9200/5601 已随 PLG 替换删除，见 docs/16-stage3-observability.md）
if ops_have_cmd ss; then
    bad_bindings=""
    for port in 9090 3001 9093 3100 5000; do
        if ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; then
            # 绑定地址不是 127.0.0.1 或 ::1 即视为暴露
            if ss -lntH 2>/dev/null | awk '{print $4}' \
                | grep -E "[:.]${port}$" \
                | grep -vqE '^(127\.0\.0\.1|\[::1\]|::1)[:. ]'; then
                bad_bindings="${bad_bindings}${port} "
            fi
        fi
    done
    if [[ -z "$bad_bindings" ]]; then
        ops_ok "net.admin-ports" "监控与日志端口未发现非 127.0.0.1 绑定"
    else
        ops_fail "net.admin-ports" "以下管理端口可能已暴露到非本地地址: ${bad_bindings% }"
    fi

    # 记录公网监听事实
    public_listeners="$(ss -lntH 2>/dev/null | awk '{print $4}' \
        | grep -vE '^(127\.0\.0\.1|\[::1\]|::1)[:. ]' \
        | sort -u | tr '\n' ' ' || printf '')"
    if [[ -n "${public_listeners// /}" ]]; then
        ops_info "net.listeners" "非本地监听地址: ${public_listeners% }"
    fi
fi

if ops_have_cmd ufw; then
    if [[ "$OPS_QUIET" != "1" ]]; then
        printf '       --- ufw status ---\n'
        ufw status verbose 2>/dev/null | ops_indent \
            || ops_fact "ufw status 需要 root 权限（sudo 后重跑可获取完整输出）"
    fi
    if ufw status 2>/dev/null | head -n 1 | grep -qi 'Status: active'; then
        ops_ok "net.ufw" "UFW 已启用"
    else
        ops_warn "net.ufw" "UFW 未启用或无法读取状态（阶段一要求 active）"
    fi
else
    ops_info "net.ufw" "未安装 ufw"
fi

# ----------------------------------------------------------------------------
# 11. 项目仓库状态（发布前的一个静态事实）
# ----------------------------------------------------------------------------
ops_section "11. 项目仓库状态"

if [[ -d "$PROJECT_DIR/.git" ]]; then
    head_commit="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
    head_subject="$(git -C "$PROJECT_DIR" log -1 --pretty=%s 2>/dev/null || printf '')"
    ops_info "repo.commit" "$head_commit  $head_subject"

    dirty_count="$(git -C "$PROJECT_DIR" status --short 2>/dev/null | ops_count_lines)"
    if (( dirty_count > 0 )); then
        ops_info "repo.dirty" "工作区有 ${dirty_count} 项未提交改动（生产环境请确认这是有意的）"
    else
        ops_ok "repo.dirty" "工作区干净"
    fi
else
    ops_info "repo" "$PROJECT_DIR 不是 git 工作区，跳过"
fi

# ----------------------------------------------------------------------------
# 12. 巡检结束
# ----------------------------------------------------------------------------
ops_section "12. 巡检结束"

ops_fact "本脚本只做只读巡检。发现异常时：先保存证据，再做人工分析。"
ops_fact "记录建议：异常现象 / 命令输出 / 关键证据 / 初步推断 / 处理动作 / 验证结果 / 遗留风险"
ops_fact "证书有效期: scripts/cert_check.py    备份完整性: scripts/backup_check.py"
ops_fact "日志错误模式: scripts/log_analyzer.py    汇总报告: scripts/ops-report.py"

ops_finish "daily-check" "KnowTrace-Workflow 日常巡检"
