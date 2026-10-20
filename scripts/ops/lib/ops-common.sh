#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================
# KnowTrace-Workflow 运维公共库 —— Bash 系统操作层
# ============================================================================
#
# 定位：本文件被 daily-check.sh / security-check.sh / run-daily-ops.sh 等脚本
#       source，提供「配置加载 + 结果分级 + 结论汇总 + JSON 输出」四件公共事。
#
# 约定（与 docs/日常运维/ 的记录原则一致）：
#   1. 只做只读判断，不在这里执行任何修改性动作。
#   2. 每个结论分四级：OK / WARN / FAIL / INFO。
#      - OK   已确认符合预期
#      - WARN 需要关注，但尚未影响可用性
#      - FAIL 已确认异常，需要处理
#      - INFO 事实记录，不构成判断
#   3. 推断不得写成结论。没实际验证的内容一律 INFO 或不写。
#   4. 退出码固定为三档：0=无异常，1=存在 WARN，2=存在 FAIL。
#      这个约定让脚本可以安全地接入 systemd / cron，也能被 ops-report.py 汇总。
#
# 用法（在脚本开头）：
#   SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
#   # shellcheck source=../lib/ops-common.sh
#   source "$SCRIPT_DIR/../lib/ops-common.sh"
#   ops_parse_common_args "$@"
#   ops_load_conf
#   ... ops_section / ops_ok / ops_warn / ops_fail / ops_info ...
#   ops_finish "daily-check" "KnowTrace-Workflow 日常巡检"
# ============================================================================

[[ -n "${OPS_COMMON_LOADED:-}" ]] && return 0
OPS_COMMON_LOADED=1
OPS_COMMON_VERSION="1.0.0"

# ----------------------------------------------------------------------------
# 0. 运行上下文
# ----------------------------------------------------------------------------

OPS_RUN_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
OPS_RUN_EPOCH="$(date -u '+%s')"
OPS_HOSTNAME="$(hostname 2>/dev/null || printf 'unknown')"
OPS_USER_NAME="${SUDO_USER:-$(whoami 2>/dev/null || printf 'unknown')}"
OPS_CWD="$(pwd)"
OPS_QUIET="${OPS_QUIET:-0}"
OPS_NO_COLOR="${OPS_NO_COLOR:-0}"
OPS_JSON_OUT="${OPS_JSON_OUT:-}"
OPS_JSON_DISABLED="${OPS_JSON_DISABLED:-0}"
OPS_MARKDOWN_OUT="${OPS_MARKDOWN_OUT:-}"
USER_NAME="$OPS_USER_NAME"

# 仓库根目录 = 本文件所在目录（lib/）的上一级
_ops_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
OPS_DEFAULT_ROOT="$(cd -- "$_ops_lib_dir/.." && pwd -P)"
OPS_ROOT="${OPS_ROOT:-$OPS_DEFAULT_ROOT}"
unset _ops_lib_dir

# 命令行参数（供调用脚本继续解析自己的参数）
OPS_REMAINING_ARGS=()

# 颜色只在终端且未显式关闭时启用
if [[ "$OPS_NO_COLOR" != "0" ]] || [[ ! -t 1 ]] || [[ -n "${NO_COLOR:-}" ]]; then
    C_RESET=""; C_OK=""; C_WARN=""; C_FAIL=""; C_INFO=""; C_TITLE=""
else
    C_RESET=$'\033[0m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
    C_FAIL=$'\033[31m'; C_INFO=$'\033[36m'; C_TITLE=$'\033[1m'
fi

# ----------------------------------------------------------------------------
# 1. 基础工具
# ----------------------------------------------------------------------------

ops_have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

ops_die() {
    printf '%s 严重错误：%s\n' "${C_FAIL}[FAIL]${C_RESET}" "$*" >&2
    exit 3
}

# 校验「带值选项」后面确实跟着一个值。调用方式：ops_require_value "$@"
# （$1 = 选项名，$2 = 取值）。
#
# 必须在主 shell 里直接调用，**不能**写成 X="$(ops_require_value "$@")"：
# 命令替换会 fork 出子 shell，子 shell 里的 exit 只结束它自己，主脚本照常往下走，
# 于是 shift 2 失败（非零退出但不中断循环）、$1 原地不动 ——
# 参数解析循环就会永远匹配同一个 case，100% CPU 死循环。
ops_require_value() {
    (( $# >= 2 )) || ops_die "选项 $1 缺少取值"
}

# 探测一个 HTTP 端点，输出 "<状态码> <耗时秒>"。
#
# 为什么要重试：公网探测是「单次 curl --max-time N」时，一次瞬时抖动（DNS 抖动、
# 连接被丢弃、TLS 握手超时）就会返回 000，脚本据此记 FAIL 并让退出码变 2。
# 实测遇到过一次：https://.../api/health/ready 返回 000，紧接着连测 3 次都是 200
# （DNS 0.04s / TLS 0.09s / total 0.10s）。挂到告警链路后这种误报会消耗对告警的信任，
# 所以任何要拿去告警的探测都必须重试。
#
# 重试策略：只在「没拿到 HTTP 状态码（000）」时重试 —— 那是传输层失败，值得再试；
# 拿到 4xx/5xx 说明服务确实应答了，重试没有意义，直接返回真实状态码。
#
# 用法：read -r code total < <(ops_http_probe <url> [期望码正则] [尝试次数])
# 环境变量 OPS_HTTP_RETRIES 可覆盖默认尝试次数（默认 3）。
ops_http_probe() {
    local url="$1" want="${2:-*}" attempts="${3:-${OPS_HTTP_RETRIES:-3}}"
    [[ "$attempts" =~ ^[0-9]+$ ]] && (( attempts >= 1 )) || attempts=1

    local i code total result=""
    for (( i = 1; i <= attempts; i++ )); do
        read -r code total < <(curl -k -s -o /dev/null -w '%{http_code} %{time_total}' \
            --max-time 8 "$url" 2>/dev/null || printf '000 0')
        [[ "$code" =~ ^[0-9]+$ ]] || code=000
        [[ "$total" =~ ^[0-9.]+$ ]] || total=0
        result="$code $total"
        # 拿到了状态码就不再重试，哪怕它不是期望值
        [[ "$code" != "000" ]] && break
        (( i < attempts )) && sleep 1
    done
    printf '%s' "$result"
}

# 检查依赖命令，缺失即终止（避免“看起来跑了但没测到”的假通过）
ops_require_cmds() {
    local missing=() cmd
    for cmd in "$@"; do
        ops_have_cmd "$cmd" || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        ops_die "缺少必要命令: ${missing[*]}（请安装后重试）"
    fi
}

# 把任意文本转成可安全放进 JSON 字符串的形式
ops_json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# 整数四舍五入（避免依赖 bc）
# 入参容错：调用方常写 $(( errors * 100 ))，而 errors 若因历史写法带上了换行
# （见下面 ops_count_lines 的说明）就会是 "0\n0"，此时 $(( )) 早已报语法错误。
# 这里再兜一层，保证任何输入都得到一个合法整数。
ops_int_div() {
    local numerator="${1:-0}" denominator="${2:-1}"
    [[ "$numerator" =~ ^-?[0-9]+$ ]] || numerator=0
    [[ "$denominator" =~ ^[0-9]+$ ]] || denominator=1
    (( denominator == 0 )) && denominator=1
    printf '%s' "$(awk -v a="$numerator" -v b="$denominator" 'BEGIN{printf "%.0f", a/b}')"
}

# 统计非空行数。总是输出一个合法的十进制整数。
#   管道用法：cmd | ops_count_lines
#   直接传参：ops_count_lines "$file"      （文件读取失败时输出 0，而不是报错）
#
# ⚠ 两种错误写法都会导致「同一行出现两个 0」（"0\n0"），后续 `(( count > 0 ))`
#   直接语法错误（`error token is "0"`），而且因为 `set -e` 没开，脚本会带着
#   半错状态继续跑，看起来像正常输出：
#     1. `cmd | grep -c . || printf '0'` —— grep -c 在 0 匹配时也打印 "0"，只是退出码 1
#     2. `grep -c PATTERN file || printf '0'` —— 文件不存在/不可读时 grep 什么都不打印，
#        退出码 2，`||` 补一个 "0"，本意是好的；但一旦 grep 成功匹配 0 行，
#        它已经打印了 "0" 且退出码 1，于是又变成 "0\n0"
#   要数「匹配 0 行也算成功」的计数，正确写法是加 `; true` 而不是 `|| printf`：
#     count="$(grep -c PATTERN file 2>/dev/null; true)"
ops_count_lines() {
    local n
    if (( $# > 0 )); then
        n="$(grep -c . -- "$1" 2>/dev/null)"
    else
        n="$(grep -c . 2>/dev/null)"
    fi
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# 文件 mtime（epoch 秒）
ops_mtime() {
    stat -c %Y -- "$1" 2>/dev/null || printf '0'
}

# epoch 秒 → 距现在的小时数
ops_age_hours() {
    local epoch="${1:-0}"
    [[ "$epoch" =~ ^[0-9]+$ && "$epoch" -gt 0 ]] || { printf 'unknown'; return 0; }
    printf '%s' "$(awk -v now="$OPS_RUN_EPOCH" -v then="$epoch" 'BEGIN{printf "%.1f", (now-then)/3600}')"
}

# 文件权限的“是否对同组/其他用户开放”判断（备份与 .env 必须 600/700）
ops_is_group_or_other_readable() {
    local path="$1" perms
    perms="$(stat -c %A -- "$path" 2>/dev/null || printf '')"
    [[ -n "$perms" ]] || return 1
    # 位置 5,6,7 为 group 的 rwx；8,9,10 为 other 的 rwx
    [[ "${perms:4:3}" == *r* || "${perms:7:3}" == *r* ]]
}

# ----------------------------------------------------------------------------
# 2. 配置加载（ops.conf）
# ----------------------------------------------------------------------------
#
# 配置优先级：
#   1) 命令行 --conf <路径>
#   2) 环境变量 OPS_CONF
#   3) <仓库根>/ops.conf
#   4) /etc/knowtrace/ops.conf
#
# 解析规则刻意做得很保守：只认 KEY=VALUE，不执行任何内容，不对右侧做变量展开，
# 因此 ops.conf 里可以安全地写字面量口令（虽然原则上不应该写）。

opts_conf_paths_checked=()
ops_conf_file=""
opts_conf_loaded=0
declare -A ops_conf_values=()

ops_load_conf() {
    local candidate=""
    opts_conf_paths_checked=()

    if [[ -n "${OPS_CONF:-}" ]]; then
        opts_conf_paths_checked+=("$OPS_CONF")
        if [[ -f "$OPS_CONF" ]]; then
            candidate="$OPS_CONF"
        else
            ops_die "--conf/OPS_CONF 指定的配置文件不存在: $OPS_CONF"
        fi
    else
        for candidate in "$OPS_ROOT/ops.conf" "/etc/knowtrace/ops.conf"; do
            opts_conf_paths_checked+=("$candidate")
            [[ -f "$candidate" ]] && break
        done
        [[ -f "$candidate" ]] || candidate=""
    fi

    ops_conf_file="$candidate"
    (( ++opts_conf_loaded ))

    [[ -n "$ops_conf_file" ]] || return 0

    local raw_line line key value
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        line="${raw_line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"   # 去左空白
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        [[ "$line" == *"="* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"       # 去右空白
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        # 去掉成对引号
        if (( ${#value} >= 2 )) && [[ "${value:0:1}" == "${value: -1}" ]] \
            && [[ "${value:0:1}" == '"' || "${value:0:1}" == "'" ]]; then
            value="${value:1:${#value}-2}"
        fi
        ops_conf_values["$key"]="$value"
    done <"$ops_conf_file"

    return 0
}

# 读取单个配置项；未设置时返回兜底值
ops_conf_get() {
    local key="$1" fallback="${2-}"
    if [[ -n "${ops_conf_values[$key]+set}" && -n "${ops_conf_values[$key]}" ]]; then
        printf '%s' "${ops_conf_values[$key]}"
    else
        printf '%s' "$fallback"
    fi
}

# 读取以空白分隔的列表，每项一行输出
ops_conf_list() {
    local key="$1" fallback="${2-}" raw item
    raw="$(ops_conf_get "$key" "$fallback")"
    # 这里故意不加引号，按空白拆分是预期行为
    # shellcheck disable=SC2086
    for item in $raw; do
        [[ -n "$item" ]] && printf '%s\n' "$item"
    done
    return 0
}

# ----------------------------------------------------------------------------
# 容器名解析 —— 不要写死前缀
# ----------------------------------------------------------------------------
# 历史教训（2026-10-03）：这些脚本原先用 `grep -Eq "^knowtrace-${service}-[0-9]+$"`
# 判断容器在不在。仓库更名为 KnowTrace-Workflow 后，容器名变成
# `knowtrace-workflow-app-1`，正则匹配不上 —— 于是**巡检把在跑的容器报成"缺少"**，
# 得出一份看起来煞有介事的 FAIL 报告。这正是本仓库最贵的那类故障：
# **检查器悄悄失效，而不是被检查的东西坏了**。
#
# 现在改为**按服务名问 compose 要容器**（`docker compose ps -q <service>`），
# 与项目名/容器名解耦：改名、换项目名、多项目并存都不受影响。
#
# 仅在 compose 不可用时，才回退到按前缀匹配容器名（前缀可用
# CONTAINER_PREFIX 配置，默认推导为「部署目录名的小写」，即 /opt/knowtrace-workflow
# → knowtrace-workflow-）。

# 输出某服务的容器名（优先 compose，其次按 -<service>-<n>$ 匹配）；找不到则返回 1
ops_container_for_service() {
    local service="$1" cid name
    ops_have_cmd docker || return 1

    # ① 问 compose。**必须把三个 overlay 都带上** —— 监控与日志服务
    #    （prometheus/grafana/alertmanager/loki/alloy）定义在 compose.observability.yaml，
    #    只带 compose.yaml 会得到 "no such service"。
    #    2026-10-03 实测踩到过这一条：修完前缀问题后 alertmanager 仍报"未运行"，
    #    就是因为这里少了 overlay。
    if [[ -f "${PROJECT_DIR:-}/compose.yaml" ]]; then
        local -a compose_files=(-f "${PROJECT_DIR}/compose.yaml")
        local overlay
        for overlay in compose.production.yaml compose.observability.yaml; do
            [[ -f "${PROJECT_DIR}/${overlay}" ]] && compose_files+=(-f "${PROJECT_DIR}/${overlay}")
        done
        cid="$(docker compose --project-directory "${PROJECT_DIR:-.}" "${compose_files[@]}" \
                ps -q "$service" 2>/dev/null | head -n1)"
        if [[ -n "$cid" ]]; then
            name="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##')"
            [[ -n "$name" ]] && { printf '%s' "$name"; return 0; }
        fi
    fi

    # ② 回退：**不依赖任何前缀**，直接按 `-<service>-<数字>` 收尾匹配。
    #    为什么不用"配置一个前缀"：前缀要从 compose 项目名来，而项目名不一定等于
    #    部署目录名（本机是 /opt/knowtrace 但项目名是 knowtrace-workflow）。
    #    逼着运维去配一个前缀＝把同一个坑换个地方埋。锚定 `-<service>-<n>$` 既准确
    #    又与前缀无关；`auth` 不会误配 `auth-postgres`（那后面跟的是字母不是数字）。
    name="$(docker ps --format '{{.Names}}' 2>/dev/null \
            | grep -E -- "-${service}-[0-9]+$" | head -n1)"
    [[ -n "$name" ]] && { printf '%s' "$name"; return 0; }
    return 1
}

# 所有运行中的容器名，一行一个
ops_running_container_names() {
    docker ps --format '{{.Names}}' 2>/dev/null || printf ''
}

# 判断某服务是否有容器在跑（0=在跑）
ops_service_running() {
    ops_container_for_service "$1" >/dev/null 2>&1
}

# 读取整数配置，非法值回退到兜底值
ops_conf_int() {
    local key="$1" fallback="$2" value
    value="$(ops_conf_get "$key" "")"
    if [[ "$value" =~ ^-?[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$fallback"
    fi
}

# ----------------------------------------------------------------------------
# 3. 参数解析
# ----------------------------------------------------------------------------

# 通用参数：--conf / --json / --no-json / --quiet / --no-color
# 其余参数保留在 OPS_REMAINING_ARGS 中，由调用脚本自己处理。
ops_parse_common_args() {
    OPS_REMAINING_ARGS=()
    while (( $# )); do
        case "$1" in
            --conf)        ops_require_value "$@"; OPS_CONF="$2"; shift 2 ;;
            --conf=*)      OPS_CONF="${1#*=}"; shift ;;
            --json)        ops_require_value "$@"; OPS_JSON_OUT="$2"; shift 2 ;;
            --json=*)      OPS_JSON_OUT="${1#*=}"; shift ;;
            --no-json)     OPS_JSON_DISABLED=1; shift ;;
            --markdown)    ops_require_value "$@"; OPS_MARKDOWN_OUT="$2"; shift 2 ;;
            --markdown=*)  OPS_MARKDOWN_OUT="${1#*=}"; shift ;;
            --quiet|-q)    OPS_QUIET=1; shift ;;
            --no-color)    OPS_NO_COLOR=1; C_RESET=""; C_OK=""; C_WARN=""; C_FAIL=""; C_INFO=""; C_TITLE=""; shift ;;
            --help|-h)     OPS_SHOW_HELP=1; shift ;;
            --)            shift; while (( $# )); do OPS_REMAINING_ARGS+=("$1"); shift; done; break ;;
            *)             OPS_REMAINING_ARGS+=("$1"); shift ;;
        esac
    done
    return 0
}

# ----------------------------------------------------------------------------
# 4. 结果记录
# ----------------------------------------------------------------------------

declare -a ops_finding_level=()
declare -a ops_finding_check=()
declare -a ops_finding_message=()

ops_level_tag() {
    case "$1" in
        OK)   printf '%s' "${C_OK}[ OK ]${C_RESET}" ;;
        WARN) printf '%s' "${C_WARN}[WARN]${C_RESET}" ;;
        FAIL) printf '%s' "${C_FAIL}[FAIL]${C_RESET}" ;;
        INFO) printf '%s' "${C_INFO}[INFO]${C_RESET}" ;;
        *)    printf '[????]' ;;
    esac
}

# ops_record <LEVEL> <检查项ID> <说明>
ops_record() {
    local level="$1" check="$2" message="${3-}"
    ops_finding_level+=("$level")
    ops_finding_check+=("$check")
    ops_finding_message+=("$message")

    # quiet 只保留「需要人看的」级别：WARN 与 FAIL。
    # 不要把这里改成「只放行 FAIL」—— 这个模式的用途是「把输出直接当告警邮件正文」，
    # 只放行 FAIL 会让一次 WARN=3 的运行在邮件里什么都不显示，
    # 而那 3 条 WARN 恰恰是收件人要看的东西。OK/INFO 才是该被压掉的噪声。
    [[ "$OPS_QUIET" == "1" && "$level" != "WARN" && "$level" != "FAIL" ]] && return 0

    local padded
    padded="$(printf '%-30s' "$check")"
    if [[ -n "$message" ]]; then
        printf '%s %s %s\n' "$(ops_level_tag "$level")" "$padded" "$message"
    else
        printf '%s %s\n' "$(ops_level_tag "$level")" "$padded"
    fi
    return 0
}

ops_ok()   { ops_record OK   "$1" "${2-}"; }
ops_warn() { ops_record WARN "$1" "${2-}"; }
ops_fail() { ops_record FAIL "$1" "${2-}"; }
ops_info() { ops_record INFO "$1" "${2-}"; }

# 事实行：只打印，不计入结论
ops_fact() {
    [[ "$OPS_QUIET" == "1" ]] && return 0
    printf '       %s\n' "${1-}"
    return 0
}

# 原样输出命令输出（缩进 6 空格），用于保留现场证据
ops_indent() {
    [[ "$OPS_QUIET" == "1" ]] && return 0
    sed 's/^/      /' || true
    return 0
}

ops_section() {
    [[ "$OPS_QUIET" == "1" ]] && return 0
    printf '\n%s\n' "${C_TITLE}============================================================================${C_RESET}"
    printf '%s%s%s\n' "$C_TITLE" "$1" "$C_RESET"
    printf '%s\n' "${C_TITLE}============================================================================${C_RESET}"
    return 0
}

# ----------------------------------------------------------------------------
# 5. 结论汇总与输出
# ----------------------------------------------------------------------------

ops_count_level() {
    local want="$1" i n=0
    for (( i=0; i<${#ops_finding_level[@]}; i++ )); do
        [[ "${ops_finding_level[$i]}" == "$want" ]] && (( n += 1 ))
    done
    printf '%s' "$n"
}

ops_worst_level() {
    (( $(ops_count_level FAIL) > 0 )) && { printf 'FAIL'; return 0; }
    (( $(ops_count_level WARN) > 0 )) && { printf 'WARN'; return 0; }
    printf 'OK'
}

ops_exit_code() {
    case "$(ops_worst_level)" in
        FAIL) printf '2' ;;
        WARN) printf '1' ;;
        *)    printf '0' ;;
    esac
}

# ops_write_json <脚本名> <标题>
ops_write_json() {
    local script="$1" title="${2-}" out="$OPS_JSON_OUT"

    if [[ "$OPS_JSON_DISABLED" == "1" ]]; then
        return 0
    fi
    if [[ -z "$out" ]]; then
        # 没给 --json 时的兜底目录，优先级：
        #   1. 脚本自己解析出的 REPORTS_DIR（通常来自 ops.conf）
        #   2. 环境变量 OPS_REPORTS_DIR
        #   3. 工具包内的 reports/
        # 没有第 1 条时，交互式执行会把报告写到 /opt/knowtrace-ops/reports/，
        # 而 systemd 单元用 --json 显式指向 /var/lib/knowtrace/reports/ —— 同一个
        # 目录下就出现两份互不可见的报告，weekly 的「每日巡检有没有在产出」和
        # ops-report.py 的汇总都会看漏。优先跟随 ops.conf 消除这个分裂。
        local default_dir="${REPORTS_DIR:-${OPS_REPORTS_DIR:-$OPS_ROOT/reports}}"
        out="${default_dir%/}/${script}-$(date -u '+%Y%m%dT%H%M%SZ').json"
    elif [[ -d "$out" ]]; then
        # 允许 --json 直接传目录（挂 systemd 时最自然的写法）：
        # 目录 => 补上带时间戳的文件名，与 Python 侧 _prepare_output 行为一致。
        out="${out%/}/${script}-$(date -u '+%Y%m%dT%H%M%SZ').json"
    fi

    local out_dir; out_dir="$(dirname -- "$out")"
    mkdir -p -- "$out_dir" 2>/dev/null || { ops_warn "report-dir" "无法创建报告目录: $out_dir"; return 0; }

    local tmp; tmp="$(mktemp "${out}.XXXXXX" 2>/dev/null)" || return 0

    local i last total
    total=${#ops_finding_level[@]}
    last=$(( total - 1 ))

    {
        printf '{\n'
        printf '  "schema": "knowtrace-ops/1",\n'
        printf '  "script": "%s",\n' "$(ops_json_escape "$script")"
        printf '  "title": "%s",\n' "$(ops_json_escape "$title")"
        printf '  "hostname": "%s",\n' "$(ops_json_escape "$OPS_HOSTNAME")"
        printf '  "generated_at": "%s",\n' "$OPS_RUN_UTC"
        printf '  "worst": "%s",\n' "$(ops_worst_level)"
        printf '  "exit_code": %s,\n' "$(ops_exit_code)"
        printf '  "counts": {"fail": %s, "warn": %s, "ok": %s, "info": %s},\n' \
            "$(ops_count_level FAIL)" "$(ops_count_level WARN)" \
            "$(ops_count_level OK)" "$(ops_count_level INFO)"
        printf '  "config_file": "%s",\n' "$(ops_json_escape "${ops_conf_file:-none}")"
        printf '  "findings": [\n'
        for (( i=0; i<total; i++ )); do
            printf '    {"level": "%s", "check": "%s", "message": "%s"}%s\n' \
                "$(ops_json_escape "${ops_finding_level[$i]}")" \
                "$(ops_json_escape "${ops_finding_check[$i]}")" \
                "$(ops_json_escape "${ops_finding_message[$i]}")" \
                "$( (( i < last )) && printf ',' )"
        done
        printf '  ]\n'
        printf '}\n'
    } >"$tmp" 2>/dev/null

    if mv -f -- "$tmp" "$out" 2>/dev/null; then
        ops_json_written="$out"
    else
        rm -f -- "$tmp" 2>/dev/null || true
        ops_warn "report-write" "无法写入 JSON 报告: $out"
    fi
    return 0
}

# ops_write_markdown <脚本名> <标题> [输出路径]
# 把本次记录写成 Markdown（与 ops_write_json 的 findings 一一对应）。
# 目的是让「巡检快照」和「运维记录」能用同一份结论，不用手工誊抄。
ops_write_markdown() {
    local script="$1" title="${2-}" out="${3:-${OPS_MARKDOWN_OUT:-}}"
    [[ -n "$out" ]] || return 0
    if [[ -d "$out" ]]; then
        out="${out%/}/${script}-$(date -u '+%Y%m%dT%H%M%SZ').md"
    fi

    local out_dir; out_dir="$(dirname -- "$out")"
    mkdir -p -- "$out_dir" 2>/dev/null || { ops_warn "report-dir" "无法创建报告目录: $out_dir"; return 0; }

    local tmp; tmp="$(mktemp "${out}.XXXXXX" 2>/dev/null)" || return 0

    # 表格里的竖线会破坏 Markdown 结构，必须转义
    _ops_md_cell() { printf '%s' "${1-}" | sed 's/|/\\|/g'; }

    {
        printf '# %s\n\n' "$title"
        printf '> 由 `%s` 于 %s 自动生成。机器判定的结果可直接引用；\n' "$script" "$OPS_RUN_UTC"
        printf '> 标注为 INFO 的是事实记录，不是结论，不能当作「已验证」。\n\n'
        printf -- '- 主机：%s\n' "$OPS_HOSTNAME"
        printf -- '- 执行用户：%s\n' "$OPS_USER_NAME"
        printf -- '- 执行时间(UTC)：%s\n' "$OPS_RUN_UTC"
        printf -- '- 配置文件：%s\n' "${ops_conf_file:-未加载}"
        printf -- '- 结论：**%s**\n' "$(ops_worst_level)"
        printf -- '- 明细：FAIL=%s WARN=%s OK=%s INFO=%s\n\n' \
            "$(ops_count_level FAIL)" "$(ops_count_level WARN)" \
            "$(ops_count_level OK)" "$(ops_count_level INFO)"

        printf '## 检查结果\n\n'
        printf '| 级别 | 检查项 | 说明 |\n| --- | --- | --- |\n'
        local i
        for (( i=0; i<${#ops_finding_level[@]}; i++ )); do
            printf '| %s | `%s` | %s |\n' \
                "${ops_finding_level[$i]}" \
                "$(_ops_md_cell "${ops_finding_check[$i]}")" \
                "$(_ops_md_cell "${ops_finding_message[$i]}")"
        done
        printf '\n'

        if (( $(ops_count_level FAIL) > 0 )); then
            printf '## 需要优先处理的 FAIL\n\n'
            for (( i=0; i<${#ops_finding_level[@]}; i++ )); do
                [[ "${ops_finding_level[$i]}" == "FAIL" ]] || continue
                printf -- '- `%s`: %s\n' "${ops_finding_check[$i]}" "${ops_finding_message[$i]}"
            done
            printf '\n'
        fi

        printf '## 记录边界\n\n'
        printf -- '- 本次结论只覆盖执行时刻，不能作为持续可用性的证明。\n'
        printf -- '- 只有实际验证通过的内容才记 OK；推断一律记 INFO。\n'
        printf -- '- 报告不含密码、Token、Cookie 或 .env 明细。\n'
    } >"$tmp" 2>/dev/null

    unset -f _ops_md_cell 2>/dev/null || true

    if mv -f -- "$tmp" "$out" 2>/dev/null; then
        ops_markdown_written="$out"
    else
        rm -f -- "$tmp" 2>/dev/null || true
        ops_warn "report-write" "无法写入 Markdown 报告: $out"
    fi
    return 0
}

# ops_finish <脚本名> <标题>
# 打印结论、写 JSON 与 Markdown，并按约定返回退出码。
# 环境变量 OPS_EXIT_ZERO=1 可强制退出码为 0（用于不希望标记失败的定时任务）。
ops_finish() {
    local script="$1" title="${2-}"
    ops_json_written=""
    ops_markdown_written=""

    ops_section "巡检结论 —— $title"
    printf '脚本      : %s\n' "$script"
    printf '主机      : %s\n' "$OPS_HOSTNAME"
    printf '执行用户  : %s\n' "$OPS_USER_NAME"
    printf '执行时间  : %s\n' "$OPS_RUN_UTC"
    printf '配置文件  : %s\n' "${ops_conf_file:-未加载（使用内置默认值）}"
    printf '结论      : %s\n' "$(ops_worst_level)"
    printf '明细      : FAIL=%s WARN=%s OK=%s INFO=%s\n' \
        "$(ops_count_level FAIL)" "$(ops_count_level WARN)" \
        "$(ops_count_level OK)" "$(ops_count_level INFO)"

    if (( $(ops_count_level FAIL) > 0 )); then
        printf '\n需要优先处理的 FAIL 项：\n'
        local i
        for (( i=0; i<${#ops_finding_level[@]}; i++ )); do
            [[ "${ops_finding_level[$i]}" == "FAIL" ]] || continue
            printf '  - %s: %s\n' "${ops_finding_check[$i]}" "${ops_finding_message[$i]}"
        done
    fi

    ops_write_json "$script" "$title"
    ops_write_markdown "$script" "$title"

    if [[ -n "$ops_json_written" ]]; then
        printf 'JSON 报告 : %s\n' "$ops_json_written"
    fi
    if [[ -n "$ops_markdown_written" ]]; then
        printf 'Markdown 报告 : %s\n' "$ops_markdown_written"
    fi

    printf '\n%s\n' "本脚本只做只读检查，不修改任何服务、容器、配置或数据。"
    printf '%s\n' "本脚本的结论只覆盖本次执行时刻，不能作为持续可用性的证明。"

    local code; code="$(ops_exit_code)"
    if [[ "${OPS_EXIT_ZERO:-0}" == "1" ]]; then
        code=0
    fi
    return "$code"
}
