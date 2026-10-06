#!/usr/bin/env bash
# ============================================================================
# KnowTrace-Workflow 安全与访问只读检查
# ============================================================================
#
# 对应文档：
#   docs/日常运维/2026-09-20-运维回顾与遗漏事项补缺.md（第 2 节「安全与访问」）
#   docs/KnowTrace-Workflow-VPS-部署学习-2026-09-06/阶段一/问题记录/INC-001-UFW未启用.md
#   docs/日常运维/日常运维清单.md（安全与访问）
#
# 设计原则（沿用运维记录原则）：
#   1. 只读。不修改 SSH、防火墙、服务配置，不重载任何服务。
#   2. 不打印任何密钥值。仅检查 .env 中关键项「是否存在、是否为默认占位值」。
#   3. 不输出完整 .env 内容，不把任何敏感值写进报告。
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
KnowTrace-Workflow 安全与访问只读检查

用法:
  ./scripts/security-check.sh [选项]

选项:
  --conf <文件>   指定 ops.conf
  --json <文件>   写出 JSON 报告
  --no-json       不写 JSON 报告
  --quiet, -q     只输出 WARN/FAIL
  --no-color      关闭彩色输出
  --help, -h      显示本帮助

说明:
  本脚本是只读检查，不会修改 SSH、防火墙或任何服务配置。
  报告与屏幕输出中都不会包含密码、Token、Cookie 或 .env 明细。

退出码:
  0 未发现异常   1 存在 WARN   2 存在 FAIL
EOF
}

ops_parse_common_args "$@"
[[ "${OPS_SHOW_HELP:-0}" == "1" ]] && { usage; exit 0; }
if (( ${#OPS_REMAINING_ARGS[@]} > 0 )); then
    printf '未知参数: %s\n\n' "${OPS_REMAINING_ARGS[*]}" >&2
    usage >&2
    exit 3
fi

ops_require_cmds date hostname awk sed grep stat find
ops_load_conf

# ----------------------------------------------------------------------------
# 配置
# ----------------------------------------------------------------------------
PROJECT_DIR="$(ops_conf_get PROJECT_DIR /opt/knowtrace)"
ENV_FILE="$(ops_conf_get ENV_FILE "$PROJECT_DIR/.env")"
OBSERVABILITY_ENV_FILE="$(ops_conf_get OBSERVABILITY_ENV_FILE "$PROJECT_DIR/.env.observability")"
BACKUP_ROOT="$(ops_conf_get BACKUP_ROOT /var/backups/knowtrace)"
SSHD_CONFIG="$(ops_conf_get SSHD_CONFIG /etc/ssh/sshd_config)"
NGINX_ACCESS_LOG="$(ops_conf_get NGINX_ACCESS_LOG /var/log/nginx/knowtrace.access.log)"
NGINX_ERROR_LOG="$(ops_conf_get NGINX_ERROR_LOG /var/log/nginx/knowtrace.error.log)"
CADDY_ACCESS_LOG="$(ops_conf_get CADDY_ACCESS_LOG /var/log/caddy/knowtrace-access.log)"
FAILED_LOGIN_WINDOW_HOURS="$(ops_conf_int FAILED_LOGIN_WINDOW_HOURS 24)"
THRESH_FAILED_LOGIN_WARN="$(ops_conf_int THRESHOLD_FAILED_LOGIN_WARN 20)"
THRESH_FAILED_LOGIN_FAIL="$(ops_conf_int THRESHOLD_FAILED_LOGIN_FAIL 100)"
MANAGED_PORTS="$(ops_conf_get MANAGED_PORTS '9090 3001 9093 9200 5601 5000')"
PUBLIC_PORTS_ALLOWED="$(ops_conf_get PUBLIC_PORTS_ALLOWED '80 443 22345')"

is_root=0
[[ "${EUID:-$(id -u 2>/dev/null || printf '1')}" == "0" ]] && is_root=1

# 只读地读取 sshd 有效配置（sshd -T 需要 root；失败时不尝试提权）
sshd_effective() {
    [[ "$is_root" == "1" ]] || return 1
    ops_have_cmd sshd || return 1
    sshd -T 2>/dev/null
}

# 判断某个 .env 键存在且不是明显的默认/占位值。绝不返回值本身。
env_key_state() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || { printf 'nofile'; return 0; }

    local line value
    line="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=//p" "$file" 2>/dev/null | head -n 1 || printf '')"
    if [[ -z "$line" ]]; then
        printf 'missing'
        return 0
    fi

    value="$line"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if (( ${#value} >= 2 )) && [[ "${value:0:1}" == "${value: -1}" ]] \
        && [[ "${value:0:1}" == '"' || "${value:0:1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
    fi

    if [[ -z "$value" ]]; then
        printf 'empty'
    elif [[ "$value" == change-me* || "$value" == CHANGEME* || "$value" == example* \
        || "$value" == '<'* || "$value" == 'your-'* || "$value" == 'replace'* \
        || "$value" == 'KnowTrace-Workflow@123' || "$value" == 'password' || "$value" == 'admin' ]]; then
        printf 'placeholder'
    else
        printf 'set'
    fi
    return 0
}

# ============================================================================
ops_section "KnowTrace-Workflow 安全与访问只读检查  主机=$OPS_HOSTNAME"
printf '检查时间(UTC): %s\n' "$OPS_RUN_UTC"
printf '权限级别: %s\n' "$([[ "$is_root" == "1" ]] && printf 'root（可读取完整 sshd/ufw/journal 输出）' || printf '普通用户（部分检查需要 sudo 才能获得完整输出）')"
printf '保证: 本脚本不修改任何配置，也不输出任何密钥明文。\n'

# ----------------------------------------------------------------------------
# 1. SSH 服务端配置
# ----------------------------------------------------------------------------
ops_section "1. SSH 服务端配置"

if ! ops_have_cmd sshd && [[ ! -f "$SSHD_CONFIG" ]]; then
    ops_info "ssh.sshd" "未找到 sshd 与配置文件，跳过"
else
    effective="$(sshd_effective || printf '')"

    if [[ -n "$effective" ]]; then
        # 注意 sshd -T 输出的键名是小写
        pubkey="$(printf '%s\n' "$effective" | awk '$1=="pubkeyauthentication" {print $2}' | head -n 1)"
        passwordauth="$(printf '%s\n' "$effective" | awk '$1=="passwordauthentication" {print $2}' | head -n 1)"
        kbdinteractive="$(printf '%s\n' "$effective" | awk '$1=="kbdinteractiveauthentication" {print $2}' | head -n 1)"
        permitroot="$(printf '%s\n' "$effective" | awk '$1=="permitrootlogin" {print $2}' | head -n 1)"
        usedns="$(printf '%s\n' "$effective" | awk '$1=="usedns" {print $2}' | head -n 1)"
        gssapi="$(printf '%s\n' "$effective" | awk '$1=="gssapiauthentication" {print $2}' | head -n 1)"
        maxauth="$(printf '%s\n' "$effective" | awk '$1=="maxauthtries" {print $2}' | head -n 1)"

        if [[ "$passwordauth" == "yes" ]]; then
            ops_fail "ssh.password-authentication" "密码登录已开启，不符合「只用密钥登录」"
        elif [[ "$passwordauth" == "no" ]]; then
            ops_ok "ssh.password-authentication" "密码登录已关闭"
        else
            ops_info "ssh.password-authentication" "未读取到 passwordauthentication 值"
        fi

        if [[ "$pubkey" == "yes" ]]; then
            ops_ok "ssh.pubkey-authentication" "公钥登录已开启"
        elif [[ -n "$pubkey" ]]; then
            ops_fail "ssh.pubkey-authentication" "公钥登录为 $pubkey，可能导致无法登录"
        fi

        if [[ "$kbdinteractive" == "yes" ]]; then
            ops_warn "ssh.kbd-interactive" "KbdInteractiveAuthentication=yes，可能允许密码类交互认证"
        elif [[ "$kbdinteractive" == "no" ]]; then
            ops_ok "ssh.kbd-interactive" "交互式认证已关闭"
        fi

        case "$permitroot" in
            no)                       ops_ok   "ssh.permit-root-login" "禁止 root 直接登录" ;;
            prohibit-password|forced-commands-only) ops_ok "ssh.permit-root-login" "$permitroot（仅密钥）" ;;
            yes)                      ops_fail "ssh.permit-root-login" "允许 root 直接登录" ;;
            *)                        ops_info "ssh.permit-root-login" "值: ${permitroot:-unknown}" ;;
        esac

        # UseDNS=yes 与 GSSAPIAuthentication=yes 是「登录慢」的常见原因
        # （docs/日常运维 中记录过 Xshell 访问慢的问题）
        if [[ "$usedns" == "yes" ]]; then
            ops_warn "ssh.use-dns" "UseDNS=yes，反向解析可能造成登录缓慢"
        elif [[ "$usedns" == "no" ]]; then
            ops_ok "ssh.use-dns" "UseDNS=no"
        fi

        if [[ "$gssapi" == "yes" ]]; then
            ops_warn "ssh.gssapi" "GSSAPIAuthentication=yes，可能造成登录等待"
        elif [[ "$gssapi" == "no" ]]; then
            ops_ok "ssh.gssapi" "GSSAPI 认证已关闭"
        fi

        if [[ "$maxauth" =~ ^[0-9]+$ ]] && (( maxauth > 6 )); then
            ops_info "ssh.max-auth-tries" "MaxAuthTries=$maxauth（偏大）"
        elif [[ -n "$maxauth" ]]; then
            ops_ok "ssh.max-auth-tries" "MaxAuthTries=$maxauth"
        fi
    else
        ops_info "ssh.effective-config" "无法读取 sshd 有效配置（需要 root）。请用 sudo 重跑以获得完整判断。"

        # 退回静态文件检查：只在没有 root 时使用
        if [[ -r "$SSHD_CONFIG" ]]; then
            if grep -Eiq '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' "$SSHD_CONFIG" 2>/dev/null; then
                ops_warn "ssh.password-authentication" "$SSHD_CONFIG 中显式开启了密码登录（未考虑 sshd_config.d 覆盖，结论待确认）"
            else
                ops_info "ssh.password-authentication" "静态文件未见 PasswordAuthentication yes（需 sudo 才能给出确定结论）"
            fi
        fi
    fi
fi

# 授权密钥文件权限：authorized_keys 必须不可被同组/其他用户写入
if [[ -f /root/.ssh/authorized_keys ]]; then
    perms="$(stat -c %A /root/.ssh/authorized_keys 2>/dev/null || printf '')"
    if [[ "${perms:4:3}" == *w* || "${perms:7:3}" == *w* ]]; then
        ops_fail "ssh.authorized-keys-perms" "/root/.ssh/authorized_keys 允许同组或其他用户写入（$perms）"
    else
        ops_ok "ssh.authorized-keys-perms" "/root/.ssh/authorized_keys 权限正常（$perms）"
    fi
fi

# ----------------------------------------------------------------------------
# 2. 登录记录与失败尝试
# ----------------------------------------------------------------------------
ops_section "2. 登录记录与失败尝试（最近 ${FAILED_LOGIN_WINDOW_HOURS} 小时）"

if ops_have_cmd last; then
    if [[ "$OPS_QUIET" != "1" ]]; then
        printf '       --- last -a (最近 10 条) ---\n'
        last -a -n 10 2>/dev/null | ops_indent
    fi
fi

failed_count=0
failed_sources=""

if ops_have_cmd journalctl && [[ "$is_root" == "1" ]]; then
    window="${FAILED_LOGIN_WINDOW_HOURS} hours ago"
    failed_lines="$(journalctl --since "$window" --no-pager 2>/dev/null \
        | grep -Ei 'Failed password|authentication failure|Invalid user|Connection closed by authenticating user' \
        || printf '')"

    if [[ -n "$failed_lines" ]]; then
        failed_count="$(printf '%s\n' "$failed_lines" | ops_count_lines)"
        # 提取来源 IP，只保留去重后的前 10 个
        failed_sources="$(printf '%s\n' "$failed_lines" \
            | grep -oE 'from [0-9a-fA-F.:]+' | awk '{print $2}' \
            | sort | uniq -c | sort -rn | head -n 10 || printf '')"
    fi

    # 密码登录已关闭时，失败登录永远无法成功，属公开 IP 的背景噪音，最多 WARN 不 FAIL；
    # 只有密码登录开启时，失败登录才是真实威胁，达到 FAIL 阈值才报 FAIL。
    if [[ "${passwordauth:-}" == "no" ]]; then
        if (( failed_count >= THRESH_FAILED_LOGIN_WARN )); then
            ops_warn "ssh.failed-logins" "${FAILED_LOGIN_WINDOW_HOURS} 小时内 ${failed_count} 次失败登录（密码登录已关闭，无法成功，属背景噪音）"
        else
            ops_ok "ssh.failed-logins" "${FAILED_LOGIN_WINDOW_HOURS} 小时内失败登录 ${failed_count} 次"
        fi
    elif (( failed_count >= THRESH_FAILED_LOGIN_FAIL )); then
        ops_fail "ssh.failed-logins" "${FAILED_LOGIN_WINDOW_HOURS} 小时内 ${failed_count} 次失败登录，疑似暴力破解（密码登录开启，有真实风险）"
    elif (( failed_count >= THRESH_FAILED_LOGIN_WARN )); then
        ops_warn "ssh.failed-logins" "${FAILED_LOGIN_WINDOW_HOURS} 小时内 ${failed_count} 次失败登录，需要关注"
    else
        ops_ok "ssh.failed-logins" "${FAILED_LOGIN_WINDOW_HOURS} 小时内失败登录 ${failed_count} 次"
    fi

    if [[ -n "$failed_sources" ]]; then
        if [[ "$OPS_QUIET" != "1" ]]; then
            printf '       --- 失败登录来源 TOP（次数 + IP）---\n'
            printf '%s\n' "$failed_sources" | ops_indent
        fi
    fi

    # 成功登录也要留证：异常来源比失败次数更重要
    accepted="$(journalctl --since "$window" --no-pager 2>/dev/null \
        | grep -Ei 'Accepted (publickey|password)' | tail -n 10 || printf '')"
    if [[ -n "$accepted" ]]; then
        if [[ "$OPS_QUIET" != "1" ]]; then
            printf '       --- 最近成功登录 ---\n'
            printf '%s\n' "$accepted" | ops_indent
        fi
    fi
else
    ops_info "ssh.failed-logins" "需要 root + journalctl 才能统计失败登录（请用 sudo 重跑）"
fi

# ----------------------------------------------------------------------------
# 3. 公网监听与防火墙
# ----------------------------------------------------------------------------
ops_section "3. 公网监听与防火墙"

if ops_have_cmd ss; then
    listeners="$(ss -lntH 2>/dev/null | awk '{print $4}' | sort -u || printf '')"
    # ⚠ 排除的是**整个回环网段**，不是只有 127.0.0.1。
    #    2026-10-06 实测踩到：原正则只匹配 `127.0.0.1`，而 systemd-resolved
    #    正常绑定在 `127.0.0.53`（stub listener）与 `127.0.0.54` ——
    #    这两个**都在回环内**（RFC 1122：127.0.0.0/8 全段保留给回环），
    #    外部**根本连不上**（实测 `Connection refused`），却被判成「非本地监听」
    #    并让 weekly 每次都报一条 WARN。判据的假阳性会训练人忽略 WARN。
    #    匹配写法兼顾 ss 的几种输出形态：`127.0.0.53%lo:53`、`127.0.0.1:8080`、`[::1]:80`。
    non_local="$(printf '%s\n' "$listeners" \
        | grep -vE '^(127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\]|::1)[:%]' \
        | grep -v '^$' || printf '')"

    if [[ -n "$non_local" ]]; then
        ops_fact "非本地监听地址（需确认都在预期内）:"
        printf '%s\n' "$non_local" | ops_indent

        # 从监听地址里提取端口号，与本项目允许的公网端口比较
        listening_ports="$(printf '%s\n' "$non_local" | sed -E 's/.*[:.]([0-9]+)$/\1/' | sort -un | tr '\n' ' ')"
        unexpected=""
        for port in $listening_ports; do
            found=0
            for allowed in $PUBLIC_PORTS_ALLOWED; do
                [[ "$port" == "$allowed" ]] && found=1
            done
            (( found == 0 )) && unexpected="${unexpected}${port} "
        done

        if [[ -z "${unexpected// /}" ]]; then
            ops_ok "net.public-listeners" "全部公网监听端口都在允许清单内（$PUBLIC_PORTS_ALLOWED）"
        else
            ops_warn "net.public-listeners" "以下监听端口不在允许清单（$PUBLIC_PORTS_ALLOWED）内: ${unexpected% }"
        fi
    else
        ops_ok "net.public-listeners" "未发现非本地监听地址"
    fi

    # 管理端口（监控 / 日志 / 认证）绝不应绑定到非本地地址
    exposed_admin=""
    for port in $MANAGED_PORTS; do
        if printf '%s\n' "$non_local" | grep -qE "[:.]${port}$"; then
            exposed_admin="${exposed_admin}${port} "
        fi
    done
    if [[ -z "${exposed_admin// /}" ]]; then
        ops_ok "net.admin-ports" "管理端口（$MANAGED_PORTS）未暴露到公网"
    else
        ops_fail "net.admin-ports" "管理端口已暴露: ${exposed_admin% }（必须只绑定 127.0.0.1 并通过 SSH 隧道访问）"
    fi
else
    ops_info "net.listeners" "ss 不可用，跳过端口检查"
fi

if ops_have_cmd ufw; then
    ufw_status="$(ufw status verbose 2>/dev/null || printf '')"
    if [[ -n "$ufw_status" ]]; then
        if [[ "$OPS_QUIET" != "1" ]]; then
            printf '       --- ufw status verbose ---\n'
            printf '%s\n' "$ufw_status" | ops_indent
        fi
        if printf '%s\n' "$ufw_status" | head -n 1 | grep -qi 'Status: active'; then
            ops_ok "net.ufw" "UFW active"
        else
            ops_fail "net.ufw" "UFW 未启用（阶段一 INC-001 曾出现该问题）"
        fi
    else
        ops_info "net.ufw" "无法读取 ufw 状态（需要 root）"
    fi
else
    ops_info "net.ufw" "未安装 ufw"
fi

# ----------------------------------------------------------------------------
# 4. 密钥与环境变量文件（只检查状态，不输出值）
# ----------------------------------------------------------------------------
ops_section "4. 密钥文件状态（不输出任何值）"

check_env_file() {
    local file="$1" label="$2"
    if [[ ! -f "$file" ]]; then
        ops_info "env.$label" "文件不存在: $file"
        return 0
    fi

    if ops_is_group_or_other_readable "$file"; then
        ops_fail "env.$label-perms" "$file 对同组或其他用户可读，必须收紧为 0600"
    else
        ops_ok "env.$label-perms" "$file 权限已收紧"
    fi

    if [[ "$is_root" == "1" ]]; then
        local count
        count="$(ops_count_lines "$file")"
        ops_info "env.$label-keys" "包含 ${count} 个配置项（未读取、未输出任何值）"
    fi
}

check_env_file "$ENV_FILE" "main"
check_env_file "$OBSERVABILITY_ENV_FILE" "observability"

# 关键密钥项：只判断「是否仍为默认占位值」或「缺失」，绝不打印值本身
if [[ -f "$ENV_FILE" ]]; then
    for key in MYSQL_ROOT_PASSWORD JWT_SECRET AUTH_COOKIE_SECRET METRICS_BEARER_TOKEN; do
        state="$(env_key_state "$ENV_FILE" "$key")"
        case "$state" in
            set)         ops_ok "env.key.$key" "已设置（值未读取、未输出）" ;;
            placeholder) ops_fail "env.key.$key" "仍是默认/占位值，生产环境必须更换" ;;
            empty)       ops_fail "env.key.$key" "为空" ;;
            missing)     ops_info "env.key.$key" "未在该文件中出现（可能由其他机制注入）" ;;
            nofile)      ops_info "env.key.$key" "配置文件不存在" ;;
        esac
    done

    # 生产环境必须开启安全 Cookie
    secure_state="$(env_key_state "$ENV_FILE" AUTH_COOKIE_SECURE)"
    case "$secure_state" in
        set)
            if sed -n 's/^[[:space:]]*AUTH_COOKIE_SECURE[[:space:]]*=[[:space:]]*//p' "$ENV_FILE" 2>/dev/null | head -n 1 | grep -qi '^true'; then
                ops_ok "env.auth-cookie-secure" "AUTH_COOKIE_SECURE=true"
            else
                ops_fail "env.auth-cookie-secure" "HTTPS 部署下 AUTH_COOKIE_SECURE 必须为 true"
            fi
            ;;
        missing)  ops_warn "env.auth-cookie-secure" "未显式设置 AUTH_COOKIE_SECURE，HTTPS 下应设为 true" ;;
        *)        ops_warn "env.auth-cookie-secure" "AUTH_COOKIE_SECURE 状态异常，请人工确认" ;;
    esac

    # 初始化默认管理员口令仍留在 .env 是已知设计，但生产环境应确认已修改
    ops_info "env.default-admin" "默认管理员 KnowTrace-Workflow / KnowTrace-Workflow@123 只用于首次本机登录；请在数据库侧确认密码已修改"
elif [[ "$is_root" != "1" && -f "$ENV_FILE" ]]; then
    ops_info "env.key-check" "需要 root 才能读取 .env 内容（请用 sudo 重跑）"
else
    ops_warn "env.main" "主配置文件不存在: $ENV_FILE"
fi

# ----------------------------------------------------------------------------
# 5. 边缘代理异常请求
# ----------------------------------------------------------------------------
ops_section "5. 边缘代理请求异常（访问日志尾部抽样）"

check_access_log() {
    local log="$1" label="$2"
    [[ -f "$log" ]] || { ops_info "http.$label-access" "日志不存在: $log"; return 0; }

    if ! [[ -r "$log" ]]; then
        ops_info "http.$label-access" "无权读取 $log（请用 sudo 重跑）"
        return 0
    fi

    local tail_lines total errors
    tail_lines="$(tail -n 2000 "$log" 2>/dev/null || printf '')"
    total="$(printf '%s\n' "$tail_lines" | ops_count_lines)"

    # 统计 4xx / 5xx；日志格式不同，这里用宽松的「状态码字段」匹配
    errors="$(printf '%s\n' "$tail_lines" | grep -cE '" (4[0-9]{2}|5[0-9]{2}) ' 2>/dev/null; true)"

    if (( total == 0 )); then
        ops_info "http.$label-access" "$log 为空"
        return 0
    fi

    local ratio; ratio="$(ops_int_div "$(( errors * 100 ))" "$total")"
    local detail="最近 ${total} 条请求中 ${errors} 条为 4xx/5xx（${ratio}%）"

    if (( ratio >= 50 )); then
        ops_fail "http.$label-access" "$detail，异常比例过高"
    elif (( ratio >= 20 )); then
        ops_warn "http.$label-access" "$detail"
    else
        ops_ok "http.$label-access" "$detail"
    fi

    # 记录状态码分布，便于判断是正常 404 还是大面积 5xx
    if [[ "$OPS_QUIET" != "1" ]]; then
        printf '       --- %s 状态码分布 ---\n' "$label"
        printf '%s\n' "$tail_lines" \
            | grep -oE '" [0-9]{3} ' | awk '{print $2}' \
            | sort | uniq -c | sort -rn | head -n 10 | ops_indent
    fi
    return 0
}

check_access_log "$NGINX_ACCESS_LOG" "nginx"
check_access_log "$CADDY_ACCESS_LOG" "caddy"

for log in "$NGINX_ERROR_LOG"; do
    if [[ -f "$log" && -r "$log" ]]; then
        recent_errors="$(tail -n 200 "$log" 2>/dev/null | grep -Ei 'error|crit|alert|emerg' | wc -l | tr -d ' ')"
        [[ "$recent_errors" =~ ^[0-9]+$ ]] || recent_errors=0
        if (( recent_errors > 0 )); then
            ops_warn "http.nginx-error" "$log 尾部 200 行中有 ${recent_errors} 条错误级日志"
        else
            ops_ok "http.nginx-error" "$log 尾部未见错误级日志"
        fi
    fi
done

# ----------------------------------------------------------------------------
# 6. Docker 端口暴露与权限
# ----------------------------------------------------------------------------
ops_section "6. Docker 端口暴露"

if ops_have_cmd docker && docker ps >/dev/null 2>&1; then
    port_map="$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null || printf '')"
    if [[ -n "$port_map" ]]; then
        # 0.0.0.0:PORT-> 或 :::PORT-> 表示绑定到所有网卡 = 公网可达
        wide_open="$(printf '%s\n' "$port_map" \
            | grep -E '(0\.0\.0\.0|\[::\]|::):[0-9]+->' || printf '')"
        if [[ -n "$wide_open" ]]; then
            ops_fail "docker.port-bindings" "以下容器端口绑定到所有网卡（应对 127.0.0.1 绑定）:"
            if [[ "$OPS_QUIET" != "1" ]]; then
                printf '%s\n' "$wide_open" | ops_indent
            fi
        else
            ops_ok "docker.port-bindings" "未发现绑定到所有网卡的容器端口"
        fi
    fi

    # 容器内以 root 运行属于信息项，不是结论
    if [[ "$OPS_QUIET" != "1" ]]; then
        printf '       --- 容器用户（root 运行仅为事实记录）---\n'
        docker ps --format '{{.Names}}' 2>/dev/null | while IFS= read -r c; do
            [[ -n "$c" ]] || continue
            u="$(docker inspect --format '{{.Config.User}}' "$c" 2>/dev/null || printf '')"
            printf '%s: %s\n' "$c" "${u:-默认(root)}"
        done | ops_indent
    fi
else
    ops_info "docker.port-bindings" "docker 不可用或无权访问，跳过"
fi

# ----------------------------------------------------------------------------
# 7. 备份目录权限与完整性姿态
# ----------------------------------------------------------------------------
ops_section "7. 备份目录权限"

if [[ -d "$BACKUP_ROOT" ]]; then
    perms="$(stat -c %A "$BACKUP_ROOT" 2>/dev/null || printf '')"
    if [[ "${perms:4:3}" == *r* || "${perms:7:3}" == *r* || "${perms:4:3}" == *x* || "${perms:7:3}" == *x* ]]; then
        ops_warn "backup.dir-perms" "$BACKUP_ROOT 对同组或其他用户可访问（$perms），建议 0700"
    else
        ops_ok "backup.dir-perms" "$BACKUP_ROOT 权限已收紧（$perms）"
    fi

    loose="$(find "$BACKUP_ROOT" -maxdepth 1 -type f -name 'knowtrace-*' 2>/dev/null \
        | while IFS= read -r f; do
            ops_is_group_or_other_readable "$f" && printf '%s\n' "$f"
        done | head -n 10 || printf '')"
    if [[ -n "$loose" ]]; then
        ops_warn "backup.file-perms" "存在对同组或其他用户可读的备份文件（含账号哈希与会话元数据），建议 0600"
    else
        ops_ok "backup.file-perms" "备份文件权限已收紧"
    fi
else
    ops_info "backup.dir-perms" "备份目录不存在: $BACKUP_ROOT"
fi

# ----------------------------------------------------------------------------
# 8. 入侵防护组件
# ----------------------------------------------------------------------------
ops_section "8. 可选加固组件"

if ops_have_cmd fail2ban-client; then
    if fail2ban-client status >/dev/null 2>&1; then
        ops_info "security.fail2ban" "fail2ban 运行中"
        if [[ "$OPS_QUIET" != "1" ]]; then
            fail2ban-client status sshd 2>/dev/null | ops_indent || true
        fi
    else
        ops_info "security.fail2ban" "已安装但未运行或无权限读取状态"
    fi
else
    ops_info "security.fail2ban" "未安装 fail2ban（可选加固项，本项目当前未使用）"
fi

# ----------------------------------------------------------------------------
# 自动安全修补（unattended-upgrades）
# ----------------------------------------------------------------------------
# 2026-10-06 之前这里是一条**空转判据**：只把 `20auto-upgrades` 的内容打印成 INFO，
# **从不断言任何东西**。配置文件在 → 永远记 INFO，哪怕定时器停了、服务关了、
# 或者它每次启动就崩，日报看起来一模一样。
#
# 这正是本项目反复吃亏的形状（`KT-GAP-28` 孤儿指标、`KT-GAP-35` ProtectHome、
# `KT-GAP-40` fail2ban 端口）：**判据的输入坏了，而输出看起来只是「一切正常」**。
#
# 改成真断言，且**区分四种结果** —— 因为「没有可升级的包」是**合法的**结果，
# 不能与「它根本没跑」混为一谈：
#   定时器未启用          → FAIL（不会再自动修补了）
#   日志文件不存在        → FAIL（从没跑过）
#   日志陈旧（> 阈值）    → WARN（调度停了）
#   日志有启动但无结论行  → WARN（每次启动就退出，没走到结论）
#   以上都不成立          → OK（附「最近一次实际升级了多少包」）
#
# 判据的**边界（明说）**：它证明「它按调度在跑、且能跑到结论」，
# **不证明「当前有 security 更新时它一定会装上」** —— 那需要一个真实的安全更新来验，
# 不能人工造（本项目不制造假的自然事件）。
if ops_have_cmd systemctl && systemctl list-unit-files unattended-upgrades.service >/dev/null 2>&1; then
    THRESH_AUTO_UPGRADE_STALE_HOURS="$(ops_conf_int THRESHOLD_AUTO_UPGRADE_STALE_HOURS 48)"
    auto_log="/var/log/unattended-upgrades/unattended-upgrades.log"
    auto_timer="apt-daily-upgrade.timer"

    if [[ "$(systemctl is-enabled "$auto_timer" 2>/dev/null || printf 'unknown')" != "enabled" ]]; then
        ops_fail "security.auto-upgrades" "自动安全修补的定时器 $auto_timer 未启用 —— 不会再自动装安全更新"
    elif [[ ! -f "$auto_log" ]]; then
        ops_fail "security.auto-upgrades" "找不到 $auto_log —— unattended-upgrades 从未运行过"
    else
        auto_age="$(ops_age_hours "$(ops_mtime "$auto_log")")"
        auto_starts="$(grep -cF 'Starting unattended upgrades script' "$auto_log" 2>/dev/null || printf 0)"
        # 两种「跑到结论」的形态：有包要升 / 没有可升的包
        auto_concl="$(grep -cE 'Packages that will be upgraded:|No packages found that can be upgraded unattended' "$auto_log" 2>/dev/null || printf 0)"
        [[ "$auto_starts" =~ ^[0-9]+$ ]] || auto_starts=0
        [[ "$auto_concl" =~ ^[0-9]+$ ]] || auto_concl=0

        if [[ "$auto_age" == "unknown" ]]; then
            ops_warn "security.auto-upgrades" "读到 $auto_log 但取不到时间戳，无法判断新鲜度"
        elif awk -v a="$auto_age" -v t="$THRESH_AUTO_UPGRADE_STALE_HOURS" 'BEGIN{exit !(a > t)}'; then
            ops_warn "security.auto-upgrades" "$auto_timer 已启用，但日志 ${auto_age} 小时未更新（阈值 ${THRESH_AUTO_UPGRADE_STALE_HOURS}h）—— 调度可能停了"
        elif (( auto_starts == 0 )); then
            ops_warn "security.auto-upgrades" "日志里没有一次「Starting」记录 —— 单元可能启动即失败"
        elif (( auto_concl == 0 )); then
            ops_warn "security.auto-upgrades" "日志有 $auto_starts 次启动，但没有一行结论（既没说有包要升、也没说没有可升的）—— 每次都提前退出了"
        else
            last_upgrade="$(grep -E 'Packages that will be upgraded:' "$auto_log" 2>/dev/null | tail -1 || printf '')"
            if [[ -n "$last_upgrade" ]]; then
                ops_ok "security.auto-upgrades" "$auto_timer 已启用，日志 ${auto_age} 小时前更新；最近一次实际升级过包"
            else
                ops_ok "security.auto-upgrades" "$auto_timer 已启用，日志 ${auto_age} 小时前更新；至今没有需要自动升级的包"
            fi
        fi
    fi
fi

# ----------------------------------------------------------------------------
# 结论
# ----------------------------------------------------------------------------
ops_section "安全只读检查结束"

ops_fact "本脚本只做只读检查，未修改 SSH、防火墙或任何服务配置。"
ops_fact "本次结论只代表执行时刻；未实际验证的内容不会被写成「已通过」。"
ops_fact "如需变更配置，请先在 docs/日常运维/ 中记录原值、修改值、重载命令和回滚方法。"

ops_finish "security-check" "KnowTrace-Workflow 安全与访问只读检查"
