#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================
# KnowTrace-Workflow 运维公共库 —— 监控系统只读检查
# ============================================================================
#
# 被 daily-ops.sh（每天）与 weekly-check.sh（每周）共用，避免两处各写一份
# Prometheus/Alertmanager 解析逻辑。
#
# 依赖：ops-common.sh 必须先 source（使用 ops_ok / ops_warn / ops_fail / ops_info /
#       ops_conf_int / ops_conf_get / ops_have_cmd）。
#
# 只读保证：只调用 Prometheus / Alertmanager 的 GET 查询接口，
#           不调用任何 -/reload、/-/quit 或 admin API。
#
# 用法：
#   source "$SCRIPT_DIR/../lib/ops-monitor.sh"
#   ops_monitor_check          # 结果通过 ops_* 记入当前结论
# ============================================================================

[[ -n "${OPS_MONITOR_LOADED:-}" ]] && return 0
OPS_MONITOR_LOADED=1

ops_monitor_url() {
    local url="$1"
    curl -sS --max-time "${OPS_MONITOR_TIMEOUT:-8}" "$url" 2>/dev/null
}

# 检查监控系统；返回 0 总是成功（结论通过 ops_* 记录），
# 这样调用方不必关心「监控没装」和「监控挂了」的区别。
ops_monitor_check() {
    local prometheus_base="${1:-$(ops_conf_get PROMETHEUS_BASE http://127.0.0.1:9090)}"
    local alertmanager_base="${2:-$(ops_conf_get ALERTMANAGER_BASE http://127.0.0.1:9093)}"

    local thresh_targets_min thresh_down_max thresh_firing
    local thresh_stale_hours thresh_latency_ms
    thresh_targets_min="$(ops_conf_int THRESHOLD_TARGETS_MIN 10)"
    thresh_down_max="$(ops_conf_int THRESHOLD_TARGETS_DOWN_MAX 0)"
    thresh_firing="$(ops_conf_int THRESHOLD_ALERTS_FIRING_WARN 0)"
    thresh_stale_hours="$(ops_conf_int THRESHOLD_ALERTS_STALE_HOURS 2)"
    thresh_latency_ms="$(ops_conf_int THRESHOLD_BLACKBOX_MEDIAN_MS 2000)"

    if ! ops_have_cmd curl; then
        ops_warn "mon.prometheus" "curl 不可用，无法检查监控系统"
        return 0
    fi
    if ! ops_have_cmd jq; then
        ops_warn "mon.prometheus" "jq 不可用，无法结构化解析 Prometheus API（apt install jq）"
        return 0
    fi

    # ---- Prometheus: targets ----
    local targets_json total_targets down_targets job_summary
    targets_json="$(ops_monitor_url "$prometheus_base/api/v1/targets?state=any")"

    if [[ -z "$targets_json" ]]; then
        ops_fail "mon.prometheus" "无法访问 Prometheus API: $prometheus_base/api/v1/targets"
    elif [[ "$(printf '%s' "$targets_json" | jq -r '.status // "error"' 2>/dev/null)" != "success" ]]; then
        ops_fail "mon.prometheus" "Prometheus API 返回非 success 状态"
    else
        total_targets="$(printf '%s' "$targets_json" | jq -r '[.data.activeTargets[]?] | length' 2>/dev/null)"
        down_targets="$(printf '%s' "$targets_json" | jq -r '[.data.activeTargets[]? | select(.health != "up")] | length' 2>/dev/null)"
        [[ "$total_targets" =~ ^[0-9]+$ ]] || total_targets=0
        [[ "$down_targets" =~ ^[0-9]+$ ]] || down_targets=0

        if (( total_targets < thresh_targets_min )); then
            ops_fail "mon.targets-count" "抓取目标只有 ${total_targets} 个，低于下限 ${thresh_targets_min}，抓取面疑似塌陷"
        else
            ops_ok "mon.targets-count" "抓取目标 ${total_targets} 个（下限 ${thresh_targets_min}）"
        fi

        if (( down_targets > thresh_down_max )); then
            ops_fail "mon.targets-down" "${down_targets} 个抓取目标非 up（允许 ≤ ${thresh_down_max}）"
            if [[ "$OPS_QUIET" != "1" ]]; then
                printf '       --- 非 up 的 target ---\n'
                printf '%s' "$targets_json" | jq -r \
                    '.data.activeTargets[]? | select(.health != "up") | "  \(.labels.job // "?") | \(.scrapeUrl) | \(.health) | \(.lastError // "")"' \
                    2>/dev/null | head -n 10 | ops_indent
            fi
        else
            ops_ok "mon.targets-down" "所有抓取目标均为 up"
        fi

        # 按 job 汇总，便于发现「某类 exporter 整体掉线」
        job_summary="$(printf '%s' "$targets_json" | jq -r \
            '[.data.activeTargets[]? | {job: (.labels.job // "unknown"), health: .health}]
             | group_by(.job)
             | map({job: .[0].job, up: (map(select(.health=="up"))|length), all: length})
             | sort_by(.job) | .[] | "  \(.job): \(.up)/\(.all) up"' 2>/dev/null)"
        if [[ -n "$job_summary" && "$OPS_QUIET" != "1" ]]; then
            printf '       --- 按 job 汇总 ---\n'
            printf '%s\n' "$job_summary" | ops_indent
        fi

        # ---- blackbox 外部可达性 ----
        local bb_total bb_down
        bb_total="$(printf '%s' "$targets_json" | jq -r '[.data.activeTargets[]? | select((.labels.job // "") | test("blackbox"))] | length' 2>/dev/null)"
        bb_down="$(printf '%s' "$targets_json" | jq -r '[.data.activeTargets[]? | select((.labels.job // "") | test("blackbox")) | select(.health != "up")] | length' 2>/dev/null)"
        if [[ ! "$bb_total" =~ ^[0-9]+$ ]] || (( bb_total == 0 )); then
            ops_info "mon.blackbox" "没有 blackbox job 的抓取目标，跳过探测检查"
        elif (( bb_down > 0 )); then
            ops_fail "mon.blackbox" "${bb_down}/${bb_total} 个 blackbox 探测目标非 up（外部可达性可能已断）"
        else
            ops_ok "mon.blackbox" "blackbox 探测 ${bb_total} 个目标全部 up"
        fi
    fi

    # ---- Alertmanager: 告警与链路新鲜度 ----
    #
    # /api/v2/alerts 返回的**不只是**正在响的告警。status.state 只有三态
    # （active / suppressed / unprocessed，见 Alertmanager 自身的
    # alertmanager_alerts{state=...} 指标），被 inhibit_rules 抑制掉的、以及还没
    # 处理完的都在同一个数组里。直接数数组长度会把它们一并算成「告警」，
    # 所以这里显式只取 active。
    #
    # severity=info 是本项目自定义的「事实记录」级别：见 init-observability-env.sh，
    # 它被单独路由到 local-only —— 只进 UI、不进邮箱，为的就是不变成每天一封的噪声。
    # 但它同样会出现在这个数组里；若与 warning/critical 一起计入阈值，一条
    # 「运行态只是落后了、应用行为没变」的 info 就会天天把日报顶成 WARN，
    # 而 WARN 是要留给人看真问题的。因此 info 单独计数、单独记一行 INFO。
    #
    # 严重度只报不升级：critical 不会把巡检结论抬到 FAIL。原因是
    # knowtrace_ops_report_worst_level 又喂给 KnowTraceOpsCheckFailed，
    # 一旦 FAIL 会让下一天的巡检再次看到 critical —— 自锁成永久 FAIL。
    # 「谁来叫醒人」是设计问题，先如实把数字摆出来。
    local alerts_json firing firing_info sev_critical sev_warning
    alerts_json="$(ops_monitor_url "$alertmanager_base/api/v2/alerts")"
    if [[ -z "$alerts_json" ]]; then
        ops_warn "mon.alertmanager" "无法访问 Alertmanager API: $alertmanager_base/api/v2/alerts"
    elif ! printf '%s' "$alerts_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        ops_warn "mon.alertmanager" "Alertmanager 返回了非预期格式，无法解析告警数"
    else
        # 缺 severity 标签的按 warning 计 —— 宁可多报，不要因为少一个标签就静默漏掉。
        firing="$(printf '%s' "$alerts_json" | jq -r \
            '[.[] | select(.status.state == "active") | select((.labels.severity // "warning") != "info")] | length' 2>/dev/null)"
        firing_info="$(printf '%s' "$alerts_json" | jq -r \
            '[.[] | select(.status.state == "active") | select((.labels.severity // "") == "info")] | length' 2>/dev/null)"
        sev_critical="$(printf '%s' "$alerts_json" | jq -r \
            '[.[] | select(.status.state == "active") | select((.labels.severity // "") == "critical")] | length' 2>/dev/null)"
        sev_warning="$(printf '%s' "$alerts_json" | jq -r \
            '[.[] | select(.status.state == "active") | select((.labels.severity // "") == "warning")] | length' 2>/dev/null)"
        [[ "$firing" =~ ^[0-9]+$ ]] || firing=0
        [[ "$firing_info" =~ ^[0-9]+$ ]] || firing_info=0
        [[ "$sev_critical" =~ ^[0-9]+$ ]] || sev_critical=0
        [[ "$sev_warning" =~ ^[0-9]+$ ]] || sev_warning=0
        if (( firing > thresh_firing )); then
            ops_warn "mon.alerts-firing" "${firing} 条告警处于 active 状态（阈值 ≤ ${thresh_firing}；其中 critical ${sev_critical} / warning ${sev_warning}）"
            if [[ "$OPS_QUIET" != "1" ]]; then
                printf '%s' "$alerts_json" | jq -r \
                    '.[] | select(.status.state == "active") | select((.labels.severity // "warning") != "info")
                     | "  \(.labels.alertname // "?") [\(.labels.severity // "-")] \(.labels.instance // .labels.job // "")"' \
                    2>/dev/null | head -n 10 | ops_indent
            fi
        else
            ops_ok "mon.alerts-firing" "当前无非 info 的 active 告警"
        fi
        # info 是事实记录，不是故障：单独记一行，不参与阈值。
        if (( firing_info > 0 )); then
            local info_names
            info_names="$(printf '%s' "$alerts_json" | jq -r \
                '[.[] | select(.status.state == "active") | select((.labels.severity // "") == "info")
                  | (.labels.alertname // "?")] | join(", ")' 2>/dev/null)"
            ops_info "mon.alerts-info" "${firing_info} 条 info 级事实记录处于 active（不计入阈值）: ${info_names}"
        fi
    fi

    # 告警出口是否还在：AM 容器不在，告警就没有去处
    if ops_have_cmd docker; then
        local am_container
        # 按服务名解析容器，不写死容器名前缀 —— 否则仓库/项目改名后这里会
        # 把"在跑的 Alertmanager"报成"未运行、告警链路已断"（2026-10-03 实际发生过）
        if am_container="$(ops_container_for_service alertmanager)"; then
            local am_last
            am_last="$(docker logs --tail 1 "$am_container" 2>&1 | head -n 1 || printf '')"
            # 长时间没有新日志 = 可能没有告警在流转，也可能是链路断了，因此只记事实
            ops_info "mon.alertmanager-log" "Alertmanager 最后一行日志: ${am_last:0:140}"
        else
            ops_fail "mon.alertmanager-container" "Alertmanager 容器未运行，告警链路已断（Prometheus 的告警无处发送）"
        fi
    fi

    # ---- Prometheus 自身的 API 延迟（只记事实 + 阈值提醒）----
    local query p95_json p95 p95_ms
    query='histogram_quantile(0.95, sum(rate(prometheus_http_request_duration_seconds_bucket[1h])) by (le))'
    p95_json="$(ops_monitor_url "$prometheus_base/api/v1/query?query=$(printf '%s' "$query" | jq -sRr @uri)")"
    p95="$(printf '%s' "${p95_json:-}" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null)"
    if [[ -n "$p95" ]]; then
        p95_ms="$(awk -v v="$p95" 'BEGIN{printf "%.0f", v*1000}')"
        if [[ "$p95_ms" =~ ^[0-9]+$ ]] && (( p95_ms > thresh_latency_ms )); then
            ops_warn "mon.prometheus-latency" "Prometheus API p95 延迟 ${p95_ms}ms，超过 ${thresh_latency_ms}ms"
        else
            ops_info "mon.prometheus-latency" "Prometheus API p95 延迟 ${p95_ms}ms"
        fi
    fi

    return 0
}
