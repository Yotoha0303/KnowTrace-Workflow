#!/usr/bin/env bash
set -Eeuo pipefail
# ============================================================================
# KnowTrace-Workflow 从零安装入口（Linux，bash）
# ============================================================================
#
# 这个脚本解决的是**鸡生蛋**问题：
#   `scripts/bootstrap/bootstrap.sh` 能一条命令跑完 host→apps→monitoring→ops→verify，
#   但它自己在仓库里 —— 要跑它得先有仓库，要拿仓库得先 git clone，
#   而"装系统依赖 + clone"本身也该由脚本做。
#   所以在仓库**之外**需要一个入口。这个文件就是它。
#
# 用法（新机器上，root）：
#
#   # 方式一：先 clone 再执行（可审计，推荐）
#   git clone https://github.com/Yotoha0303/KnowTrace-Workflow.git /opt/knowtrace
#   sudo bash /opt/knowtrace/scripts/install.sh --domain knowtrace.example.org
#
#   # 方式二：一条命令（不先 clone）
#   curl -fsSL https://raw.githubusercontent.com/Yotoha0303/KnowTrace-Workflow/refs/heads/main/scripts/install.sh \
#     | sudo bash -s -- --domain knowtrace.example.org
#
# 它做四件事，然后交给 bootstrap：
#   1) 装系统依赖（apt）
#   2) clone / 更新仓库
#   3) 建 external 数据卷（bootstrap 的 host 阶段也会做，这里是双保险）
#   4) 若给了 --domain，写 /etc/caddy/Caddyfile 并起 Caddy
#   5) exec bootstrap.sh --all
#
# **刻意不做**（与 bootstrap 的边界一致，理由见 docs/changes/2026-10-02 各篇）：
#   * UFW / sshd 加固 —— 自锁风险：`ufw enable` 前未放行 SSH 端口会立即失联，
#     且无法从远程改回。脚本绝不代做，只在最后打印命令。
#   * 异地备份 / 告警邮箱 / AI key —— 需要外部凭据，属人工输入。
#
# 退出码: 0 成功  1 失败  3 参数或环境错误
# ============================================================================

REPO_URL="https://github.com/Yotoha0303/KnowTrace-Workflow.git"
REPO_REF="main"
TARGET_DIR="/opt/knowtrace"
DOMAIN=""
SKIP_DEPS=false
ASSUME_YES=false
DRY_RUN=false
RECORD_FILE=""

usage() {
  # 为什么内嵌而不是 `sed -n` 读 $0：
  #   `curl … | bash -s --` 这种调用下**没有脚本文件可读**（$0 是 "bash"），
  #   原写法会让 --help 直接报 `sed: can't read …`（2026-10-02 实测踩到）。
  #   这条正是本脚本的头号用法，所以必须内嵌。
  cat <<'USAGE'
KnowTrace-Workflow 从零安装入口（Linux，root）

用法：
  git clone <repo> /opt/knowtrace && sudo bash /opt/knowtrace/scripts/install.sh [选项]
  curl -fsSL <raw-url>/scripts/install.sh | sudo bash -s -- [选项]

选项：
  --domain <域名>   写 /etc/caddy/Caddyfile 并让 Caddy 自动签证书（强烈建议给）
  --repo <url>      仓库地址（默认官方仓库）
  --ref <分支>      分支或 tag（默认 main）
  --dir <路径>      安装目录（默认 /opt/knowtrace）
  --skip-deps       跳过 apt 装包（依赖已就绪时用）
  --yes             自动确认（bootstrap 询问「已有部署是否继续」时）
  --dry-run         只打印将做什么，不修改任何东西
  --record <文件>   把每一步追加写入该文件（重建演练用，透传给 bootstrap）
  --help, -h        显示本帮助

它做的事：装依赖 → clone/更新仓库 → 建 external 数据卷 → 写 Caddyfile
           → 交给 scripts/bootstrap/bootstrap.sh --all
（bootstrap 负责：host → apps → monitoring → ops → verify，含镜像构建）

刻意不做（自锁风险或需外部凭据，只在结束时打印命令）：
  UFW 防火墙、sshd 加固、异地备份后端、告警邮箱、AI key
USAGE
  exit "${1:-0}"
}

while (( $# )); do
  case "$1" in
    --repo)      REPO_URL="${2:?--repo 需要值}"; shift 2 ;;
    --ref)       REPO_REF="${2:?--ref 需要值}"; shift 2 ;;
    --dir)       TARGET_DIR="${2:?--dir 需要值}"; shift 2 ;;
    --domain)    DOMAIN="${2:?--domain 需要值}"; shift 2 ;;
    --skip-deps) SKIP_DEPS=true; shift ;;
    --yes)       ASSUME_YES=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --record)    RECORD_FILE="${2:?--record 需要值}"; shift 2 ;;
    --help|-h)   usage 0 ;;
    *) echo "错误：未知参数 $1" >&2; usage 3 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '  [ OK ] %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*" >&2; }
die()  { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

run() {
  if [[ "$DRY_RUN" == true ]]; then printf '    (dry-run) %s\n' "$*"; else "$@"; fi
}

# 不依赖调用者的工作目录：`curl … | bash` 时 cwd 是任意的，而调用者所在目录
# 可能已被删除（实测：清理脚本 cd 进去后又 rm -rf 它，随后 git 报
# `fatal: Unable to read current working directory`）。本脚本全程用绝对路径，
# 先切到一个必然存在的目录即可。
cd / 2>/dev/null || true

if (( EUID != 0 )); then
  # 用 sudo 重启自己：注意要原样带上所有参数（包括 --yes / --dry-run）。
  #
  # 边界：`curl … | bash -s --` 这种调用下 $0 是 "bash" 而不是文件路径，
  # 再 exec sudo -- bash 会从已被读完的 stdin 里找脚本，失败得很困惑。
  # 所以这里显式拦一下，给出可直接照抄的写法。
  if [[ ! -f "$0" ]]; then
    printf '  [FAIL] 需要 root，且当前不是通过文件调用（$0=%s）。
' "$0" >&2
    printf '         改为：curl -fsSL <url>/scripts/install.sh | sudo bash -s -- <参数>
' >&2
    printf '         或先 clone 再：sudo bash scripts/install.sh <参数>
' >&2
    exit 3
  fi
  exec sudo -- "$0" "$@"
fi

# ---------------------------------------------------------------------------
step "环境识别"
# 只支持 Debian 系：apt 与包名都按它写。其它发行版**明确拒绝**，
# 而不是"试试看"—— 免得装到一半失败留下半成品。
if [[ ! -r /etc/os-release ]]; then
  die "读不到 /etc/os-release，无法识别发行版"
fi
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ok "OS: ${PRETTY_NAME:-unknown}" ;;
  *) die "只支持 Ubuntu / Debian（当前 ID=${ID:-unknown}）。其它发行版请照 docs/KnowTrace-Workflow-VPS-部署学习-2026-09-06/ 手工部署" ;;
esac
info "仓库 : $REPO_URL ($REPO_REF)"
info "目录 : $TARGET_DIR"
[[ -n "$DOMAIN" ]] && info "域名 : $DOMAIN（将写 Caddyfile）" || info "域名 : 未指定 → 跳过 Caddy 配置（之后可手工配）"

# 内存提示：构建吃内存，2 GB 机器在**已部署**状态下容易失败
mem_avail_kib="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_avail_mib=$(( mem_avail_kib / 1024 ))
info "可用内存: ${mem_avail_mib} MiB"
if (( mem_avail_mib < 700 )); then
  warn "可用内存不足 700 MiB —— 后续 docker build 可能失败（2026-09-30 曾把整机压死）"
  warn "若装完后失败：先在别处构建镜像再 docker save/load，或临时加 swap，或换更大机器"
fi

# ---------------------------------------------------------------------------
step "系统依赖"
# 清单依据（两个来源，不是猜的）：
#   * scripts/bootstrap/lib/preflight.sh 声明的必需命令
#   * docs/KnowTrace-Workflow-VPS-部署学习-2026-09-06/阶段一/文档/04-…教程.md §5
# 其中 jq 与 flock 是**必需**而非可选：巡检脚本里有 26 处 jq 调用，
# 缺了不是"少个功能"，是**静默产出空字段的报告**（调用点带 2>/dev/null）。
# 注意 jq 在 Ubuntu 上可能因 fwupd 依赖碰巧存在，不能指望。
# openssl 与 python3 是**硬要求**，不是"有就用"：
#   scripts/linux/init-env.sh:58-59  `command -v python3 || exit 3`（同理 openssl）
#   scripts/linux/write-ops-metrics.sh:49 同样硬要求 python3
#   scripts/bootstrap/lib/preflight.sh    把 openssl / python3 列为必需命令
# 它们在 Ubuntu 上常因基础包或依赖**碰巧存在**（实测这台机上 openssl 是 fwupd 的
# auto 依赖、python3 来自 python3-minimal），所以"本机能跑"不等于"下一台也能"。
# 2026-10-02 写本脚本时正是漏了这两个 —— 补上。
# （tar / sha256sum / find 等属 Ubuntu essential 或 coreutils，必然存在，不列。）
# 与 deploy/ansible/group_vars/all.yml 的 baseline_packages 一一对应（改一处、另一处同步）。
# unattended-upgrades 这里只装包；**配置**（20auto-upgrades）由 Ansible roles/baseline 负责。
DEPS=(docker.io docker-compose-v2 nginx caddy rclone age fail2ban git curl ca-certificates jq util-linux openssl python3 unattended-upgrades)
if [[ "$SKIP_DEPS" == true ]]; then
  info "已按 --skip-deps 跳过"
else
  if [[ "$DRY_RUN" == true ]]; then
    printf '    (dry-run) apt-get -o DPkg::Lock::Timeout=900 update && install -y %s\n' "${DEPS[*]}"
  else
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

    # dpkg 锁：新装 Ubuntu 开机后 unattended-upgrades 会申请 /var/lib/dpkg/lock-frontend，
    # 此时 apt-get install 会**立刻失败**（退出码 100）。
    # 2026-10-02 裸机演练实测踩到，而本机当时有 **329 个包**待升级 ——
    # 它 download-only 阶段会占锁数分钟。已部署的机器遇不到（早过了开机窗口）。
    #
    # 所以：先告诉用户在等谁（免得以为卡死），再用 apt 自带的锁等待选项等它。
    # 超时给 15 分钟：2 vCPU 上下载 329 个包通常几分钟，留足余量胜过中途失败。
    if command -v fuser >/dev/null 2>&1 && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
      holder="$(fuser -v /var/lib/dpkg/lock-frontend 2>&1 | awk 'NR>2 && $0 ~ /[0-9]/ {print $1" (pid "$2")"; exit}')"
      warn "dpkg 锁被占用${holder:+：$holder}"
      info "新装系统开机后常由 unattended-upgrades 触发（可能它在下载大量安全更新）。"
      info "本步骤会等待，最多 15 分钟；不需要你干预。"
    fi

    APT_LOCK_OPT=(-o DPkg::Lock::Timeout=900)
    apt-get "${APT_LOCK_OPT[@]}" update -qq
    apt-get "${APT_LOCK_OPT[@]}" install -y -qq "${DEPS[@]}" >/dev/null
    ok "已安装：${DEPS[*]}"
  fi
fi

# ---------------------------------------------------------------------------
step "仓库"
if [[ -d "$TARGET_DIR/.git" ]]; then
  info "已存在检出，尝试快进更新"
  # 未跟踪文件会挡住 pull（2026-10-01 踩过）；这里只提示，不擅自删。
  run git -C "$TARGET_DIR" fetch --quiet origin "$REPO_REF"
  if ! git -C "$TARGET_DIR" diff --quiet HEAD "origin/$REPO_REF" -- 2>/dev/null; then
    dirty="$(git -C "$TARGET_DIR" status --porcelain | wc -l)"
    (( dirty > 0 )) && warn "本地有 $dirty 项改动，pull 可能被挡住 —— 先确认再继续"
  fi
  run git -C "$TARGET_DIR" checkout "$REPO_REF" 2>/dev/null || true
  run git -C "$TARGET_DIR" pull --ff-only
else
  run install -d -m 755 "$(dirname "$TARGET_DIR")"
  run git clone --quiet --branch "$REPO_REF" "$REPO_URL" "$TARGET_DIR"
fi
[[ "$DRY_RUN" == true ]] || ok "HEAD: $(git -C "$TARGET_DIR" rev-parse --short HEAD) (分支 $(git -C "$TARGET_DIR" rev-parse --abbrev-ref HEAD))"

# ---------------------------------------------------------------------------
step "外部数据卷"
# compose.yaml 里这两个卷是 external: true —— Docker 不会替我们建。
# bootstrap 的 host 阶段也会建（双保险：这里先建，避免 host 之前就被别的东西挡住）。
for v in go-user-system_mysql_data go-user-system_redis_data; do
  if docker volume inspect "$v" >/dev/null 2>&1; then
    info "已存在：$v"
  else
    run docker volume create "$v" >/dev/null
    ok "已创建：$v"
  fi
done

# ---------------------------------------------------------------------------
step "反向代理（Caddyfile）"
# 为什么在 install 而不是在 bootstrap：Caddyfile 与**域名**强相关，
# 而 bootstrap 只认"文件在不在"。把它放在这里、由 --domain 生成，
# 是为了**不要把某个具体域名硬编码进仓库**。
CADDYFILE="/etc/caddy/Caddyfile"
if [[ -z "$DOMAIN" ]]; then
  info "未指定 --domain，跳过（Caddy 将没有站点配置，HTTPS 起不来）"
elif [[ -f "$CADDYFILE" ]] && grep -qF "$DOMAIN" "$CADDYFILE" 2>/dev/null; then
  info "已存在含该域名的 Caddyfile，不覆盖"
else
  if [[ -f "$CADDYFILE" ]]; then
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    backup="/root/knowtrace-ops/backups/${ts}-before-install-caddy"
    run install -d -m 700 "$backup"
    run cp -a "$CADDYFILE" "$backup/Caddyfile"
    ok "原 Caddyfile 已备份到 $backup"
  fi
  if [[ "$DRY_RUN" == true ]]; then
    printf '    (dry-run) 写入 /etc/caddy/Caddyfile（域名 %s）\n' "$DOMAIN"
  else
    install -d -m 755 /etc/caddy /var/log/caddy
    # 从仓库模板生成，而不是在这里内嵌 —— 否则同一份配置有两个来源，
    # 改一处忘一处就会出现"脚本写的"与"仓库里的"不一致（本仓库踩过同类）。
    caddy_template="$TARGET_DIR/deploy/caddy/Caddyfile"
    if [[ ! -f "$caddy_template" ]]; then
      die "缺少模板 $caddy_template（仓库结构变了？）"
    fi
    sed "s|__DOMAIN__|$DOMAIN|g" "$caddy_template" > "$CADDYFILE"
    chown -R caddy:caddy /var/log/caddy 2>/dev/null || true
    ok "已写入 $CADDYFILE"
  fi
  # 证书由 ACME 自动签发 —— 前置条件是 DNS 已解析到本机且 80/443 从公网可达
  warn "签发证书需要：DNS 的 A 记录已指向本机，且 80/443 公网可达"
fi

# ---------------------------------------------------------------------------
step "交给 bootstrap"
# host 阶段会再确认一次卷与 nginx 站点配置；apps 之后会自动修 uploads 属主；
# verify 会断言「运行态 revision 是否包含所有影响镜像的改动」。
bootstrap="$TARGET_DIR/scripts/bootstrap/bootstrap.sh"
ARGS=(--all)
[[ "$ASSUME_YES" == true ]] && ARGS+=(--yes)
[[ "$DRY_RUN" == true ]] && ARGS+=(--dry-run)
# --record 透传给 bootstrap：重建演练时那份「每一步都记下来」的产物就是规格说明书
[[ -n "$RECORD_FILE" ]] && ARGS+=(--record "$RECORD_FILE")
if [[ "$DRY_RUN" == true ]]; then
  # dry-run 下 clone 只被打印、没有真的执行，所以这里**不能**检查文件是否存在 ——
  # 否则「全新机器 dry-run」会以一个假故障收尾（2026-10-02 实测踩到）。
  info "(dry-run) 将执行：bash $bootstrap ${ARGS[*]}"
else
  [[ -f "$bootstrap" ]] || die "缺少 $bootstrap（仓库结构变了？）"
  info "执行：bash $bootstrap ${ARGS[*]}"
  info "（含镜像构建，2 vCPU 机器上约 10–20 分钟）"
  bash "$bootstrap" "${ARGS[@]}"
fi

# ---------------------------------------------------------------------------
step "安装完成"
if [[ "$DRY_RUN" == true ]]; then
  info "dry-run 结束，未做任何修改"
  exit 0
fi

if [[ -f "$TARGET_DIR/.env" ]] && grep -qE '^KNOWTRACE_ADMIN_PASSWORD=KnowTrace-Workflow@123$' "$TARGET_DIR/.env"; then
  warn "管理员口令是固定值 KnowTrace-Workflow@123 —— 公网可达时**必须**改（README 里写着这对凭据）"
else
  info "管理员口令为随机生成，查看："
  info "  grep '^KNOWTRACE_ADMIN_' $TARGET_DIR/.env   # 勿贴进聊天或日志"
fi

info ""
info "【仍需你亲自做的两件事】—— 脚本刻意不代做："
info "  1) 防火墙（自锁风险：先放行 SSH 端口再 enable，否则立即失联）"
info "     ufw allow <你的SSH端口>/tcp && ufw allow 80/tcp && ufw allow 443/tcp"
info "     ufw default deny incoming && ufw default allow outgoing && ufw --force enable"
info "  2) SSH 加固（改错即失联）：装公钥 → **另开窗口验证密钥能登录** → 才关密码登录"
info "     样例：docs/KnowTrace-Workflow-VPS-部署学习-2026-09-06/阶段一/配置样例/00-knowtrace-hardening.conf"
info "  【更省事】以上 Day 0 加固（UFW / sshd / sysctl / fail2ban）可交给幂等的 Ansible："
info "     cd /opt/knowtrace/deploy/ansible && ansible-playbook site.yml（先 --tags access 装公钥并验证，再全量）"
info ""
info "端口与地址：应用 127.0.0.1:3000（经 Caddy → nginx），Grafana 需 SSH 隧道到 127.0.0.1:3001"
[[ -n "$DOMAIN" ]] && info "站点：https://$DOMAIN"
