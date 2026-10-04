#!/usr/bin/env bash
# ============================================================================
# bootstrap 主入口 —— 把「从零到可用」的既有零件串成一条链
# ============================================================================
#
# 为什么存在
# ----------
# 2026-09-29/30 核查发现：Linux 侧每个零件都能用，但**没有任何编排入口**。
# README 推荐的 `make up` 走的是 PowerShell（scripts/start-all.ps1），
# 在新 Linux 服务器上 `make`、`powershell`、`pwsh` 一个都不存在。
# 于是「从零部署」实际是 7 步手工命令 + 一堆没自动化的系统准备。
#
# 本脚本不重新实现任何东西，只做三件事：
#   1. 预检（不合格直接拒绝）
#   2. 按阶段调用既有脚本（apps / monitoring / ops）
#   3. 每步记进 --record 记录文件（灾难恢复演练时它就是重建文档）
#
# 与 2026-09-29 设计文档的关系
# ---------------------------
# 那份文档 §4.2 主张「先手工重建成一次，把踩到的每一步记下来，再写脚本」，
# 反对凭空想象地写。本脚本遵守这个约束：**它编排的每一步都是已实测过的命令**，
# 没有任何推断出来的步骤。见 KnowTrace-ops/docs/2026-09-29-一键部署可行性与设计.md。
#
# 明确不自动化（沿用 §3.3）
# ------------------------
#   * 云厂商侧（买机器、DNS、安全组）
#   * 首次 SSH 连接（鸡生蛋）
#   * 系统包安装 / sshd 加固 / UFW —— 有「自锁」风险（见 §2.3），
#     一律不默默执行，只打印指引
#   * 告警凭据（163 授权码）—— 设计上必须隐藏输入
#
# 用法
# ----
#   bootstrap.sh --stage <host|apps|monitoring|ops|verify> [选项]
#   bootstrap.sh --all [--yes]
#
# 阶段
#   ansible     Day 0 宿主机加固（系统包/sshd/sysctl/UFW/fail2ban，幂等）。
#               需 ansible-core 与 /root/knowtrace-ops/knowtrace_vps_ed25519.pub 就位，否则跳过
#   host        宿主机准备：建 external 数据卷 + 放 Nginx 站点配置 + 移除 default 站点
#               （幂等，可重复跑；全新机器上必须先跑它，否则 apps 连构建都开始不了）
#   apps        拉代码 + 生成 .env + 起应用栈（会构建镜像，耗时最长）
#               结束后会自动修一次上传目录属主（见 prepare-host.sh 的说明）
#   monitoring  调 deploy-observability.sh（监控栈 + Nginx 阻断）
#   ops         装运维巡检的 systemd 单元
#   verify      全链路验收
#
# 选项
#   --dir <路径>     项目目录（默认脚本所在的仓库根）
#   --record <文件>  把每一步追加写入该文件（重建文档）
#   --yes            危险/耗时步骤自动确认（CI 用；人类别用）
#   --dry-run        只打印将要做什么，不执行
#   --help
#
# 环境变量
#   BOOTSTRAP_MIN_FREE_KIB   覆盖内存预检阈值（默认 700000，约 700 MiB）。
#                            只在你清楚后果时下调——见下方「预检为什么比别处严」。
#   NODE_OPTIONS             构建期 Node 内存上限（默认 --max-old-space-size=1024）
#
# 预检为什么比 deploy-observability.sh 严
# ---------------------------------------
# 本脚本要跑 docker build，而那个脚本只起容器。2026-09-30 的事故里，
# next build 把 2 vCPU / 1.8 GB 的实例压到负载 124、可用内存 15 MB，
# 并造成约 70 分钟全站不可用。所以这里宁愿早拒绝。
#
# 退出码
#   0 成功   1 失败   2 危险步骤被拒绝   3 用法错误
# ============================================================================

set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
. "$script_directory/lib/common.sh"
# shellcheck source=lib/preflight.sh
. "$script_directory/lib/preflight.sh"

BOOTSTRAP_DIR="$(cd -- "$script_directory/../.." && pwd -P)"
BOOTSTRAP_ASSUME_YES=false
BOOTSTRAP_DRY_RUN=false
BOOTSTRAP_STAGES=()

usage() {
  # 退出码按项目惯例：--help 是**正常**请求，返回 0；
  # 参数错误才返回 BOOTSTRAP_USAGE(3)。与 install.sh / init-env.sh 一致。
  sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "$1"
}

while (( $# )); do
  case "$1" in
    --stage)
      [[ -n "${2:-}" ]] || { echo "错误：--stage 需要一个值" >&2; exit "$BOOTSTRAP_USAGE"; }
      case "$2" in
        ansible|host|apps|monitoring|ops|verify) BOOTSTRAP_STAGES+=("$2") ;;
        *) echo "错误：未知阶段 $2（可选 ansible|host|apps|monitoring|ops|verify）" >&2; exit "$BOOTSTRAP_USAGE" ;;
      esac
      shift 2 ;;
    --all)     BOOTSTRAP_STAGES=(ansible host apps monitoring ops verify); shift ;;
    --dir)     BOOTSTRAP_DIR="$(cd -- "$2" && pwd -P)"; shift 2 ;;
    --record)  BOOTSTRAP_RECORD_FILE="$2"; shift 2 ;;
    --yes)     BOOTSTRAP_ASSUME_YES=true; shift ;;
    --dry-run) BOOTSTRAP_DRY_RUN=true; shift ;;
    --help|-h) usage 0 ;;
    *) echo "错误：未知参数 $1" >&2; exit "$BOOTSTRAP_USAGE" ;;
  esac
done

if (( ${#BOOTSTRAP_STAGES[@]} == 0 )); then
  echo "错误：至少需要一个阶段（--stage <阶段> 或 --all）" >&2
  usage "$BOOTSTRAP_USAGE"
fi

# 需要 root：既有脚本（init-env.sh 等）自己会 sudo，但预检要读 /proc 与 docker
if (( EUID != 0 )); then
  exec sudo -- "$0" "$@"
fi

cd -- "$BOOTSTRAP_DIR"

# compose 调用方式：**必须**两个 --env-file + 三个 -f。
# 漏掉会在 MetricsBearerToken / KNOWTRACE_APP_REVISION 上静默失效，
# 而部署看起来仍然成功（2026-09-30 事故的教训）。
compose=(
  docker compose
  --project-directory "$BOOTSTRAP_DIR"
  --env-file "$BOOTSTRAP_DIR/.env"
  --env-file "$BOOTSTRAP_DIR/.env.observability"
  -f "$BOOTSTRAP_DIR/compose.yaml"
  -f "$BOOTSTRAP_DIR/compose.production.yaml"
  -f "$BOOTSTRAP_DIR/compose.observability.yaml"
)

b_record "=== bootstrap 开始 $(date -u '+%Y-%m-%dT%H:%M:%SZ') dir=$BOOTSTRAP_DIR stages=${BOOTSTRAP_STAGES[*]} ==="

# ---------------------------------------------------------------------------
b_stage_ansible() {
  b_step "阶段：ansible —— Day 0 宿主机加固（幂等）"

  local ansible_dir="$BOOTSTRAP_DIR/deploy/ansible"
  local playbook="$ansible_dir/site.yml"
  local pubkey_file="/root/knowtrace-ops/knowtrace_vps_ed25519.pub"

  # 缺料就跳过、不硬跑：sshd/UFW 有自锁风险，跑一半比不跑更危险
  if [[ ! -f "$playbook" ]]; then
    b_fail "缺少 $playbook"
    return "$BOOTSTRAP_FAIL"
  fi
  if ! command -v ansible-playbook >/dev/null 2>&1; then
    b_warn "跳过：未安装 ansible-core（apt-get install ansible-core && ansible-galaxy collection install -r deploy/ansible/requirements.yml）"
    return 0
  fi
  if [[ ! -f "$pubkey_file" ]]; then
    b_warn "跳过：缺少控制端公钥 $pubkey_file（access role 会断言它；先 scp 公钥再跑）"
    return 0
  fi

  if [[ "$BOOTSTRAP_DRY_RUN" == true ]]; then
    b_info "(dry-run) ansible-playbook site.yml --check"
    return 0
  fi

  (cd "$ansible_dir" && ansible-playbook site.yml)
  b_record "RUN: ansible-playbook site.yml"
  b_ok "Day 0 加固完成（幂等，二次运行 changed=0）"
}

# ---------------------------------------------------------------------------
b_stage_host() {
  b_step "阶段：host —— 宿主机准备（建数据卷 / 边缘配置）"
  # 为什么必须在这里：compose.yaml 的两个数据卷是 external: true，
  # 而唯一创建它们的是 scripts/start-all.ps1（PowerShell）—— Linux 侧没有对应实现。
  # 2026-10-02 实测：不建卷时 `compose up` 直接报 external volume not found，
  # 连镜像构建都不会开始。
  local prepare="$BOOTSTRAP_DIR/scripts/linux/prepare-host.sh"
  if [[ ! -f "$prepare" ]]; then
    b_fail "缺少 $prepare"
    return "$BOOTSTRAP_FAIL"
  fi
  if [[ "$BOOTSTRAP_DRY_RUN" == true ]]; then
    bash "$prepare" --dry-run
  else
    bash "$prepare"
    b_record "RUN: scripts/linux/prepare-host.sh"
  fi
}

# ---------------------------------------------------------------------------
b_stage_apps() {
  b_step "阶段：apps —— 生成配置并启动应用栈"

  # 1) .env
  if b_file_has_content "$BOOTSTRAP_DIR/.env"; then
    b_already ".env 已存在"
  else
    if [[ "$BOOTSTRAP_DRY_RUN" == true ]]; then
      b_info "(dry-run) bash scripts/linux/init-env.sh"
    else
      bash scripts/linux/init-env.sh
      b_record "RUN: scripts/linux/init-env.sh"
    fi
  fi

  # 2) .env.observability —— 由 monitoring 阶段真正需要；apps 阶段先确保存在，
  #    因为 compose 合并时它会参与变量插值（缺了 METRICS_BEARER_TOKEN 会直接报错）。
  if b_file_has_content "$BOOTSTRAP_DIR/.env.observability"; then
    b_already ".env.observability 已存在"
  else
    if [[ "$BOOTSTRAP_DRY_RUN" == true ]]; then
      b_info "(dry-run) bash scripts/linux/init-observability-env.sh"
    else
      bash scripts/linux/init-observability-env.sh
      b_record "RUN: scripts/linux/init-observability-env.sh"
    fi
  fi

  # 3) 配置校验 —— 先校验再构建，避免构建完才发现 compose 写错
  if [[ "$BOOTSTRAP_DRY_RUN" == true ]]; then
    b_info "(dry-run) compose config --quiet"
  else
    "${compose[@]}" config --quiet
    b_ok "compose 配置校验通过"
    b_record "VERIFY: compose config --quiet 通过"
  fi

  # 4) 构建并启动
  b_info "将执行：up -d --build --wait（含镜像构建，2 vCPU 机器上约 3–5 分钟）"
  if [[ "$BOOTSTRAP_DRY_RUN" == true ]]; then
    b_info "(dry-run) ${compose[*]} up -d --build --wait"
    return 0
  fi
  export KNOWTRACE_APP_REVISION="$(git -C "$BOOTSTRAP_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=1024}"
  b_info "KNOWTRACE_APP_REVISION=${KNOWTRACE_APP_REVISION:0:12}（构建期烘进镜像）"
  "${compose[@]}" up -d --build --wait --wait-timeout 1200
  b_record "RUN: compose up -d --build --wait（revision=${KNOWTRACE_APP_REVISION:0:12}）"
  b_ok "应用栈已启动"

  # 属主修复必须紧跟 up：compose.yaml 把 ./data/uploads 作为绑定挂载，
  # up 会重建该目录并由 root 创建，盖掉镜像里的 chown —— 不修则图片上传 100% EACCES
  # （2026-09-13 与 09-19 曾静默发生 42 次）。
  # 2026-10-02 实测：修复前该目录确实是 root:root。
  bash "$BOOTSTRAP_DIR/scripts/linux/prepare-host.sh" --fix-uploads
  b_record "RUN: prepare-host.sh --fix-uploads（绑定挂载属主修复）"
}

# ---------------------------------------------------------------------------
b_stage_monitoring() {
  b_step "阶段：monitoring —— 监控栈 + 边缘阻断 + 自带验收"
  if [[ "$BOOTSTRAP_DRY_RUN" == true ]]; then
    b_info "(dry-run) bash scripts/linux/deploy-observability.sh"
    return 0
  fi
  # 不带 --build-app：apps 阶段已经构建过。带它会重复构建（这台机器上很贵）。
  bash scripts/linux/deploy-observability.sh
  b_record "RUN: scripts/linux/deploy-observability.sh"
  b_ok "监控栈就绪"
}

# ---------------------------------------------------------------------------
b_stage_ops() {
  b_step "阶段：ops —— 安装巡检 systemd 单元"
  local ops_root="/opt/knowtrace-ops"
  local conf="/etc/knowtrace/ops.conf"

  if [[ "$BOOTSTRAP_DRY_RUN" == true ]]; then
    b_info "(dry-run) install -d -m 700 /etc/knowtrace"
    b_info "(dry-run) cp -a scripts/ops/{lib,scripts,systemd,docs,ops.conf.example} $ops_root/"
    b_info "(dry-run) bash $ops_root/systemd/install.sh --source $ops_root/systemd"
    return 0
  fi

  install -d -m 755 "$ops_root"
  # 缺口：ops.conf 要写进 /etc/knowtrace/，而该目录在老机上是手工建的，
  # 全新机器上不存在 —— 2026-10-02 实测 ops 阶段因此报
  # `install: cannot create regular file '/etc/knowtrace/ops.conf': No such file or directory`
  # 并以 set -Eeuo pipefail 中止，单元一个都没装。
  #
  # 为什么不交给 install.sh：它把"配置文件存在"当预检前提（`[ OK ] 配置文件存在`），
  # 所以必须在调它之前就把目录建好。
  install -d -m 700 /etc/knowtrace
  # cp -a 而不是 cp -r：cp -r 不修正已存在目标的权限位，
  # 某文件第一次以错误模式拷进去后每次重拷都不会自愈（见 09-29 文档 N3）。
  cp -a scripts/ops/lib scripts/ops/scripts scripts/ops/systemd scripts/ops/docs scripts/ops/ops.conf.example "$ops_root/"
  b_ok "工具包已同步到 $ops_root"

  if [[ ! -f "$conf" ]]; then
    install -m 600 "$ops_root/ops.conf.example" "$conf"
    b_warn "已创建 $conf（0600）—— **需要你编辑**：至少确认 PROJECT_DIR / CERT_DOMAINS / PUBLIC_HEALTH_URL"
  else
    b_already "已存在 $conf"
  fi

  install -d -m 755 /var/lib/knowtrace/reports /var/log/knowtrace-logs
  bash "$ops_root/systemd/install.sh" --source "$ops_root/systemd"
  b_record "RUN: systemd/install.sh（先 start 验证，再 enable 定时器）"
  b_ok "巡检定时器已安装"
}

# ---------------------------------------------------------------------------
# 明确列出「脚本刻意不做、必须人来做」的事，并给出可直接复制的命令。
#
# 为什么要有这个：本项目最贵的教训是「部署看起来成功了」——
# 脚本跑完 ALL GREEN，而实际上 Caddyfile 没有、UFW 没启、口令还是默认值。
# 与其让这些躺在文档第 4 节里，不如在结束时当面列出来。
b_report_remaining_manual() {
  local domain="${BOOTSTRAP_DOMAIN:-knowtrace.duckdns.org}"
  local pending=()

  [[ -f /etc/caddy/Caddyfile ]] || pending+=("caddyfile")
  [[ "$(systemctl is-active ufw 2>/dev/null)" == "active" ]] || pending+=("ufw")
  if [[ -f "$BOOTSTRAP_DIR/.env" ]] && grep -qE '^POSTGRES_PASSWORD=knowtrace$' "$BOOTSTRAP_DIR/.env"; then
    pending+=("postgres_password")
  fi
  [[ -f /etc/knowtrace/age-recipient.pub ]] || pending+=("offsite")

  if (( ${#pending[@]} == 0 )); then
    b_ok "没有遗留的人工项"
    return 0
  fi

  b_step "还需要你做的（脚本刻意不代做，理由见 §4 边界）"
  for item in "${pending[@]}"; do
    case "$item" in
      caddyfile)
        b_warn "反向代理与证书 —— 仓库不提供 Caddyfile（与域名强相关）"
        b_info "    写入 /etc/caddy/Caddyfile 后：caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy"
        b_info "    模板见 docs/KnowTrace-Workflow-VPS-部署学习-2026-09-06/阶段一/服务器配置样例/Caddyfile"
        ;;
      ufw)
        b_warn "防火墙 —— 有自锁风险，脚本绝不代启"
        b_info "    ⚠️ 先把 SSH 端口放行，否则会立即失联："
        b_info "    ufw allow <你的SSH端口>/tcp && ufw allow 80/tcp && ufw allow 443/tcp"
        b_info "    ufw default deny incoming && ufw default allow outgoing && ufw --force enable"
        ;;
      postgres_password)
        b_warn "POSTGRES_PASSWORD 仍是 .env.example 的字面量 knowtrace"
        b_info "    注意：改它要同时改容器与数据卷，**有丢数据风险**，请在维护窗口做"
        ;;
      offsite)
        b_warn "异地备份未配置 —— 单元会因缺 age 公钥被 ConditionPathExists 静默跳过"
        b_info "    需先选后端，再写 /etc/knowtrace/age-recipient.pub 与 OFFSITE_REMOTE"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
b_stage_verify() {
  b_step "阶段：verify —— 全链路验收"
  local failures=0

  check() {
    local label="$1" url="$2" expect="${3:-200}"
    local got
    got="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$url" 2>/dev/null || echo 000)"
    if [[ "$got" == "$expect" ]]; then
      b_ok "$label → $got"
    else
      b_fail "$label → $got（期望 $expect）"
      failures=$(( failures + 1 ))
    fi
  }

  check "应用存活"  "http://127.0.0.1:3000/api/health/live"
  check "应用就绪"  "http://127.0.0.1:3000/api/health/ready"
  # /api/metrics 无 token 时返回 404 是**设计行为**（404-instead-of-401），不是故障
  check "指标端点（未授权应为 404）" "http://127.0.0.1:3000/api/metrics" 404

  command -v ss >/dev/null 2>&1 && {
    b_info "监听端口："
    ss -tlnp 2>/dev/null | awk 'NR>1 {print "    " $4}' | sort -u | head -12
  }

  b_info "容器状态："
  docker ps --format '    {{.Names}}\t{{.Status}}' 2>/dev/null | sort | head -12

  # ---------------------------------------------------------------------------
  # 以下三项是 2026-10-02 真机演练才暴露出来的判据。
  # 教训（2026-09-30 事故）：**"部署成功"不能只看命令返回 0**，
  # 也不能只看端点 200 —— 必须断言「运行态 == 期望态」。
  # ---------------------------------------------------------------------------

  # (a) 运行态 revision 是否等于部署目录的 HEAD。
  #     镜像里烘进了 KNOWTRACE_APP_REVISION，这是唯一能证明
  #     "线上跑的就是这份代码"的判据。09-30 那次事故正是缺这个断言。
  local expect_revision actual_revision app_container
  expect_revision="$(git -C "$BOOTSTRAP_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  # 用 compose 解析出 app 容器，不写死容器名。
  # 为什么：容器名是 `<compose 项目名>-<服务>-1`，项目名一改（如
  # KnowTrace → KnowTrace-Workflow）容器名就变，写死会让这个**版本核对断言**
  # 悄悄失效 —— 而它正是 2026-09-30 事故后加的、最该保持有效的那一条。
  app_container="$("${compose[@]}" ps -q app 2>/dev/null | head -n1)"
  if [[ -z "$app_container" ]]; then
    b_warn "找不到 app 容器（compose ps -q app 为空）—— 跳过运行态 revision 核对"
    return 0
  fi
  actual_revision="$(docker inspect "$app_container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= '/^KNOWTRACE_APP_REVISION=/{print $2}' | tr -d '\r')"
  if [[ -z "$actual_revision" ]]; then
    b_warn "取不到运行态 revision（容器 $app_container 里没有 KNOWTRACE_APP_REVISION）—— 跳过该项"
  elif [[ "$actual_revision" == "$expect_revision" ]]; then
    b_ok "运行态 revision 与 HEAD 一致 → ${actual_revision:0:12}"
  else
    # 不一致本身不一定是问题：只改 docs/ 或 scripts/ 时镜像本来就不需要重建
    # （那些文件不进镜像）。所以要看**运行态到 HEAD 之间改过哪些文件**。
    #
    # 为什么这样定：2026-09-30 的事故是「15 个 src/ 文件没进镜像」，
    # 而当时没有任何检查能发现它。断言要抓的是那件事，不是"HEAD 相等"这个形式。
    local app_paths=(src package.json pnpm-lock.yaml pnpm-workspace.yaml Dockerfile
                     drizzle services next.config.ts .dockerignore
                     compose.yaml compose.production.yaml compose.observability.yaml)
    local app_changed=""
    if git -C "$BOOTSTRAP_DIR" cat-file -e "${actual_revision}^{commit}" 2>/dev/null; then
      app_changed="$(git -C "$BOOTSTRAP_DIR" diff --name-only \
        "$actual_revision" "$expect_revision" -- "${app_paths[@]}" 2>/dev/null | head -5)"
    else
      b_warn "部署目录里没有 ${actual_revision:0:12} 这个提交（浅克隆？）—— 无法判断差异范围"
      app_changed="unknown"
    fi

    if [[ -z "$app_changed" ]]; then
      b_warn "运行态 ${actual_revision:0:12} 落后 HEAD ${expect_revision:0:12}，但差异只涉及文档/脚本 —— 镜像无需重建"
    else
      b_fail "运行态 revision 落后，且**有影响镜像的改动未部署**"
      b_info "  运行 ${actual_revision:0:12} → HEAD ${expect_revision:0:12}"
      if [[ "$app_changed" != "unknown" ]]; then
        b_info "  未部署的文件（前 5 个）："
        printf '    %s\n' $app_changed
      fi
      b_info "  修法：bash scripts/bootstrap/bootstrap.sh --stage apps"
      failures=$(( failures + 1 ))
    fi
  fi

  # (b) 证据图片目录是否真的可写。
  #     这是"命令返回 0 但功能坏掉"的典型：compose 起得来、端点 200，
  #     但绑定挂载属主是 root 时上传 100% EACCES（曾静默 42 次）。
  #     所以这里做**真实写入探测**，而不是看属主数字。
  local uploads_probe="$BOOTSTRAP_DIR/data/uploads/evidence/.bootstrap-write-probe"
  if [[ ! -d "$BOOTSTRAP_DIR/data/uploads/evidence" ]]; then
    b_warn "证据目录不存在（应用尚未初始化？）—— 跳过可写断言"
  elif ( umask 077; : > "$uploads_probe" ) 2>/dev/null; then
    rm -f -- "$uploads_probe"
    b_ok "证据图片目录可写"
  else
    b_fail "证据图片目录不可写 —— 图片上传会以 EACCES 失败"
    b_info "  修法：bash scripts/linux/prepare-host.sh --fix-uploads"
    failures=$(( failures + 1 ))
  fi

  # (c) 5 个定时器是否都已 enable。
  #     ops 阶段曾因 /etc/knowtrace 缺失而静默中止，单元一个都没装。
  # 4 个是**必需**的；offsite-backup 是**可选**的（它需要 age 公钥 + rclone 远端，
  # 属"刻意不自动化"那一类）。2026-10-02 裸机演练实测：把 offsite 也当必需，
  # 新机器上直接报 FAIL，把整条链的结论污染成失败 —— 那是假失败。
  local timer missing_timers=()
  for timer in backup daily-ops weekly-check monthly-ops; do
    if [[ "$(systemctl is-enabled "knowtrace-$timer.timer" 2>/dev/null)" != "enabled" ]]; then
      missing_timers+=("$timer")
    fi
  done
  if (( ${#missing_timers[@]} == 0 )); then
    b_ok "4 个必需定时器均已启用"
  else
    b_fail "未启用的定时器：${missing_timers[*]}"
    failures=$(( failures + 1 ))
  fi
  if [[ "$(systemctl is-enabled "knowtrace-workflow-offsite-backup.timer" 2>/dev/null)" == "enabled" ]]; then
    b_ok "offsite-backup 定时器已启用（异地备份，可选）"
  else
    b_info "offsite-backup 未启用 —— 可选，需 age 公钥与 rclone 远端后才能工作"
  fi

  if (( failures == 0 )); then
    b_ok "验收通过"
    b_record "VERIFY: 全链路验收通过（$failures 个失败）"
  else
    b_fail "验收有 $failures 项失败"
    b_record "VERIFY: 失败 $failures 项"
    return 1
  fi
}

# ---------------------------------------------------------------------------
b_step "预检"
b_check_os
b_check_commands
b_check_docker_running
b_check_resources
b_check_ports

if ! b_detect_existing_deployment; then
  b_warn "本目录已有容器在运行 —— 这可能是重复部署。"
  if ! b_confirm "确认要在已有部署的目录上继续吗？"; then
    b_fail "已中止（危险步骤被拒绝）"
    exit "$BOOTSTRAP_DANGER_DECLINED"
  fi
fi

b_record "PREFLIGHT: 通过"

for stage in "${BOOTSTRAP_STAGES[@]}"; do
  b_stage_"$stage"
done

b_step "完成"
b_info "阶段：${BOOTSTRAP_STAGES[*]}"
if [[ -n "$BOOTSTRAP_RECORD_FILE" ]]; then
  b_info "步骤记录：$BOOTSTRAP_RECORD_FILE"
fi
b_info "未自动化的部分（需人工）：反向代理与证书、DNS（ansible 阶段若因缺 ansible-core/公钥被跳过，系统包/sshd/UFW 也需人工）。"
b_report_remaining_manual
b_info "指引见 docs/KnowTrace-Workflow-VPS-部署学习-2026-09-06/阶段一/文档/04-从零部署到当前线上状态-完整实操教程.md"
b_record "=== bootstrap 结束 $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
