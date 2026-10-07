#!/usr/bin/env bash
# ============================================================================
# server_health_check.sh —— 单机轻量运维巡检（自包含单文件）
# ============================================================================
#
# 定位：一台公网 Ubuntu VPS（Caddy 反代 → 后端 Web 服务，DuckDNS 动态解析）
#       的「一次跑完、一眼看懂」巡检。纯原生 Bash + coreutils，不依赖任何
#       第三方工具，也不 source 本仓库的 lib/。
#
# 与 scripts/ops/ 下日/周/月巡检的分工（**别把两者搞混**）：
#   * daily-ops.sh / weekly-check.sh 是**体系化**巡检：依赖 lib/ops-common.sh，
#     产出 JSON/Markdown 报告并接告警链路 —— 那是常态化机制。
#   * 本脚本是**自包含单文件**：拷到一台没部署过工具包的机器上也能直接跑，
#     适合「救援环境」「对照排查」「新机器摸底」。它不写报告目录，
#     只追加一份人类可读日志。
#   两者判据口径**刻意保持一致**（四级结论 + 四档退出码），所以同一台机器上
#   两边的结论可以直接对照，不会出现「一个说 OK 一个说 FAIL」的口径分裂。
#
# 只读保证
#   不修改任何配置、不重启任何服务、不写除巡检日志外的任何文件。
#   唯一的写入是 --log 指定的日志（默认 /var/log/health_check.log）。
#
# 退出码（与 scripts/ops 一致，便于接入 systemd / cron）
#   0 = 未发现异常   1 = 存在 WARN   2 = 存在 FAIL   3 = 脚本自身错误
#
# 用法
#   sudo ./server_health_check.sh                 # 完整巡检
#   sudo ./server_health_check.sh --quiet         # 只打印 WARN/FAIL（适合当邮件正文）
#   sudo ./server_health_check.sh --self-test     # 负向证伪自检（注入故障，断言必定报警）
#   sudo ./server_health_check.sh --no-log        # 不写日志（纯控制台）
#   sudo ./server_health_check.sh --json r.json   # 额外落一份机器可读报告
#
# 配套 logrotate 配置见文件末尾的注释块（也在 --help 之外单独可查）。
# ============================================================================

set -uo pipefail
# 说明：这里**故意不加 `set -e`**。巡检脚本要在「某条命令失败」时继续往下跑
# 并把它记成一条结论；`-e` 会让第一个非零退出（例如 grep 没匹配到）直接终止
# 整个巡检，于是「没发现问题」和「脚本半路死了」在退出码上长得一样。
# 每处可能失败的命令都显式 `|| true` 或做返回值判断。
export LC_ALL=C
# LC_ALL=C 是为了让 sort/awk 的排序与数字解析与语言环境无关：
# 在 zh_CN.UTF-8 下 sort 的排序规则不同，且某些 locale 下 awk 的小数点会变成逗号，
# 导致 printf "%.0f" 输出 "1,5" 这种解析不了的值。巡检脚本必须确定性。

HC_VERSION="1.0.0"
HC_SCRIPT_NAME="server_health_check"

# ----------------------------------------------------------------------------
# 0. 参数与运行上下文
# ----------------------------------------------------------------------------
HC_QUIET=0
HC_NO_COLOR=0
HC_NO_LOG=0
HC_NO_REFERENCE=0
HC_SELF_TEST=0
HC_SHOW_HELP=0
HC_JSON_OUT=""
HC_LOG_FILE="${HC_LOG_FILE:-/var/log/health_check.log}"
HC_CONF_FILE=""

usage() {
    cat <<'EOF'
server_health_check.sh —— 单机轻量运维巡检（自包含）

用法:
  sudo ./server_health_check.sh [选项]

选项:
  --log <文件>      巡检日志路径（默认 /var/log/health_check.log）
  --no-log          不写日志，只打印到控制台
  --json <文件>     额外写一份机器可读的 JSON 报告
  --conf <文件>     读取 ops.conf（只读，用于覆盖阈值/路径/单元名）
  --quiet, -q       只输出 WARN/FAIL
  --no-color        关闭彩色输出（也认环境变量 NO_COLOR）
  --no-reference    不打印末尾的命令参数详解
  --self-test       负向证伪自检：注入故障，断言判据必定报警
  --help, -h        显示本帮助

检查项:
  1. 内存与 Swap 水位 + OOM 历史触发记录
  2. 根分区磁盘使用率与 inode 余量
  3. 异常对外连接（ESTABLISHED）与非标监听端口
  4. 最近 1 小时 SSH 爆破失败 Top 5 来源 IP（/var/log/auth.log）
  5. Caddy 与后端核心服务状态（含崩溃重启检测）

退出码:
  0 未发现异常   1 存在 WARN   2 存在 FAIL   3 脚本自身错误
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --log)          [[ -n "${2-}" ]] || { printf '选项 --log 缺少取值\n' >&2; exit 3; }; HC_LOG_FILE="$2"; shift 2 ;;
        --json)         [[ -n "${2-}" ]] || { printf '选项 --json 缺少取值\n' >&2; exit 3; }; HC_JSON_OUT="$2"; shift 2 ;;
        --conf)         [[ -n "${2-}" ]] || { printf '选项 --conf 缺少取值\n' >&2; exit 3; }; HC_CONF_FILE="$2"; shift 2 ;;
        --no-log)       HC_NO_LOG=1; shift ;;
        --quiet|-q)     HC_QUIET=1; shift ;;
        --no-color)     HC_NO_COLOR=1; shift ;;
        --no-reference) HC_NO_REFERENCE=1; shift ;;
        --self-test)    HC_SELF_TEST=1; shift ;;
        --help|-h)      HC_SHOW_HELP=1; shift ;;
        --version)      printf '%s %s\n' "$HC_SCRIPT_NAME" "$HC_VERSION"; exit 0 ;;
        *)              printf '未知参数: %s\n\n' "$1" >&2; usage >&2; exit 3 ;;
    esac
done

[[ "$HC_SHOW_HELP" == "1" ]] && { usage; exit 0; }

HC_RUN_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
HC_RUN_EPOCH="$(date -u '+%s')"
HC_HOSTNAME="$(hostname 2>/dev/null || printf 'unknown')"
HC_IS_ROOT=0
[[ "${EUID:-$(id -u 2>/dev/null || printf '1')}" == "0" ]] && HC_IS_ROOT=1

# 颜色：只在真终端且未显式关闭时启用。
# 判据是 `[[ -t 1 ]]`（stdout 是终端），因为脚本常被重定向进文件或管道给 mail，
# 那种情况下 ANSI 转义序列会变成乱码。NO_COLOR 是社区约定（no-color.org）。
if [[ "$HC_NO_COLOR" != "0" ]] || [[ ! -t 1 ]] || [[ -n "${NO_COLOR:-}" ]]; then
    C_RESET=""; C_OK=""; C_WARN=""; C_FAIL=""; C_INFO=""; C_TITLE=""
else
    C_RESET=$'\033[0m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
    C_FAIL=$'\033[31m'; C_INFO=$'\033[36m'; C_TITLE=$'\033[1m'
fi

# ----------------------------------------------------------------------------
# 1. 只读的 ops.conf 读取器
# ----------------------------------------------------------------------------
# 只认 KEY=VALUE，不 source（source 会执行文件内容 = 拿运维脚本当代码执行）。
# 与 lib/ops-common.sh 的解析规则一致：去注释、去成对引号、不展开变量。
declare -A hc_conf_values=()
hc_conf_file=""
hc_load_conf() {
    local candidate="" line key value
    if [[ -n "$HC_CONF_FILE" ]]; then
        [[ -f "$HC_CONF_FILE" ]] || { printf '指定的配置文件不存在: %s\n' "$HC_CONF_FILE" >&2; exit 3; }
        candidate="$HC_CONF_FILE"
    else
        for candidate in "${HC_OPS_CONF:-}" "$(dirname -- "${BASH_SOURCE[0]}")/../ops.conf" /etc/knowtrace/ops.conf; do
            [[ -n "$candidate" && -f "$candidate" ]] && break
            candidate=""
        done
    fi
    hc_conf_file="$candidate"
    [[ -n "$candidate" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "${line:0:1}" == "#" || "$line" != *"="* ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if (( ${#value} >= 2 )) && [[ "${value:0:1}" == "${value: -1}" ]] \
            && [[ "${value:0:1}" == '"' || "${value:0:1}" == "'" ]]; then
            value="${value:1:${#value}-2}"
        fi
        hc_conf_values["$key"]="$value"
    done < "$candidate"
    return 0
}
# 取值优先级（与 scripts/ops 的手册一致）：
#   环境变量 > ops.conf 文件 > 内置默认值
# 为什么要读环境变量：一是让 cron / systemd 能不改文件就覆盖阈值与路径
#   （Environment=HC_AUTH_LOG=... 比改 /etc 下的配置轻得多）；
#   二是 --self-test 靠它注入假数据源 —— 若不读环境变量，
#   自检里的 HC_AUTH_LOG 等设置会被静默忽略，于是自检「看起来在测」，
#   实际测的是真机的 /var/log/auth.log（不存在 → 静默降级成 INFO），
#   判据于是永远不会报警。这正是本项目最贵的那类故障：检查器悄悄失效。
#
# ⚠️ 「显式设为空」必须算**已设置**，不能回落到配置文件（2026-10-07 真机踩到）：
#   原先判据是 `-n "${!key}"`，它把「没设」和「设成了空串」当成同一件事。
#   于是 `SYSTEMD_FAILED_ALLOWLIST=`（本意是「没有白名单」）会**静默回落**到
#   /etc/knowtrace/ops.conf 里的 `repass.service` —— 用户明确要求「清空白名单」，
#   脚本却照旧用白名单，且**毫无提示**。这与上面那条是同一族缺陷。
#   现在改为只判 `${!key+set}`（设没设），空串是一个**有意义的取值**，照用。
hc_conf_get() {
    local key="$1" fallback="${2-}"
    if [[ -n "${!key+set}" ]]; then
        printf '%s' "${!key}"
    elif [[ -n "${hc_conf_values[$key]+set}" ]]; then
        printf '%s' "${hc_conf_values[$key]}"
    else
        printf '%s' "$fallback"
    fi
}
hc_conf_int() {
    local v; v="$(hc_conf_get "$1" "")"
    if [[ "$v" =~ ^[0-9]+$ ]]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

# ----------------------------------------------------------------------------
# 2. 结论分级与输出
# ----------------------------------------------------------------------------
# 四级结论，与 scripts/ops 完全一致：
#   OK   已确认符合预期（必须实际验证过，不是「没报错」）
#   WARN 需要关注，但尚未影响可用性
#   FAIL 已确认异常，需要处理
#   INFO 事实记录，不构成判断（**包括所有「无法验证」的情况**）
# INFO 这一级是刻意存在的：拿不到数据时既不报 OK（假装验证过）也不报 FAIL
# （把「我读不到」说成「它坏了」），而是明确记成「没验证」。
hc_level=(); hc_check=(); hc_message=()
hc_count_fail=0; hc_count_warn=0; hc_count_ok=0; hc_count_info=0

hc_log_open() {
    [[ "$HC_NO_LOG" == "1" ]] && return 0
    local dir; dir="$(dirname -- "$HC_LOG_FILE")"
    if [[ ! -d "$dir" ]]; then
        mkdir -p -- "$dir" 2>/dev/null || { printf '无法创建日志目录 %s，已改为不写日志\n' "$dir" >&2; HC_NO_LOG=1; return 0; }
    fi
    if ! : >> "$HC_LOG_FILE" 2>/dev/null; then
        printf '无法写入日志 %s，已改为不写日志\n' "$HC_LOG_FILE" >&2
        HC_NO_LOG=1
    fi
    return 0
}

# 追加一行到日志（始终不带颜色、带 UTC 时间戳）
hc_log_line() {
    [[ "$HC_NO_LOG" == "1" ]] && return 0
    printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$HC_LOG_FILE" 2>/dev/null || true
    return 0
}

hc_record() {
    local level="$1" check="$2" msg="${3-}"
    hc_level+=("$level"); hc_check+=("$check"); hc_message+=("$msg")
    case "$level" in
        FAIL) hc_count_fail=$(( hc_count_fail + 1 )) ;;
        WARN) hc_count_warn=$(( hc_count_warn + 1 )) ;;
        OK)   hc_count_ok=$(( hc_count_ok + 1 )) ;;
        INFO) hc_count_info=$(( hc_count_info + 1 )) ;;
    esac
    local color=""
    case "$level" in
        FAIL) color="$C_FAIL" ;; WARN) color="$C_WARN" ;;
        OK)   color="$C_OK"   ;; INFO) color="$C_INFO" ;;
    esac
    # --quiet 只压 OK/INFO：这两个是「一切正常」的噪音，
    # 保留 WARN/FAIL 才让 --quiet 的输出能直接当邮件正文用。
    # （教训来自 scripts/ops：曾有一版 --quiet 把 WARN 也压掉了，
    #   于是「静默」把该看的静默了。）
    if [[ "$HC_QUIET" != "1" || "$level" == "FAIL" || "$level" == "WARN" ]]; then
        printf '  %s%-4s%s %-26s %s\n' "$color" "$level" "$C_RESET" "$check" "$msg"
    fi
    hc_log_line "$level $check $msg"
    return 0
}
hc_ok()   { hc_record OK   "$1" "${2-}"; }
hc_warn() { hc_record WARN "$1" "${2-}"; }
hc_fail() { hc_record FAIL "$1" "${2-}"; }
hc_info() { hc_record INFO "$1" "${2-}"; }

# 事实行：只打印，不计入结论（用于贴原始证据）
hc_fact() {
    [[ "$HC_QUIET" == "1" ]] && return 0
    printf '         %s\n' "${1-}"
    return 0
}
# 原样输出命令输出（缩进），保留现场证据
hc_indent() { [[ "$HC_QUIET" == "1" ]] && return 0; sed 's/^/         /' || true; return 0; }

hc_section() {
    hc_log_line "=== $1 ==="
    [[ "$HC_QUIET" == "1" ]] && return 0
    printf '\n%s%s%s\n' "$C_TITLE" "────────────────────────────────────────────────────────────────────────────" "$C_RESET"
    printf '%s%s%s\n' "$C_TITLE" "$1" "$C_RESET"
    return 0
}

hc_worst_level() {
    if (( hc_count_fail > 0 )); then printf 'FAIL'; return 0; fi
    if (( hc_count_warn > 0 )); then printf 'WARN'; return 0; fi
    printf 'OK'
}
hc_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 计数：读 stdin，输出**一个干净的整数**。
#
# ⚠️ 为什么不能写 `grep -c X || printf '0'`（2026-10-07 在真机踩到）：
#   `grep -c` 在「无匹配」时会 **打印 0 并退出 1**。外面再补一个 `|| printf '0'`，
#   命令替换里就得到 "0\n0" —— 赋值给变量后是**含换行的两行字符串**。后果是：
#     · `(( failed_pw >= 300 ))` 报 `syntax error in expression (error token is "0")`
#     · 而且**每处调用都报**，一条只读巡检刷出满屏噪声
#     · 更糟：这个变量还被拼进结论字符串，于是报告里出现「Failed password 0↵0 次」
#   正确做法是**让 grep 自己兜底**（它本来就输出 0），不要在外面再补一个 0；
#   外层只做「结果不像数字才归零」的防御。
hc_count() {
    local n
    n="$(grep -c "$@" 2>/dev/null)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# ----------------------------------------------------------------------------
# 3. 配置与阈值（ops.conf 可覆盖，缺省值贴合本项目实况）
# ----------------------------------------------------------------------------
hc_load_conf

THRESH_MEM_WARN="$(hc_conf_int THRESHOLD_MEM_WARN 15)"      # MemAvailable 低于此百分比 → WARN
THRESH_MEM_FAIL="$(hc_conf_int THRESHOLD_MEM_FAIL 8)"       # 低于此百分比 → FAIL
THRESH_SWAP_WARN="$(hc_conf_int THRESHOLD_SWAP_WARN 50)"
THRESH_SWAP_FAIL="$(hc_conf_int THRESHOLD_SWAP_FAIL 80)"
THRESH_DISK_WARN="$(hc_conf_int THRESHOLD_DISK_WARN 80)"
THRESH_DISK_FAIL="$(hc_conf_int THRESHOLD_DISK_FAIL 90)"
THRESH_INODE_WARN="$(hc_conf_int THRESHOLD_INODE_WARN 80)"
THRESH_INODE_FAIL="$(hc_conf_int THRESHOLD_INODE_FAIL 90)"
THRESH_BF_WARN="$(hc_conf_int HC_THRESHOLD_BF_WARN 50)"
THRESH_BF_FAIL="$(hc_conf_int HC_THRESHOLD_BF_FAIL 200)"

BF_WINDOW_HOURS="$(hc_conf_int HC_BF_WINDOW_HOURS 1)"
# auth.log 的位置：Debian/Ubuntu 在 /var/log/auth.log（由 rsyslog 落盘）；
# 若没有该文件则退回 journalctl（见 §4 的分支）。
AUTH_LOG="$(hc_conf_get HC_AUTH_LOG /var/log/auth.log)"
MEMINFO_FILE="$(hc_conf_get HC_MEMINFO_FILE /proc/meminfo)"

# 关键服务：systemd 单元。这里刻意把「单元」和「容器」分开列：
# 本项目 Caddy 是宿主 systemd 单元，后端核心服务是 docker 容器。
# 只查 systemd 会把容器全漏掉。
SYSTEMD_UNITS="$(hc_conf_get HC_SYSTEMD_UNITS 'caddy nginx ssh docker')"
# 核心单元：缺失/非 active = FAIL。其余（可选组件）= WARN。
CORE_UNITS="$(hc_conf_get HC_CORE_UNITS 'caddy')"
# 刻意保留的 failed 单元（默认空 = 任何 failed 都算问题）。
# 复用与 daily/weekly 巡检**同一个配置键** SYSTEMD_FAILED_ALLOWLIST，
# 免得同一台机器在不同脚本里得出不同结论 —— 本机该键的值是 repass.service
# （INC-S2-003：云厂商控制台救援链路，刻意保留、勿 mask）。
SYSTEMD_FAILED_ALLOWLIST="$(hc_conf_get SYSTEMD_FAILED_ALLOWLIST '')"
# 后端核心容器（compose 服务名）。留空则跳过容器检查。
CORE_CONTAINERS="$(hc_conf_get HC_CORE_CONTAINERS "$(hc_conf_get EXPECTED_SERVICES '')")"
PROJECT_DIR="$(hc_conf_get PROJECT_DIR /opt/knowtrace)"

# 端口口径
# 标准端口 = IANA 常见服务端口，出现这些不算「非标」。
HC_STANDARD_PORTS="$(hc_conf_get HC_STANDARD_PORTS '22 53 80 123 443 587 993 995')"
# 本机预期开放的端口（站点相关，来自 ops.conf；为空则只按标准端口判断）
HC_EXPECTED_PORTS="$(hc_conf_get HC_EXPECTED_PORTS "$(hc_conf_get PUBLIC_PORTS_ALLOWED '')")"
# 必须只绑 127.0.0.1 的管理端口（暴露到公网即 FAIL）
MANAGED_PORTS="$(hc_conf_get MANAGED_PORTS '9090 3001 9093 9200 5601 5000')"
# 对外连接白名单（允许出现在 ESTABLISHED 里的对端 IP/前缀，空白分隔）
HC_ESTABLISHED_ALLOW="$(hc_conf_get HC_ESTABLISHED_ALLOW '')"

# OOM 历史：额外的内核日志路径（留空则只用内置候选）
HC_KERN_LOG="$(hc_conf_get HC_KERN_LOG '')"

hc_log_open
hc_log_line "=== $HC_SCRIPT_NAME $HC_VERSION 开始巡检  host=$HC_HOSTNAME root=$HC_IS_ROOT conf=${hc_conf_file:-无} ==="

# ============================================================================
# 巡检开始
# ============================================================================
if [[ "$HC_QUIET" != "1" ]]; then
    printf '%s%s %s%s\n' "$C_TITLE" "$HC_SCRIPT_NAME" "$HC_VERSION" "$C_RESET"
    if [[ "$HC_IS_ROOT" == "1" ]]; then _priv="root"; else _priv="普通用户（部分检查会降级为 INFO）"; fi
    printf '主机: %s   时间(UTC): %s   权限: %s\n' "$HC_HOSTNAME" "$HC_RUN_UTC" "$_priv"
    printf '配置: %s\n' "${hc_conf_file:-未加载（使用内置默认值）}"
    printf '保证: 本脚本只读 —— 不修改配置、不重启服务。\n'
fi

# ----------------------------------------------------------------------------
# 1. 内存与 Swap 水位 + OOM 历史
# ----------------------------------------------------------------------------
hc_section "1. 内存与 Swap 水位 / OOM 风险"

# 为什么读 /proc/meminfo 而不是 `free`：
#   /proc/meminfo 是内核直接暴露的原始计数（单位 kB），没有格式化损失，
#   也不会因 procps 版本不同而改字段名。`free` 只是它的一个美化视图。
# 为什么用 MemAvailable 而不是 MemFree：
#   MemFree 只算「完全没被用」的页；Linux 会把空闲内存拿去做 page cache，
#   所以 MemFree 常年很低却并不代表内存紧张。MemAvailable 是内核估计的
#   「不触发 swap 就能给新进程用的量」（= 空闲 + 可回收的 cache/slab），
#   这才是判断 OOM 风险的正确指标。用 MemFree 判会天天误报。
if [[ -r "$MEMINFO_FILE" ]]; then
    # 取值的三种情况必须分开处理，**不能把「没这个字段」当成「值是 0」**：
    #   1) 有 MemAvailable（内核 ≥ 3.14，正常 Linux）→ 直接用，最准
    #   2) 没有 MemAvailable 但有 MemFree/Buffers/Cached → 用经典近似公式
    #      (MemFree + Buffers + Cached)，并**在结论里注明是近似值**
    #   3) 只有 MemFree（如某些容器/WSL 的精简 /proc）→ 既不知道可回收多少，
    #      也不该假装知道 ⇒ 记 INFO，不判 OK 也不判 FAIL
    # 为什么这么啰嗦：awk 里未赋值的变量默认是空串，`printf "%d"` 会把它印成 0。
    # 若不做区分，「字段不存在」就会伪装成「可用内存 0MiB」→ 一条凭空捏造的
    # FAIL。这正是本项目反复记录的那类故障：**把「我读不到」说成「它坏了」。**
    # 所以这里用 sentinel `-1` 表示「该字段不存在」，与真正的 0 严格区分开。
    read -r mem_total_kb mem_avail_kb mem_free_kb mem_bufcache_kb swap_total_kb swap_free_kb < <(
        awk '
            /^MemTotal:/     { t = $2 }
            /^MemAvailable:/ { a = $2 }
            /^MemFree:/      { f = $2 }
            /^Buffers:/      { b = $2 }
            /^Cached:/       { c = $2 }
            /^SwapTotal:/    { st = $2 }
            /^SwapFree:/     { sf = $2 }
            END {
                # 未出现过的字段用 -1 标记，绝不当作 0
                if (a == "")  a = -1
                if (f == "")  f = -1
                # Buffers/Cached 只要有一个缺失，近似公式就不可用
                if (b == "" || c == "") bc = -1; else bc = b + c
                if (t == "")  t = -1
                if (st == "") st = -1
                if (sf == "") sf = -1
                printf "%d %d %d %d %d %d\n", t, a, f, bc, st, sf
            }
        ' "$MEMINFO_FILE" 2>/dev/null || printf -- '-1 -1 -1 -1 -1 -1'
    )
    # 一次性 awk 取多个值，而不是 grep 多次 —— 保证所有数字来自同一时刻的快照，
    # 否则并发变化时算出来的百分比可能是「分子来自这一秒、分母来自下一秒」。

    mem_total_mib=$(( mem_total_kb / 1024 ))
    swap_total_mib=$(( swap_total_kb / 1024 ))
    swap_free_mib=$(( swap_free_kb / 1024 ))

    # 先决定「可用内存」怎么来，并记录它是不是近似值
    mem_avail_mib=""
    mem_avail_source=""
    if (( mem_avail_kb >= 0 )); then
        mem_avail_mib=$(( mem_avail_kb / 1024 ))
        mem_avail_source="exact"
    elif (( mem_free_kb >= 0 && mem_bufcache_kb >= 0 )); then
        mem_avail_mib=$(( (mem_free_kb + mem_bufcache_kb) / 1024 ))
        mem_avail_source="approx"
    fi

    if (( mem_total_mib > 0 )); then
        if [[ -z "$mem_avail_mib" ]]; then
            # 拿不到可回收内存的量 —— 记 INFO。不猜、不 FAIL。
            hc_info "host.memory" "$MEMINFO_FILE 无 MemAvailable 也无 Buffers/Cached（共 ${mem_total_mib}MiB），可用内存未验证"
        else
            # 整数百分比：先乘后除，避免整数除法把 0.8% 截成 0
            mem_avail_pct=$(( mem_avail_mib * 100 / mem_total_mib ))
            if [[ "$mem_avail_source" == "approx" ]]; then
                detail="可用约 ${mem_avail_mib}MiB / 共 ${mem_total_mib}MiB（${mem_avail_pct}%，近似值 = MemFree+Buffers+Cached，内核 < 3.14 无 MemAvailable）"
            else
                detail="可用 ${mem_avail_mib}MiB / 共 ${mem_total_mib}MiB（${mem_avail_pct}%）"
            fi
            if (( mem_avail_pct < THRESH_MEM_FAIL )); then
                hc_fail "host.memory" "$detail，低于 ${THRESH_MEM_FAIL}%，OOM 风险高"
            elif (( mem_avail_pct < THRESH_MEM_WARN )); then
                hc_warn "host.memory" "$detail，低于 ${THRESH_MEM_WARN}%"
            else
                hc_ok "host.memory" "$detail"
            fi
        fi
    else
        hc_info "host.memory" "无法解析 $MEMINFO_FILE 中的 MemTotal，内存水位未验证"
    fi

    if (( swap_total_mib > 0 && swap_free_mib >= 0 )); then
        swap_used_mib=$(( swap_total_mib - swap_free_mib ))
        swap_used_pct=$(( swap_used_mib * 100 / swap_total_mib ))
        detail="已用 ${swap_used_mib}MiB / 共 ${swap_total_mib}MiB（${swap_used_pct}%）"
        if (( swap_used_pct >= THRESH_SWAP_FAIL )); then
            hc_fail "host.swap" "$detail，swap 压力过大"
        elif (( swap_used_pct >= THRESH_SWAP_WARN )); then
            hc_warn "host.swap" "$detail，需确认是否由日志堆积/构建/容器引起"
        else
            hc_ok "host.swap" "$detail"
        fi
    else
        # 没有 swap 不是错误，但它是「内存一旦打满就直接 OOM-kill」的放大器。
        hc_warn "host.swap" "未配置 swap：内存打满时将直接触发 OOM-kill，没有缓冲"
    fi

    if [[ "$HC_QUIET" != "1" ]]; then
        hc_fact "--- /proc/meminfo 关键行 ---"
        grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty):' \
            "$MEMINFO_FILE" 2>/dev/null | hc_indent || true
    fi
else
    hc_info "host.memory" "无法读取 $MEMINFO_FILE（需要 Linux /proc）"
fi

# OOM 历史触发记录：四种来源逐个尝试，全部失败就明确记 INFO（而不是假装没有）
#   1) journalctl -k      —— 内核环形缓冲，systemd 系统首选
#   2) dmesg              —— 非 systemd 或 journal 被裁时
#   3) /var/log/kern.log  —— rsyslog 落盘
#   4) /var/log/syslog    —— 同上，Debian 系兜底
oom_hits=""
oom_source=""
if hc_have_cmd journalctl; then
    oom_hits="$(journalctl -k --no-pager --since '-30 days' 2>/dev/null \
        | grep -Ei 'Out of memory: Killed process|oom-kill:|oom_reaper: reaped process' || true)"
    [[ -n "$oom_hits" ]] && oom_source="journalctl -k（近 30 天）"
fi
if [[ -z "$oom_source" ]] && hc_have_cmd dmesg; then
    # dmesg 在 dmesg_restrict=1 时对非 root 返回空；空 != 没有记录，
    # 所以这里用「命令是否真的能跑」来区分，而不是看输出是否为空。
    if dmesg 2>/dev/null | head -1 >/dev/null 2>&1; then
        oom_hits="$(dmesg 2>/dev/null \
            | grep -Ei 'Out of memory: Killed process|oom-kill:|oom_reaper: reaped process' || true)"
        oom_source="dmesg"
    fi
fi
if [[ -z "$oom_source" ]]; then
    for f in "$HC_KERN_LOG" /var/log/kern.log /var/log/syslog; do
        [[ -n "$f" && -r "$f" ]] || continue
        oom_hits="$(grep -Ei 'Out of memory: Killed process|oom-kill:' "$f" 2>/dev/null || true)"
        oom_source="$f"
        break
    done
fi

if [[ -n "$oom_hits" ]]; then
    oom_count="$(printf '%s\n' "$oom_hits" | hc_count .)"
    oom_last="$(printf '%s\n' "$oom_hits" | tail -n 1 | cut -c1-120)"
    hc_fail "host.oom-history" "发现 ${oom_count} 条 OOM 击杀记录（来源 $oom_source），最近一条：$oom_last"
    if [[ "$HC_QUIET" != "1" ]]; then
        hc_fact "--- 最近 5 条 OOM 记录 ---"
        printf '%s\n' "$oom_hits" | tail -n 5 | hc_indent
    fi
elif [[ -n "$oom_source" ]]; then
    hc_ok "host.oom-history" "未发现 OOM 击杀记录（来源 $oom_source）"
else
    # 关键：这里必须是 INFO。没读到内核日志 ≠ 没发生过 OOM。
    # 把「读不到」写成 OK 就是虚假全绿，正是本项目吃过亏的那类故障。
    hc_info "host.oom-history" "无法读取内核日志（journalctl/dmesg/kern.log 均不可用或需 root），OOM 历史未验证"
fi

# ----------------------------------------------------------------------------
# 2. 根分区磁盘与 inode
# ----------------------------------------------------------------------------
hc_section "2. 根分区磁盘使用率与 inode"

# 为什么用 `df -P` 而不是裸 `df`：
#   -P 是 POSIX 输出格式，保证**每条记录只占一行**。裸 df 在设备名过长时会把
#   记录折成两行，于是 `awk 'NR==2'` 取到的是被折行的半截，字段错位 ——
#   算出来的使用率可能完全不对，而且不报错。巡检脚本必须用 -P。
df_line="$(df -P / 2>/dev/null | awk 'NR==2')"
if [[ -n "$df_line" ]]; then
    disk_usage="$(printf '%s\n' "$df_line" | awk '{gsub("%","",$5); print $5}')"
    disk_avail="$(printf '%s\n' "$df_line" | awk '{print $4}')"
    if [[ "$disk_usage" =~ ^[0-9]+$ ]]; then
        # 注意 df 的 Available 列是「非 root 可用的空间」：ext4 默认给 root 保留
        # 5%，所以 Available + Used 通常 < Size。这是正常的，不是算错了。
        avail_h="$(df -Ph / 2>/dev/null | awk 'NR==2 {print $4}')"
        detail="已用 ${disk_usage}%（可用 ${avail_h:-${disk_avail}K}）"
        if (( disk_usage >= THRESH_DISK_FAIL )); then
            hc_fail "disk.root" "$detail，根分区即将写满"
        elif (( disk_usage >= THRESH_DISK_WARN )); then
            hc_warn "disk.root" "$detail"
        else
            hc_ok "disk.root" "$detail"
        fi
    else
        hc_warn "disk.root" "无法解析 df 输出的使用率: $df_line"
    fi
else
    hc_info "disk.root" "df 不可用或输出异常"
fi

# inode 必须单独查：inode 用尽时 `df -h` 会显示「还有空间」，但任何新建文件
# 都会 ENOSPC（No space left on device）。这个故障极具迷惑性 ——
# 磁盘看着空着，服务却写不进去。典型成因：海量小文件（session、cache、日志分片）。
# -i 是 inode 视图，-P 同样是保证单行。
inode_line="$(df -Pi / 2>/dev/null | awk 'NR==2')"
inode_usage="$(printf '%s\n' "$inode_line" | awk '{gsub("%","",$5); print $5}')"
inode_ifree="$(printf '%s\n' "$inode_line" | awk '{print $4}')"
if [[ "$inode_usage" =~ ^[0-9]+$ ]]; then
    detail="已用 ${inode_usage}%，剩余 inode ${inode_ifree}"
    if (( inode_usage >= THRESH_INODE_FAIL )); then
        hc_fail "disk.inode" "$detail，inode 即将耗尽（磁盘可能仍显示有空间）"
    elif (( inode_usage >= THRESH_INODE_WARN )); then
        hc_warn "disk.inode" "$detail"
    else
        hc_ok "disk.inode" "$detail"
    fi
else
    hc_info "disk.inode" "无法读取 inode 信息"
fi

if [[ "$HC_QUIET" != "1" ]]; then
    hc_fact "--- df -h / ---"
    df -h / 2>/dev/null | hc_indent || true
    hc_fact "--- df -i / ---"
    df -i / 2>/dev/null | hc_indent || true
fi

# ----------------------------------------------------------------------------
# 3. 对外连接与监听端口
# ----------------------------------------------------------------------------
hc_section "3. 对外连接（ESTABLISHED）与非标监听端口"

# 为什么用 `ss` 而不是 `netstat`：
#   netstat 属 net-tools，多数新发行版已不预装；且它遍历 /proc 的效率远低于
#   ss（ss 直接走 netlink 拿内核 socket 表）。ss 是 iproute2 的一部分，
#   现代系统必装。
# 参数含义：
#   -t TCP  -u UDP  -n 不做 DNS/服务名反查（**关键**：不解析才不会因 DNS
#   卡住，也不会把 443 显示成 https、把 22345 显示成未知服务名）
#   -l 只看 LISTEN（监听）  -p 显示进程（非 root 只能看到自己的进程）
#   -H 不打印表头（比 `| tail -n +2` 稳：列数变化时不会错位）
if hc_have_cmd ss; then
    # ---- 3.1 监听端口 ----
    listeners="$(ss -lntuH 2>/dev/null | awk '{print $5}' | sort -u || true)"

    if [[ -z "$listeners" ]]; then
        hc_info "net.listeners" "ss 未返回任何监听端口（可能是权限或内核接口问题）"
    else
        # 拆成「地址」与「端口」两列。ss 的地址写法有 IPv4 (`1.2.3.4:80`)、
        # IPv6 (`[::]:80`)、通配 (`*:80`) 三种，所以端口统一取**最后一个冒号之后**。
        wide_open=""; wide_ports=""
        all_ports=""
        while IFS= read -r addr; do
            [[ -n "$addr" ]] || continue
            port="${addr##*:}"
            [[ "$port" =~ ^[0-9]+$ ]] || continue
            all_ports="${all_ports}${port} "
            # 通配地址 = 绑到所有网卡 = 公网可达
            case "$addr" in
                0.0.0.0:*|\[::\]:*|\*:*|:::*|\[::\])
                    wide_open="${wide_open}${addr} "
                    wide_ports="${wide_ports}${port} " ;;
            esac
        done <<< "$listeners"

        port_count="$(printf '%s\n' $all_ports | hc_count .)"
        port_list="$(printf '%s\n' $all_ports | sort -un | tr '\n' ' ')"
        wide_port_list="$(printf '%s\n' $wide_ports | sort -un | tr '\n' ' ')"
        hc_info "net.listeners" "共监听 ${port_count} 个端口；其中通配地址（公网可达）: ${wide_port_list:-无}"

        # 非标端口：既不在标准端口表，也不在本机预期清单里。
        #
        # ⚠️ 必须按**是否公网可达**分成两类，不能一律 WARN（2026-10-07 修正）：
        #   真机上 12 个「非标」端口里，**全部**都只绑 127.0.0.1（docker-proxy /
        #   caddy admin / containerd …）。它们是正常的内网服务，只是不在我的
        #   标准表里 —— 对它们每轮报 WARN，等于给自己造了一条永远不变的噪音。
        #   本项目 S-03 记过这条：「一条会被忽略的告警比没有告警更糟」。
        #   所以：
        #     · 通配地址上的非标端口 → WARN（新增的攻击面，需要有人认领）
        #     · 仅回环上的非标端口   → INFO（事实记录，不是问题）
        nonstd_wide=""
        nonstd_loop=""
        for p in $port_list; do
            found=0
            for s in $HC_STANDARD_PORTS $HC_EXPECTED_PORTS; do
                [[ "$p" == "$s" ]] && { found=1; break; }
            done
            (( found == 1 )) && continue
            # 是否出现在通配监听里
            if printf '%s\n' "$wide_port_list" | grep -qw -- "$p"; then
                nonstd_wide="${nonstd_wide}${p} "
            else
                nonstd_loop="${nonstd_loop}${p} "
            fi
        done
        if [[ -n "${nonstd_wide// /}" ]]; then
            hc_warn "net.nonstandard-ports" "**公网可达**的非标端口: ${nonstd_wide% }（不在标准表 [$HC_STANDARD_PORTS] 与预期清单 [${HC_EXPECTED_PORTS:-空}] 内，需确认用途）"
        else
            hc_ok "net.nonstandard-ports" "通配地址上无未预期的非标端口"
        fi
        if [[ -n "${nonstd_loop// /}" ]]; then
            hc_info "net.nonstandard-ports-loopback" "仅回环的非标端口: ${nonstd_loop% }（本机服务，非公网攻击面）"
        fi

        # 管理端口暴露到公网 = FAIL。这是实打实的攻击面：
        # Prometheus/Alertmanager/Grafana 这些一旦公网可达，等于把整个监控栈
        # 的未认证接口挂到互联网上。
        exposed=""
        for p in $MANAGED_PORTS; do
            if printf '%s\n' "$wide_open" | grep -qE "[:.]${p} "; then
                exposed="${exposed}${p} "
            fi
        done
        if [[ -n "${exposed// /}" ]]; then
            hc_fail "net.admin-ports" "管理端口暴露在通配地址上: ${exposed% }（必须只绑 127.0.0.1，走 SSH 隧道访问）"
        else
            hc_ok "net.admin-ports" "管理端口（$MANAGED_PORTS）未暴露到通配地址"
        fi

        if [[ "$HC_QUIET" != "1" ]]; then
            hc_fact "--- 通配地址监听（公网可达）---"
            if [[ -n "${wide_open// /}" ]]; then printf '%s\n' $wide_open | hc_indent; else hc_fact "（无）"; fi
            hc_fact "--- ss -lntup 全量 ---"
            ss -lntup 2>/dev/null | hc_indent || true
        fi
    fi

    # ---- 3.2 对外 ESTABLISHED 连接 ----
    # 只取 ESTABLISHED（已建立）而不是 SYN-SENT/CLOSE-WAIT：
    #   ESTABLISHED 才是「此刻正在双向通信」的连接，是判断外联行为的唯一有效状态。
    #   已经 CLOSE-WAIT 的是对端已关闭但本端没回收，属另一类问题。
    established="$(ss -tnpH state established 2>/dev/null || true)"
    if [[ -z "$established" ]]; then
        # 空结果有两种可能：真的没有连接，或者没有权限。区分它们很重要 ——
        # 没有连接的正常服务器是常见的，而「读不到」不能当成「没有」。
        if [[ "$HC_IS_ROOT" != "1" ]]; then
            hc_info "net.established" "未读取到 ESTABLISHED 连接（非 root，进程信息不可见；连接列表本身应可见）"
        else
            hc_ok "net.established" "当前无 ESTABLISHED 对外连接"
        fi
    else
        # 去掉本地回环对端：127.0.0.0/8 与 ::1 是进程间通信，不是「对外」
        # 列序：ss -tnpH 的输出是 Recv-Q / Send-Q / **Local** / **Peer** / Process
        # （表头被 -H 去掉了，所以没有偏移）。因此本地地址是 $3、对端是 $4，
        # **不是 $4/$5** —— 2026-10-07 在真机上写错过一次，症状是明细行印成
        # 「对端 -> 进程」，看起来还挺像回事，所以必须靠真机输出核对列序。
        ext_conns="$(printf '%s\n' "$established" | awk 'NF>=4 {print $3" -> "$4}' \
            | grep -vE '^(127\.|\[::1\])' | grep -vE ' -> (127\.|\[::1\])' || true)"
        ext_count="$(printf '%s\n' "$ext_conns" | hc_count .)"

        # 白名单：配置了就把命中白名单的摘出去，剩下的才叫「异常」
        if [[ -n "$HC_ESTABLISHED_ALLOW" ]]; then
            unlisted="$ext_conns"
            for allow in $HC_ESTABLISHED_ALLOW; do
                unlisted="$(printf '%s\n' "$unlisted" | grep -v -- "$allow" || true)"
            done
            unlisted_count="$(printf '%s\n' "$unlisted" | hc_count .)"
            if (( unlisted_count > 0 )); then
                hc_warn "net.established" "有 ${unlisted_count} 条非白名单对外连接（共 ${ext_count} 条），需确认对端"
            else
                hc_ok "net.established" "共 ${ext_count} 条对外连接，全部在白名单内"
            fi
        else
            # 没配白名单时不能判「异常」—— 出站连接是正常业务行为，
            # 无基准就下结论等于瞎报。所以只记 INFO + 贴出证据供人看。
            hc_info "net.established" "共 ${ext_count} 条对外连接（未配置 HC_ESTABLISHED_ALLOW 白名单，无法判定异常，证据见下）"
        fi

        if [[ "$HC_QUIET" != "1" ]]; then
            hc_fact "--- 对外 ESTABLISHED 明细（本地 -> 对端）---"
            printf '%s\n' "$ext_conns" | head -n 30 | hc_indent
        fi
    fi
else
    hc_info "net.listeners" "ss 不可用（iproute2 未安装），跳过端口与连接检查"
fi

# ----------------------------------------------------------------------------
# 4. SSH 爆破 Top 5 来源 IP（最近 N 小时）
# ----------------------------------------------------------------------------
hc_section "4. SSH 爆破失败 Top 5 来源 IP（最近 ${BF_WINDOW_HOURS} 小时）"

# 数据来源优先级：
#   1) $AUTH_LOG 文件（rsyslog 落盘，最常见）
#   2) journalctl -u ssh/-u sshd（没有 auth.log 时，journald 里也有同样的记录）
# 两者都拿不到就 INFO，绝不报 OK。
bf_lines=""
bf_source=""
if [[ -r "$AUTH_LOG" ]]; then
    # 先把窗口外的行剔掉再统计。**必须按行内时间戳解析**，不能用文件 mtime ——
    # 日志文件是滚动的，mtime 只说明「最后有人写过」，不说明某一行是什么时候的。
    bf_lines="$(awk -v year="$(date -u '+%Y')" -v now="$HC_RUN_EPOCH" \
                    -v win="$(( BF_WINDOW_HOURS * 3600 ))" '
        BEGIN {
            split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", _m, " ")
            for (i = 1; i <= 12; i++) mon[_m[i]] = i
            cutoff = now - win
        }
        {
            # syslog 时间戳格式： "Oct  6 18:12:33"
            # 注意 day 是空格补齐的（"Oct  6" 是两个空格），所以必须让 awk
            # 按「空白串」分词 —— 用 $1/$2/$3 天然正确，用字符切片会错位。
            if (!($1 in mon)) next
            split($3, t, ":")
            if (t[1] == "" || t[2] == "" || t[3] == "") next
            ep = mktime(year " " sprintf("%02d", mon[$1]) " " sprintf("%02d", $2) " " t[1] " " t[2] " " t[3])
            # 跨年：日志里的 12 月而现在是 1 月时，mktime 会算出「未来」的时间戳
            if (ep > now + 86400) {
                ep = mktime((year - 1) " " sprintf("%02d", mon[$1]) " " sprintf("%02d", $2) " " t[1] " " t[2] " " t[3])
            }
            # 容忍 300 秒的时钟微偏；窗口外的直接丢弃
            if (ep < cutoff || ep > now + 300) next
            print
        }' "$AUTH_LOG" 2>/dev/null || true)"
    bf_source="$AUTH_LOG"
elif hc_have_cmd journalctl; then
    bf_lines="$(journalctl --since "${BF_WINDOW_HOURS} hour ago" --no-pager -u ssh -u sshd 2>/dev/null || true)"
    [[ -n "$bf_lines" ]] && bf_source="journalctl -u ssh/sshd（最近 ${BF_WINDOW_HOURS} 小时）"
fi

if [[ -z "$bf_source" ]]; then
    hc_info "ssh.bf-top5" "无法读取 $AUTH_LOG，也无法读 journal（需 root），爆破统计未验证"
else
    # 分三类统计，**不合并**。
    # 为什么不合并：本项目 2026-10-04 出过一次告警误报 —— 当时把
    # 「Failed password」与 PAM 的「authentication failure」合并计数，同一次失败
    # 被记两遍，216 条真实失败被抬成 400+，越过 FAIL 阈值触发了 critical。
    # 教训：**同一事件的多个日志面不能相加**，要么取其一，要么去重。
    # 这里以 `Failed password`（真实的口令认证失败）作为阈值依据，
    # 其余两类只作为上下文展示。
    failed_pw="$(printf '%s\n' "$bf_lines" | hc_count 'Failed password')"
    invalid_user="$(printf '%s\n' "$bf_lines" | hc_count 'Invalid user')"
    conn_closed="$(printf '%s\n' "$bf_lines" | hc_count 'Connection closed by authenticating user')"

    detail="Failed password ${failed_pw} 次 / Invalid user ${invalid_user} 次 / 认证中连接被关闭 ${conn_closed} 次（来源 $bf_source）"
    if (( failed_pw >= THRESH_BF_FAIL )); then
        hc_fail "ssh.bf-count" "$detail，超过 FAIL 阈值 ${THRESH_BF_FAIL}"
    elif (( failed_pw >= THRESH_BF_WARN )); then
        hc_warn "ssh.bf-count" "$detail，超过 WARN 阈值 ${THRESH_BF_WARN}"
    else
        hc_ok "ssh.bf-count" "$detail"
    fi

    # Top 5 来源 IP —— 经典管道，逐段解释：
    #   grep -oE 'from [0-9a-fA-F.:]+'  抽出 "from <IP>"，-o 只保留匹配部分
    #   awk '{print $2}'                取 IP（丢掉 "from"）
    #   sort                            先排序，uniq 只能合并**相邻**的重复行，
    #                                   不排序的 uniq 会把同一 IP 数成好几组
    #   uniq -c                         数每组的行数（= 失败次数）
    #   sort -rn                        -n 按数值排（否则 "10" < "9" 字典序错），
    #                                   -r 倒序 = 次数最多的在前
    #   head -n 5                       取前 5
    top5="$(printf '%s\n' "$bf_lines" \
        | grep -oE 'from [0-9a-fA-F.:]+' 2>/dev/null \
        | awk '{print $2}' \
        | sort | uniq -c | sort -rn | head -n 5 || true)"

    if [[ -n "$top5" ]]; then
        # Top 5 的**内容**直接放进结论消息里，而不是只 `hc_fact` 打到屏幕：
        # hc_fact 在 --quiet 下会被压掉，于是「邮件正文里看不到是谁在打」，
        # 而 JSON 报告里也查不到 —— 两个出口同时缺失，等于这份证据没留下。
        # 放进 message 则无论 --quiet 与否都会落进报告，也才是可被断言的。
        top5_inline="$(printf '%s' "$top5" | awk '{printf "%s(%s) ", $2, $1}')"
        hc_info "ssh.bf-top5" "Top5: ${top5_inline% }"
        if [[ "$HC_QUIET" != "1" ]]; then
            hc_fact "--- Top 5（次数  IP）---"
            printf '%s\n' "$top5" | hc_indent
        fi
    else
        hc_ok "ssh.bf-top5" "窗口内没有可解析的来源 IP（无爆破尝试）"
    fi

    # 成功登录的上下文：失败多不等于被攻破，**成功登录才是入侵信号**。
    # 本项目 2026-10-04 那次告警的取证结论就是靠这一条得出的
    # （10 次成功登录全部是用户自己的公钥）。
    accepted="$(printf '%s\n' "$bf_lines" | grep -E 'Accepted (publickey|password)' || true)"
    accepted_pw="$(printf '%s\n' "$accepted" | hc_count 'Accepted password')"
    if (( accepted_pw > 0 )); then
        # 口令登录成功 = 要么密码认证还开着，要么有人在用密码进来。两者都严重。
        hc_fail "ssh.accepted-password" "窗口内有 ${accepted_pw} 次**口令登录成功**（本机应为纯公钥登录，需立即核查）"
    else
        hc_ok "ssh.accepted-password" "窗口内无口令登录成功记录"
    fi
    if [[ -n "$accepted" && "$HC_QUIET" != "1" ]]; then
        hc_fact "--- 窗口内成功登录 ---"
        printf '%s\n' "$accepted" | tail -n 10 | hc_indent
    fi
fi

# ----------------------------------------------------------------------------
# 5. Caddy 与后端核心服务状态
# ----------------------------------------------------------------------------
hc_section "5. Caddy 与后端核心服务状态"

# 判断「服务健康」不能只看 `systemctl is-active`：
#   一个服务可以是 active 却**反复崩溃重启**（Restart=always 会把它拉起来），
#   这种状态下 is-active 恒为 active，服务却实际上不可用。
#   所以要额外看 NRestarts（systemd 记录的重启计数）与最近日志里的崩溃痕迹。
hc_unit_state() {
    local unit="$1" s
    hc_have_cmd systemctl || { printf 'unknown'; return 0; }
    # `systemctl cat` 是判断「单元是否存在」最可靠的方式：
    # `is-active` 对不存在的单元会返回 inactive 且退出码 3，
    # 与「存在但已停止」长得一样 —— 会把可选组件缺失误报成服务挂了。
    systemctl cat "$unit" >/dev/null 2>&1 || { printf 'absent'; return 0; }
    s="$(systemctl is-active "$unit" 2>/dev/null | head -n 1 || true)"
    printf '%s' "${s:-unknown}"
}

hc_check_unit() {
    local unit="$1" severity="$2"   # severity: core | optional
    local state nrestarts crashes
    state="$(hc_unit_state "$unit")"
    case "$state" in
        active)
            nrestarts="$(systemctl show -p NRestarts --value "$unit" 2>/dev/null | head -n 1 || true)"
            [[ "$nrestarts" =~ ^[0-9]+$ ]] || nrestarts=0
            if (( nrestarts > 3 )); then
                hc_warn "service.$unit" "active，但已重启 ${nrestarts} 次（可能在崩溃循环中，Restart= 把它拉起来了）"
            else
                hc_ok "service.$unit" "active（重启次数 ${nrestarts}）"
            fi
            ;;
        failed)
            # failed 是**已确认异常**，不论 core 还是 optional 都报 FAIL：
            # 一个单元 failed 说明它启动就失败了，不存在「可选所以无所谓」。
            hc_fail "service.$unit" "failed —— 单元启动失败或崩溃退出，查 journalctl -u $unit -n 50"
            ;;
        absent)
            if [[ "$severity" == "core" ]]; then
                hc_fail "service.$unit" "核心单元不存在（未安装或单元名写错）"
            else
                hc_info "service.$unit" "单元不存在（可选组件，按需安装）"
            fi
            ;;
        inactive)
            if [[ "$severity" == "core" ]]; then
                hc_fail "service.$unit" "inactive —— 核心服务未运行"
            else
                hc_warn "service.$unit" "inactive（可选组件已停止）"
            fi
            ;;
        activating)
            hc_warn "service.$unit" "activating —— 正在启动，若长时间停留此状态说明启动卡住"
            ;;
        *)
            hc_info "service.$unit" "状态未知: $state（可能需要 root）"
            ;;
    esac

    # 崩溃痕迹：只看最近 24h，且只找硬失败关键字。
    # 不用 `grep -i error` 是因为正常服务也会打 "error" 字样的业务日志，
    # 那会造成大量噪音；这里只要「进程级崩溃」的证据。
    if [[ "$state" == "active" || "$state" == "failed" ]] && hc_have_cmd journalctl; then
        crashes="$(journalctl -u "$unit" --since '24 hours ago' --no-pager 2>/dev/null \
            | hc_count -E 'segfault|panic|core dumped|Failed with result|Main process exited, code=(exited|killed)')"
        if [[ "$crashes" =~ ^[0-9]+$ ]] && (( crashes > 0 )); then
            hc_warn "service.$unit.crashes" "近 24h 有 ${crashes} 条进程级失败日志（崩溃/非零退出）"
        fi
    fi
    return 0
}

if hc_have_cmd systemctl; then
    for unit in $SYSTEMD_UNITS; do
        sev="optional"
        for c in $CORE_UNITS; do [[ "$unit" == "$c" ]] && sev="core"; done
        hc_check_unit "$unit" "$sev"
    done

    # 主机上其它 failed 单元：不属于本项目但同样说明「有东西坏了」。
    # 这里只 WARN，因为本机可能有刻意保留的云厂商救援单元。
    # ⚠️ 两个坑（2026-10-07 在真机踩到）：
    #   1. 必须加 `--plain`：不加时 systemd 会在每个单元名前印一个 `●` 项目符号，
    #      于是 `awk '{print $1}'` 取到的是 `●` 而不是单元名 —— 症状是报出
    #      「存在其它 failed 单元: *」（所有单元名都被替换成了那个符号）。
    #   2. 不能写 `|| true` 兜空：`systemctl --failed` 在**没有** failed 单元时
    #      退出码是 0 且输出为空，`--plain` 后属实为空；但要靠「输出为空」而非
    #      退出码来判断，故这里保留 `|| true` 只为不让非零退出中断巡检。
    other_failed="$(systemctl --failed --no-legend --no-pager --plain 2>/dev/null | awk 'NF>=1 {print $1}' || true)"
    if [[ -n "$other_failed" ]]; then
        # 三类排除，逐单元判断（**不能用一个 known 标志概括**：
        # 一个已知单元会让整体判 OK，从而掩盖同一列表里真正的未知 failed 单元）：
        #   ① 已在本节上面单独检查过的（SYSTEMD_UNITS）
        #   ② 本机刻意保留的（SYSTEMD_FAILED_ALLOWLIST —— 复用与 daily/weekly 同一配置键）
        #   ③ 其余才算「需要关注」
        unexpected_units=""
        for u in $other_failed; do
            [[ -n "$u" ]] || continue
            skip=0
            for k in $SYSTEMD_UNITS; do
                [[ "$u" == "$k" || "$u" == "$k.service" ]] && skip=1
            done
            for a in $SYSTEMD_FAILED_ALLOWLIST; do
                [[ "$u" == "$a" || "$u" == "$a.service" ]] && skip=1
            done
            (( skip == 0 )) && unexpected_units="${unexpected_units}${u} "
        done

        allowed_hits=""
        for u in $other_failed; do
            for a in $SYSTEMD_FAILED_ALLOWLIST; do
                [[ "$u" == "$a" || "$u" == "$a.service" ]] && allowed_hits="${allowed_hits}${u} "
            done
        done

        if [[ -n "${unexpected_units// /}" ]]; then
            hc_warn "service.other-failed" "存在其它 failed 单元: ${unexpected_units% }（不在预期单元与白名单内，需处理）"
        else
            hc_ok "service.other-failed" "无未预期的 failed 单元"
        fi
        # 白名单命中的单独记 INFO：让「本机确实有个 failed 单元、但是刻意保留的」这件事
        # 仍然可见 —— 否则一旦哪天它从白名单移走，没人知道曾经有过这条。
        if [[ -n "${allowed_hits// /}" ]]; then
            hc_info "service.failed-allowlisted" "白名单内刻意保留的 failed 单元: ${allowed_hits% }（SYSTEMD_FAILED_ALLOWLIST，非本项目故障）"
        fi
    else
        hc_ok "service.other-failed" "无其它 failed 单元"
    fi
else
    hc_info "service.systemd" "systemctl 不可用，跳过服务检查"
fi

# 后端核心容器：本项目后端是 docker compose 起的，systemd 看不到它们。
if [[ -n "${CORE_CONTAINERS// /}" ]] && hc_have_cmd docker; then
    if docker ps >/dev/null 2>&1; then
        for svc in $CORE_CONTAINERS; do
            # 按 compose 服务名问容器，而不是按容器名正则匹配 ——
            # 容器名会随项目名/改名而变（本项目 2026-10-03 改名后，
            # 写死前缀的检查器曾把在跑的容器报成「缺少」）。
            cid="$(docker compose -f "$PROJECT_DIR/compose.yaml" ps -q "$svc" 2>/dev/null | head -n 1 || true)"
            if [[ -z "$cid" ]]; then
                # compose 不可用时退回按 compose 标签找
                cid="$(docker ps -q --filter "label=com.docker.compose.service=$svc" 2>/dev/null | head -n 1 || true)"
            fi
            if [[ -z "$cid" ]]; then
                hc_warn "container.$svc" "未找到运行中的容器（已停止或未部署）"
                continue
            fi
            # 容器状态 + 健康检查状态。有 healthcheck 的容器，health 才是真判据：
            # state=running 只说明进程在，health=unhealthy 说明它其实已经不好使了。
            cstate="$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null || printf 'unknown')"
            chealth="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || printf 'unknown')"
            crestarts="$(docker inspect --format '{{.RestartCount}}' "$cid" 2>/dev/null || printf '0')"
            [[ "$crestarts" =~ ^[0-9]+$ ]] || crestarts=0
            if [[ "$cstate" != "running" ]]; then
                hc_fail "container.$svc" "状态 $cstate（应为 running）"
            elif [[ "$chealth" == "unhealthy" ]]; then
                hc_fail "container.$svc" "running 但健康检查 unhealthy（进程在、服务不好使）"
            elif [[ "$chealth" == "starting" ]]; then
                hc_warn "container.$svc" "健康检查 starting（若长期停留说明起不来）"
            elif (( crestarts > 3 )); then
                hc_warn "container.$svc" "running，但重启过 ${crestarts} 次"
            else
                hc_ok "container.$svc" "running（health=${chealth}，重启 ${crestarts} 次）"
            fi
        done
    else
        hc_info "container.core" "docker 不可用或无权访问，跳过容器检查"
    fi
elif [[ -n "${CORE_CONTAINERS// /}" ]]; then
    hc_info "container.core" "未安装 docker，跳过容器检查"
fi

# Caddy 专项：Caddy 是 TLS 终结者，它挂了等于全站不可达。
# 除进程状态外，额外验证它**真的在监听 443** ——
# 单元 active 但没绑上端口（配置错误、证书加载失败）是可能的。
if hc_have_cmd ss; then
    if ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE '[:.]443$'; then
        hc_ok "caddy.listen-443" "有进程监听 443"
    else
        # 只有 caddy 单元在跑时，没监听 443 才算异常
        if [[ "$(hc_unit_state caddy)" == "active" ]]; then
            hc_fail "caddy.listen-443" "caddy 单元 active 但无人监听 443（TLS 入口不可达）"
        else
            hc_info "caddy.listen-443" "无人监听 443"
        fi
    fi
fi

# DuckDNS 解析一致性：域名解析必须指向本机，否则外部访问会打到别处。
# 只做「解析出来的 IP 是否包含本机公网 IP」的粗判 —— 多 A 记录/CDN 场景下
# 不适用，所以判不出时记 INFO 而不是 FAIL。
PUBLIC_DOMAIN="$(hc_conf_get PUBLIC_DOMAIN '')"
if [[ -n "$PUBLIC_DOMAIN" ]] && hc_have_cmd getent; then
    resolved="$(getent ahostsv4 "$PUBLIC_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
    if [[ -n "${resolved// /}" ]]; then
        # 本机公网 IP：拿不到就跳过比对（不猜）
        my_ip="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)"
        if [[ -n "$my_ip" ]]; then
            if printf '%s\n' "$resolved" | grep -qw "$my_ip"; then
                hc_ok "dns.$PUBLIC_DOMAIN" "解析到 $resolved，含本机公网 IP $my_ip"
            else
                hc_warn "dns.$PUBLIC_DOMAIN" "解析到 $resolved，但不含本机公网 IP $my_ip（DuckDNS 可能未更新）"
            fi
        else
            hc_info "dns.$PUBLIC_DOMAIN" "解析到 $resolved（无法取得本机公网 IP，未做比对）"
        fi
    else
        hc_info "dns.$PUBLIC_DOMAIN" "解析失败或无 A 记录（需确认 DuckDNS 是否过期）"
    fi
fi

# ============================================================================
# 结论
# ============================================================================
hc_section "巡检结论"

WORST="$(hc_worst_level)"
case "$WORST" in
    FAIL) EXIT_CODE=2 ;;
    WARN) EXIT_CODE=1 ;;
    *)    EXIT_CODE=0 ;;
esac

if [[ "$HC_QUIET" != "1" ]]; then
    printf '脚本      : %s %s\n' "$HC_SCRIPT_NAME" "$HC_VERSION"
    printf '主机      : %s\n' "$HC_HOSTNAME"
    printf '时间(UTC) : %s\n' "$HC_RUN_UTC"
    printf '配置文件  : %s\n' "${hc_conf_file:-未加载（使用内置默认值）}"
    printf '结论      : %s\n' "$WORST"
    printf '明细      : FAIL=%s WARN=%s OK=%s INFO=%s\n' \
        "$hc_count_fail" "$hc_count_warn" "$hc_count_ok" "$hc_count_info"
fi

if (( hc_count_fail > 0 )); then
    [[ "$HC_QUIET" != "1" ]] && printf '\n需要优先处理的 FAIL 项：\n'
    for (( i = 0; i < ${#hc_level[@]}; i++ )); do
        [[ "${hc_level[$i]}" == "FAIL" ]] || continue
        printf '  %s- %s: %s%s\n' "$C_FAIL" "${hc_check[$i]}" "${hc_message[$i]}" "$C_RESET"
    done
fi

# INFO 必须显式提醒：它代表「没验证」，不是「没问题」。
# 巡检报告最常见的误读就是把没跑成的检查当成通过的检查。
if (( hc_count_info > 0 )) && [[ "$HC_QUIET" != "1" ]]; then
    printf '\n注意：有 %s 项是 INFO（未验证），它们**不代表通过**。\n' "$hc_count_info"
    printf '      常见原因：非 root 运行、缺少对应日志、服务未安装。\n'
fi

hc_log_line "=== 结论 $WORST  FAIL=$hc_count_fail WARN=$hc_count_warn OK=$hc_count_ok INFO=$hc_count_info 退出码=$EXIT_CODE ==="

# ----------------------------------------------------------------------------
# JSON 报告（可选）
# ----------------------------------------------------------------------------
if [[ -n "$HC_JSON_OUT" ]]; then
    hc_json_escape() {
        local s="${1-}"
        s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
        s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
        printf '%s' "$s"
    }

    # --json 传**目录**时自动补时间戳文件名，传文件路径则照用。
    # 为什么要这样：scripts/ops 下日/周/月巡检的 `--json` 收的是**目录**
    # （`--json /var/lib/knowtrace/reports/`），由脚本自己拼 `<script>-<UTC>.json`。
    # 本脚本最初的语义是「收完整文件路径」—— 两者不一致，
    # 于是按既有约定写的 systemd 单元（传目录）会让报告写到目录名那个「文件」上并失败。
    # 现在两种都收：路径以 / 结尾或已是目录 ⇒ 当成目录。
    json_target="$HC_JSON_OUT"
    if [[ "$json_target" == */ || -d "$json_target" ]]; then
        json_target="${json_target%/}/$(date -u '+%Y%m%dT%H%M%SZ')-${HC_SCRIPT_NAME}.json"
        # 文件名用 <UTC戳>-<script>.json，与既有报告 <script>-<UTC戳>.json **不一样** ——
        # 这是刻意的：既有 write-ops-metrics.sh 用正则 `(.+)-(\d{8}T\d{6}Z)\.json`
        # 抓取 `daily-ops-…` 这类文件，若本脚本也叫 `daily-ops-…` 会与真日巡检**撞名**。
        # 反过来写（戳在前）既不会被那个正则命中，也保留了可排序性。
    fi

    {
        printf '{\n'
        # schema/title/hostname/generated_at 与 scripts/ops 的报告保持同名同义，
        # 这样同一目录下两类报告可以被同一套工具解析（少一处口径分叉）。
        printf '  "schema": "knowtrace.health-check/1",\n'
        printf '  "script": "%s",\n' "$HC_SCRIPT_NAME"
        printf '  "version": "%s",\n' "$HC_VERSION"
        printf '  "title": "%s",\n' "单机轻量巡检（server_health_check）"
        printf '  "hostname": "%s",\n' "$(hc_json_escape "$HC_HOSTNAME")"
        printf '  "generated_at": "%s",\n' "$HC_RUN_UTC"
        # worst 是既有工具读的键名（write-ops-metrics.sh 读 report["worst"]），
        # 因此这里也叫 worst，而不是自创 worst_level。
        printf '  "worst": "%s",\n' "$WORST"
        printf '  "exit_code": %s,\n' "$EXIT_CODE"
        printf '  "config_file": "%s",\n' "$(hc_json_escape "${hc_conf_file:-}")"
        printf '  "counts": {"fail": %s, "warn": %s, "ok": %s, "info": %s},\n' \
            "$hc_count_fail" "$hc_count_warn" "$hc_count_ok" "$hc_count_info"
        printf '  "findings": [\n'
        for (( i = 0; i < ${#hc_level[@]}; i++ )); do
            sep=","
            (( i == ${#hc_level[@]} - 1 )) && sep=""
            printf '    {"level": "%s", "check": "%s", "message": "%s"}%s\n' \
                "${hc_level[$i]}" "$(hc_json_escape "${hc_check[$i]}")" \
                "$(hc_json_escape "${hc_message[$i]}")" "$sep"
        done
        printf '  ]\n}\n'
    } > "$json_target" 2>/dev/null || printf '警告：无法写入 JSON 报告 %s\n' "$json_target" >&2
fi

# ----------------------------------------------------------------------------
# 学习指引：脚本用到的核心命令参数详解
# ----------------------------------------------------------------------------
hc_print_reference() {
    cat <<'REF'

════════════════════════════════════════════════════════════════════════════
核心命令参数详解（为什么这么写）
════════════════════════════════════════════════════════════════════════════

【内存】
  awk '/^MemAvailable:/ {print $2}' /proc/meminfo
      · 读 /proc/meminfo 而不是 `free`：它是内核原始计数（kB），无格式化损失，
        也不受 procps 版本影响。`free` 只是它的美化视图。
      · 用 MemAvailable 而不是 MemFree：Linux 把空闲内存拿去做 page cache，
        MemFree 常年很低却不代表紧张；MemAvailable = 空闲 + 可回收的 cache/slab，
        是内核给出的「不触发 swap 就能给新进程用的量」。用 MemFree 判会天天误报。
      · 一次性 awk 取多个值（END 里 printf 一行），保证所有数字来自同一时刻快照。

  journalctl -k --no-pager --since '-30 days' | grep -Ei 'Out of memory: Killed process'
      · -k / --dmesg 只看内核消息，过滤掉海量应用日志。
      · --no-pager 必须加：否则 journalctl 会调 less 并挂住等待输入 ——
        在 cron/systemd 里没有 tty，表现为「脚本卡死」。
      · 四种来源逐个降级（journalctl -k → dmesg → kern.log → syslog），
        全拿不到时记 INFO 而不是 OK：**「读不到」不等于「没发生」**。

【磁盘】
  df -P /            ← -P 是 POSIX 格式，保证每条记录只占一行
  df -Pi /           ← 追加 -i = inode 视图
      · 裸 df 在设备名过长时会折行，`awk 'NR==2'` 就取到半截记录、字段错位，
        算出的使用率可能完全不对**而且不报错**。巡检必须用 -P。
      · inode 必须单独查：inode 耗尽时 df -h 显示「还有空间」，但任何新建文件
        都报 ENOSPC。典型成因是海量小文件（session/cache/日志分片）。
      · df 的 Available 是「非 root 可用」：ext4 默认给 root 保留 5%，
        所以 Used + Available < Size 是正常的，不是算错了。

【端口与连接】
  ss -lntuH                     ← 监听端口
  ss -tnpH state established    ← 已建立连接
      · 用 ss 不用 netstat：netstat 属 net-tools，新发行版多已不预装；
        ss 走 netlink 直接读内核 socket 表，比 netstat 遍历 /proc 快得多。
      · -n 不做名称反查（**关键**）：不解析才不会因 DNS 卡住，
        也不会把 443 显示成 https 而让脚本比较端口号时失配。
      · -H 不打印表头，比 `| tail -n +2` 稳（列数变化时不会错位）。
      · 只取 ESTABLISHED：这才是「此刻正在双向通信」的连接。
        CLOSE-WAIT 是本端未回收，SYN-SENT 是还没连上，都不是外联行为的证据。
      · 端口统一取「最后一个冒号之后」：ss 的地址有 1.2.3.4:80、[::]:80、*:80
        三种写法，按冒号切分才能同时覆盖 IPv4/IPv6/通配。
      · 通配地址（0.0.0.0 / [::] / *）= 绑到所有网卡 = 公网可达，
        这是判断「管理端口是否暴露」的唯一依据。

【SSH 爆破统计】
  awk -v year=$(date -u +%Y) -v now=$(date -u +%s) '... mktime(...)'
      · **必须按行内时间戳解析**，不能用文件 mtime：日志是滚动的，
        mtime 只说明「最后有人写过」，不说明某一行是什么时候的。
      · syslog 时间戳 "Oct  6 18:12:33" 的日号是空格补齐的（两个空格），
        所以要用 $1/$2/$3 让 awk 按空白串分词 —— 字符切片会错位。
      · mktime 需要 "YYYY MM DD HH MM SS"，年份日志里没有，得从外部传入；
        并要处理跨年（现在是 1 月、日志是去年 12 月时会算出「未来」的时间戳）。
      · 容差 300 秒：容忍本机时钟微偏，避免边界行被误丢。

  grep -oE 'from [0-9a-fA-F.:]+' | awk '{print $2}' | sort | uniq -c | sort -rn | head -n 5
      · grep -o 只保留匹配到的部分（整行太长，且 IP 位置随日志格式变化）。
      · **sort 必须在 uniq 之前**：uniq 只能合并**相邻**的重复行，
        不先排序会把同一个 IP 数成好几组。
      · sort -rn 的 -n 是按数值排序（否则 "10" 会排在 "9" 前面，字典序），
        -r 是倒序 —— 次数最多的在前。
      · head -n 5 取 Top 5。整条管道是「Top-N 统计」的标准写法。

  分类计数而不合并：
      · 本项目 2026-10-04 出过一次告警误报：把 `Failed password` 与 PAM 的
        `authentication failure` 合并计数，同一次失败被记两遍，216 条真实失败
        被抬到 400+ 触发了 critical。**同一事件的多个日志面不能相加**。
      · 这里以 `Failed password` 作为阈值依据，另两类只作上下文展示。
      · 同时统计 `Accepted password`：失败多不等于被攻破，
        **成功登录才是入侵信号**。

【服务状态】
  systemctl cat <unit>          ← 判断单元是否存在
  systemctl is-active <unit>    ← active/inactive/failed/activating
  systemctl show -p NRestarts --value <unit>
      · 为什么先 `cat`：`is-active` 对不存在的单元返回 inactive（退出码 3），
        与「存在但已停止」长得一样，会把可选组件缺失误报成服务挂了。
      · 为什么看 NRestarts：`Restart=always` 会让崩溃的服务反复被拉起，
        此时 is-active 恒为 active，服务却实际上不可用。重启计数才是破绽。
      · docker 侧同理：`State.Status=running` 只说明进程在，
        `State.Health.Status` 才是服务好不好使 —— unhealthy 必须报 FAIL。

  journalctl -u <unit> --since '24 hours ago' | grep -Ec 'segfault|panic|core dumped|Failed with result'
      · 不用 `grep -i error`：正常服务也会打 "error" 字样的业务日志，噪音太大；
        这里只找**进程级崩溃**的硬证据。
      · -c 计数（配合 -E 用扩展正则）。

【日志与轮转】
  date -u '+%Y-%m-%dT%H:%M:%SZ'   ← 一律 UTC + ISO8601
      · 服务器时区可能是任意值，本地时间混进日志会让跨机对照彻底失效。
      · ISO8601 可排序、可被所有日志系统解析。本项目服务器是 Etc/UTC，
        本地是 +08，差 8 小时 —— 时间口径不统一最容易造成误判。

  logrotate：本脚本的日志用 copytruncate 而不是默认的 create（见下节）。
      · 因为脚本是**追加**写日志、且不持有文件句柄超过一次运行，
        默认的 create（rename + 新建）会让并发写入落到已被 rename 的旧 inode 上，
        那一部分日志就永久丢失。copytruncate 是「先复制再清空原文件」，
        对追加型写入者安全。
      · 轮转不需要 postrotate 发信号：脚本不常驻、没有需要重开的 fd。

【shell 写法】
  set -uo pipefail  而**不是** set -e
      · -u：引用未定义变量即报错（挡掉 $THRESHOLD 拼错却静默为空这类 bug）。
      · -o pipefail：管道中任一环失败则整体失败 —— 否则
        `cmd | grep x` 里 cmd 挂了、grep 没匹配，退出码仍是 grep 的，故障被吞。
      · 故意不加 -e：巡检要在单条命令失败时继续跑完并把它记成结论。
        加了 -e，第一个非零退出（例如 grep 没匹配到）会直接终止整个巡检，
        于是「没发现问题」和「脚本半路死了」在退出码上长得一样。
        代价是每处可能失败的命令都要显式处理（|| true 或判返回值）。
  export LC_ALL=C
      · 让排序与数字解析与语言环境无关。zh_CN.UTF-8 下 sort 的排序规则不同，
        且某些 locale 下 awk 的小数点会变成逗号（printf "%.0f" 输出 "1,5"）。
  printf '%-26s' 与 [[ -t 1 ]]
      · 颜色只在 stdout 是终端时启用：脚本常被重定向进文件或管道给 mail，
        那种情况下 ANSI 转义序列会变成乱码。也认 NO_COLOR 环境变量（社区约定）。

════════════════════════════════════════════════════════════════════════════
Logrotate 配置建议
════════════════════════════════════════════════════════════════════════════
写入 /etc/logrotate.d/server-health-check（权限 0644，root:root）：

    /var/log/health_check.log {
        daily
        rotate 30
        missingok
        notifempty
        compress
        delaycompress
        copytruncate
        su root root
        create 0640 root adm
    }

逐项说明：
  daily / rotate 30   每天轮转、保留 30 份（约一个月）。按巡检频率可调：
                      若 cron 每天跑一次，30 份 = 一个月；若每周跑，改 rotate 12。
  missingok           日志不存在时不报错（首次部署、刚轮转过都会出现）。
  notifempty          空文件不轮转，避免产生一堆 0 字节归档。
  compress            归档压缩。纯文本日志压缩比通常 10:1 以上。
  delaycompress       本次轮转的文件先不压，留到下一次 —— 因为刚轮转的文件
                      可能仍有写入者持有句柄，立刻压缩会出问题。
  copytruncate        **关键**：先复制内容再把原文件截断为 0，
                      而不是 rename 后新建。本脚本是「打开→追加→关闭」的
                      追加型写入者，rename 之后它的写入会落到已被移走的旧 inode，
                      那部分日志永久丢失。copytruncate 对这类写入者安全。
                      代价：复制与截断之间有几毫秒的窗口，极少量并发写入可能丢 ——
                      对巡检日志完全可以接受。
  su root root        以 root 身份轮转（日志目录 /var/log 非 root 不可写）。
                      logrotate 默认会拒绝轮转「父目录可被非 root 写入」的文件。
  create 0640 root adm
                      轮转后新建的文件权限。给 adm 组读权限，
                      这样非 root 的运维账号（在 adm 组）也能看巡检日志。

验证与排错：
    logrotate -d /etc/logrotate.d/server-health-check   # -d 干跑，只打印不执行
    logrotate -f /etc/logrotate.d/server-health-check   # -f 强制立即轮转一次
    ls -la /var/log/health_check.log*                   # 确认归档生成

  ⚠ 若用 -f 强制轮转做验证，请先确认没有正在运行的巡检；
    并记得 logrotate 的状态文件在 /var/lib/logrotate/status，
    删掉日志文件不会重置「上次轮转时间」。

REF
}

if [[ "$HC_QUIET" != "1" && "$HC_NO_REFERENCE" != "1" ]]; then
    hc_print_reference
fi

# ============================================================================
# --self-test：负向证伪自检
# ============================================================================
# 设计原则（本项目的「判据必须可证伪」纪律）：
#   一个检查如果**永远不会报警**，它和不存在没有区别，但看起来像有覆盖。
#   所以每个判据都必须有「注入故障 → 断言必定报警」的用例。
#
# 做法：造一个假的运行环境（假 /proc/meminfo、假 df、假 systemctl、假 auth.log），
# 用假 PATH 把**真脚本**跑一遍，然后断言 JSON 报告里对应检查项确实是 FAIL。
# 这测的是真脚本的真代码路径，不是测试替身自己。
hc_run_self_test() {
    local tmp rc=0 pass=0 fail=0
    tmp="$(mktemp -d 2>/dev/null)" || { printf '无法创建临时目录，自检中止\n' >&2; return 3; }

    mkdir -p "$tmp/bin"
    # ---- 假 /proc/meminfo：MemTotal 2048MiB，MemAvailable 只剩 2%（应判 FAIL）----
    cat > "$tmp/meminfo" <<'EOF'
MemTotal:        2097152 kB
MemFree:          102400 kB
MemAvailable:      40960 kB
Buffers:            8192 kB
Cached:            51200 kB
SwapTotal:       2097152 kB
SwapFree:        2097152 kB
Dirty:                 0 kB
EOF

    # ---- 假 df：根分区 95%（应判 FAIL）、inode 96%（应判 FAIL）----
    cat > "$tmp/bin/df" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *-Pi*) printf 'Filesystem     Inodes  IUsed   IFree IUse%% Mounted on\n/dev/fake     1000000 960000   40000   96%% /\n' ;;
  *-Ph*) printf 'Filesystem      Size  Used Avail Use%% Mounted on\n/dev/fake        40G   38G  2.0G  95%% /\n' ;;
  *-P*)  printf 'Filesystem     1024-blocks     Used Available Capacity Mounted on\n/dev/fake         41943040 39845888   2097152      95%% /\n' ;;
  *-h*)  printf 'Filesystem      Size  Used Avail Use%% Mounted on\n/dev/fake        40G   38G  2.0G  95%% /\n' ;;
  *-i*)  printf 'Filesystem     Inodes  IUsed   IFree IUse%% Mounted on\n/dev/fake     1000000 960000   40000   96%% /\n' ;;
  *)     printf 'Filesystem     1024-blocks     Used Available Capacity Mounted on\n/dev/fake         41943040 39845888   2097152      95%% /\n' ;;
esac
EOF

    # ---- 假 systemctl：caddy 是 failed（应判 FAIL）----
    cat > "$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
# 只实现本脚本用到的子命令
case "$1" in
  cat)        case "$2" in caddy.service|nginx.service|ssh.service|docker.service) exit 0 ;; *) exit 1 ;; esac ;;
  is-active)  case "$2" in caddy.service) printf 'failed\n'; exit 3 ;; *) printf 'active\n'; exit 0 ;; esac ;;
  show)       printf '0\n'; exit 0 ;;
  # 忠实复刻真机行为：systemctl --failed --no-legend 会**前置一个 ● 项目符号**
  # （除非加 --plain）。假 systemctl 若不还原这一点，回归用例就测不到那个 bug。
  --failed)   if [[ "$*" == *--plain* ]]; then
                  printf 'repass.service loaded failed failed repass\n'
              else
                  printf '\xe2\x97\x8f repass.service loaded failed failed repass\n'
              fi
              exit 0 ;;
  *)          exit 0 ;;
esac
EOF

    # ---- 假 ss：暴露一个管理端口 9090 在通配地址上（应判 FAIL）----
    cat > "$tmp/bin/ss" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *state*established*) exit 0 ;;
  *-lntup*) printf 'Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
            printf 'tcp   LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("caddy",pid=1,fd=3))\n'
            printf 'tcp   LISTEN 0 128 0.0.0.0:9090 0.0.0.0:* users:(("prom",pid=2,fd=3))\n'
            exit 0 ;;
  *)        printf 'tcp   LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'
            printf 'tcp   LISTEN 0 128 0.0.0.0:9090 0.0.0.0:*\n'
            printf 'tcp   LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*\n'
            exit 0 ;;
esac
EOF

    # ---- 假 auth.log：3 个来源 IP，其中一个刷了 900 次（应判 FAIL + Top1 正确）----
    {
        d="$(date -u '+%b %e %H:%M:%S')"
        i=1
        while (( i <= 900 )); do
            printf '%s fake sshd[1]: Failed password for invalid user u%s from 203.0.113.66 port 5%04d ssh2\n' "$d" "$i" "$i"
            i=$(( i + 1 ))
        done
        i=1
        while (( i <= 40 )); do
            printf '%s fake sshd[1]: Failed password for root from 198.51.100.7 port 6%04d ssh2\n' "$d" "$i"
            i=$(( i + 1 ))
        done
        i=1
        while (( i <= 5 )); do
            printf '%s fake sshd[1]: Failed password for admin from 192.0.2.9 port 7%04d ssh2\n' "$d" "$i"
            i=$(( i + 1 ))
        done
        printf '%s fake sshd[1]: Accepted publickey for root from 198.51.100.7 port 2222 ssh2\n' "$d"
    } > "$tmp/auth.log"

    chmod +x "$tmp/bin/df" "$tmp/bin/systemctl" "$tmp/bin/ss" 2>/dev/null || true

    printf '%s\n' "════════════════════════════════════════════════════════════════"
    printf '%s\n' "自检：注入故障，断言判据必定报警（负向证伪）"
    printf '%s\n' "════════════════════════════════════════════════════════════════"
    printf '环境: %s\n\n' "$tmp"

    # 用假 PATH + 假数据源跑真脚本
    PATH="$tmp/bin:$PATH" \
    HC_MEMINFO_FILE="$tmp/meminfo" \
    HC_AUTH_LOG="$tmp/auth.log" \
    HC_STANDARD_PORTS="22 53 80 443" \
    HC_EXPECTED_PORTS="443" \
    MANAGED_PORTS="9090" \
    HC_SYSTEMD_UNITS="caddy" \
    HC_CORE_UNITS="caddy" \
    HC_CORE_CONTAINERS="" \
    PUBLIC_DOMAIN="" \
    HC_KERN_LOG="$tmp/nonexistent-kern.log" \
    SYSTEMD_FAILED_ALLOWLIST="repass.service" \
    bash "$0" --no-color --quiet --no-log --no-reference --json "$tmp/report.json" \
    > "$tmp/stdout.txt" 2>&1
    rc=$?
    # 注意：上面这一行**没有** `|| true` —— 我们要的就是它的退出码。
    # 注入的故障足够多，正确行为是退出码 2（存在 FAIL）。

    st_assert() {
        local desc="$1" expected="$2" actual="$3"
        if [[ "$expected" == "$actual" ]]; then
            printf '  %s[PASS]%s %s  → %s\n' "$C_OK" "$C_RESET" "$desc" "$actual"
            pass=$(( pass + 1 ))
        else
            printf '  %s[FAIL]%s %s  → 期望 %s，实际 %s\n' "$C_FAIL" "$C_RESET" "$desc" "$expected" "$actual"
            fail=$(( fail + 1 ))
        fi
    }

    # 从 JSON 里取某个 check 的 level
    st_level_of() {
        local check="$1"
        grep -o "{\"level\": \"[A-Z]*\", \"check\": \"${check}\"[^}]*}" "$tmp/report.json" 2>/dev/null \
            | head -n 1 | sed -E 's/^\{"level": "([A-Z]+)".*/\1/' || printf 'MISSING'
    }

    if [[ ! -s "$tmp/report.json" ]]; then
        printf '  %s[FAIL]%s 自检未能生成 JSON 报告，后续断言全部无法执行\n' "$C_FAIL" "$C_RESET"
        printf '\n--- 脚本输出（供排错）---\n'
        head -40 "$tmp/stdout.txt" 2>/dev/null
        rm -rf "$tmp"
        return 3
    fi

    st_assert "注入内存 2% 可用 → host.memory"            "FAIL" "$(st_level_of host.memory)"
    st_assert "注入 swap 0% 已用 → host.swap"             "OK"   "$(st_level_of host.swap)"
    st_assert "注入根分区 95% → disk.root"                "FAIL" "$(st_level_of disk.root)"
    st_assert "注入 inode 96% → disk.inode"               "FAIL" "$(st_level_of disk.inode)"
    st_assert "注入 9090 在通配地址 → net.admin-ports"    "FAIL" "$(st_level_of net.admin-ports)"
    st_assert "注入 900 次爆破 → ssh.bf-count"            "FAIL" "$(st_level_of ssh.bf-count)"
    st_assert "注入 caddy failed → service.caddy"         "FAIL" "$(st_level_of service.caddy)"
    st_assert "脚本退出码（有 FAIL 应为 2）"              "2"    "$rc"

    # Top1 必须是刷得最多的那个 IP —— 这条断言防的是「排序写反」，
    # 那种 bug 下 bf-count 仍然会 FAIL（总数对），但 Top5 会指错人。
    #
    # 从 **JSON 报告**里断言，而不是从 stdout：自检跑在 --quiet 下，
    # 屏幕证据（hc_fact）会被压掉。之前这里 grep stdout 导致断言假失败 ——
    # 注意这是「测试写错了」，不是「脚本坏了」，两者必须分清。
    # 同时验证首位确实是 203.0.113.66（900 次那个），而不只是「出现在某处」。
    top5_msg="$(grep -o '"check": "ssh.bf-top5", "message": "[^"]*"' "$tmp/report.json" 2>/dev/null | head -n 1 || true)"
    top1="$(printf '%s' "$top5_msg" | grep -oE '203\.0\.113\.66\(900\)' | head -n 1 || true)"
    st_assert "Top 5 首位 = 刷 900 次的 203.0.113.66" "203.0.113.66(900)" "${top1:-未找到}"

    # 反向断言：未注入故障的检查不应被误报成 FAIL
    st_assert "未注入故障的 net.nonstandard-ports 不应 FAIL" "WARN" "$(st_level_of net.nonstandard-ports)"

    # ---- 回归用例：/proc/meminfo 缺 MemAvailable 时，绝不能凭空捏造 FAIL ----
    # 起因：2026-10-06 在本机实跑时发现 —— 精简版 /proc/meminfo 只有 MemFree、
    # 没有 MemAvailable，awk 未赋值变量被 %d 印成 0，于是报出
    # 「可用 0MiB / 共 15753MiB（0%），OOM 风险高」这条**完全捏造**的 FAIL，
    # 而它自己打印的原始证据（MemFree 3648956 kB）就在下面几行，自相矛盾。
    # 这里把「字段缺失」固化成一个必须每次都跑的用例。
    printf 'MemTotal:        2097152 kB\nMemFree:          102400 kB\nSwapTotal:       2097152 kB\nSwapFree:        2097152 kB\n' > "$tmp/meminfo-partial"
    PATH="$tmp/bin:$PATH" \
    HC_MEMINFO_FILE="$tmp/meminfo-partial" \
    HC_AUTH_LOG="$tmp/auth.log" \
    HC_KERN_LOG="$tmp/nonexistent-kern.log" \
    bash "$0" --no-color --quiet --no-log --no-reference --json "$tmp/report2.json" \
    > /dev/null 2>&1 || true
    st2() {
        grep -o "{\"level\": \"[A-Z]*\", \"check\": \"host.memory\"[^}]*}" "$tmp/report2.json" 2>/dev/null \
            | head -n 1 | sed -E 's/^\{"level": "([A-Z]+)".*/\1/' || printf 'MISSING'
    }
    st_assert "缺 MemAvailable 时 host.memory 应为 INFO（不得捏造 FAIL）" "INFO" "$(st2)"

    # ---- 反向：有 MemAvailable 且充足时，必须能判出 OK（防止「一律 INFO」的假修复）----
    printf 'MemTotal:        2097152 kB\nMemAvailable:    1048576 kB\nMemFree:          102400 kB\nSwapTotal:       2097152 kB\nSwapFree:        2097152 kB\n' > "$tmp/meminfo-ok"
    PATH="$tmp/bin:$PATH" \
    HC_MEMINFO_FILE="$tmp/meminfo-ok" \
    HC_AUTH_LOG="$tmp/auth.log" \
    HC_KERN_LOG="$tmp/nonexistent-kern.log" \
    bash "$0" --no-color --quiet --no-log --no-reference --json "$tmp/report3.json" \
    > /dev/null 2>&1 || true
    st3() {
        grep -o "{\"level\": \"[A-Z]*\", \"check\": \"host.memory\"[^}]*}" "$tmp/report3.json" 2>/dev/null \
            | head -n 1 | sed -E 's/^\{"level": "([A-Z]+)".*/\1/' || printf 'MISSING'
    }
    st_assert "有 MemAvailable 且可用 50% 时 host.memory 应为 OK" "OK" "$(st3)"

    # ---- 回归：真机跑出来的三类缺陷（2026-10-07，本地自检**全绿**却漏掉的）----
    # 这三条只有拿真机输出才发现的，所以必须固化成自检用例，
    # 否则「本地全绿」会再次掩盖它们。

    # (1) `grep -c X || printf '0'` 会产出 "0\n0"（grep 无匹配时既打印 0 又退出 1），
    #     导致 `(( n >= N ))` 报 syntax error，并把「0↵0 次」写进报告。
    #     断言：本地空数据下不应出现任何 arithmetic 报错。
    errs="$(grep -c 'syntax error in expression' "$tmp/stdout.txt" 2>/dev/null || true)"
    [[ "$errs" =~ ^[0-9]+$ ]] || errs=0
    st_assert "空数据下不应有 arithmetic syntax error" "0" "$errs"

    # (2) 计数结果里不应夹换行（"0\n0" 的另一个症状）
    badcnt="$(grep -cE 'Failed password [0-9]+$' "$tmp/stdout.txt" 2>/dev/null || true)"
    [[ "$badcnt" =~ ^[0-9]+$ ]] || badcnt=0
    st_assert "计数不应出现「数字+换行+数字」" "0" "$badcnt"

    # (3) `systemctl --failed --no-legend` 的 `●` 项目符号会污染 $1，
    #     症状是解析出的单元名变成项目符号本身（真机上显示为 `●`），而不是 repass.service。
    #     假 systemctl 已忠实还原「带 ●」的输出；没有 --plain 时下面取到的会是符号。
    #     注：白名单生效时，单元名落在 service.failed-allowlisted 这条 INFO 里
    #     （other-failed 那条此时是「无未预期」），所以从这里取。
    svcmsg="$(grep -o '"check": "service.failed-allowlisted", "message": "[^"]*"' "$tmp/report.json" 2>/dev/null | head -n 1 || true)"
    if printf '%s' "$svcmsg" | grep -q 'repass\.service'; then
        st_assert "failed 单元名正确解析（--plain 生效）" "ok" "ok"
    else
        st_assert "failed 单元名正确解析（--plain 生效）" "含 repass.service" "${svcmsg:-未找到}"
    fi

    # ---- 白名单：刻意保留的 failed 单元不应报 WARN ----
    # 本机 SYSTEMD_FAILED_ALLOWLIST=repass.service（云厂商救援链路，INC-S2-003）。
    # 不认这个键，本脚本就会成为**唯一**说这台机器不健康的工具（daily/weekly 都认）。
    st_assert "白名单内的 failed 单元 → other-failed 应为 OK" "OK" "$(st_level_of service.other-failed)"
    st_assert "白名单命中要记 INFO（保持可见）" "INFO" "$(st_level_of service.failed-allowlisted)"

    # 反向：白名单**为空**时，同一个 failed 单元必须报 WARN（防止「一律不报」的假修复）
    PATH="$tmp/bin:$PATH" \
    HC_MEMINFO_FILE="$tmp/meminfo-ok" \
    HC_AUTH_LOG="$tmp/auth.log" \
    HC_KERN_LOG="$tmp/nonexistent-kern.log" \
    SYSTEMD_FAILED_ALLOWLIST="" \
    bash "$0" --no-color --quiet --no-log --no-reference --json "$tmp/report4.json" \
    > /dev/null 2>&1 || true
    st4() {
        grep -o "{\"level\": \"[A-Z]*\", \"check\": \"service.other-failed\"[^}]*}" "$tmp/report4.json" 2>/dev/null \
            | head -n 1 | sed -E 's/^\{"level": "([A-Z]+)".*/\1/' || printf 'MISSING'
    }
    st_assert "白名单为空时同一单元应报 WARN" "WARN" "$(st4)"

    printf '\n  自检结果: PASS=%s FAIL=%s\n' "$pass" "$fail"
    if (( fail > 0 )); then
        printf '  %s结论: 有判据未按预期报警 —— 这是「检查器悄悄失效」，必须修。%s\n' "$C_FAIL" "$C_RESET"
        rm -rf "$tmp"
        return 2
    fi
    printf '  %s结论: 全部判据在注入故障后都正确报警。%s\n' "$C_OK" "$C_RESET"
    rm -rf "$tmp"
    return 0
}

if [[ "$HC_SELF_TEST" == "1" ]]; then
    hc_run_self_test
    exit $?
fi

exit "$EXIT_CODE"
