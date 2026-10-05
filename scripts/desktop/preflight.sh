#!/usr/bin/env bash
set -Eeuo pipefail
# ============================================================================
# 桌面端**前提**检查（不是桌面端本体）
# ============================================================================
#
# 为什么需要它
# ------------
# `docs/adr/0016` 与 `docs/18` §M5 都写「桌面端用 Tauri 套用现有 Web 构建产物」。
# 但 `next.config.ts` 是 `output: "standalone"` —— 产物是一个**Node 服务**，
# 不是静态目录；而 Tauri 的 `frontendDist` 吃的是静态目录。两者不是一回事。
#
# 结论：那句话是一个**未经验证的前提**，不是既成事实（见 ADR-0018）。
# 本脚本的作用就是把这个前提变成**可执行、可证伪**的判断，
# 而不是让它继续躺在文档里当断言。
#
# 它断言什么
# ----------
# 当前形态必须是 `standalone`。理由：`export`（静态导出）会关掉
# Server Actions 与动态路由 —— 那等于重写业务逻辑，
# 违反 ADR-0016「复用服务端，不重写」的边界。
#
# 退出码
#   0 = 形态符合预期（standalone），桌面端只能走「sidecar」或「加载远程 URL」两条路
#   1 = 形态不符合：出现了静态导出，或读不出 output —— 桌面端的前提变了，要重评
#   3 = 脚本自身错误（找不到文件 / 缺命令）
# ============================================================================

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_directory="$(cd -- "$script_directory/../.." && pwd -P)"
config="$project_directory/next.config.ts"

fail() { printf '  [FAIL] %s\n' "$*" >&2; }
ok()   { printf '  [ OK ] %s\n' "$*"; }
info() { printf '  [INFO] %s\n' "$*"; }

[[ -f "$config" ]] || { fail "找不到 $config"; exit 3; }

# 从 next.config.ts 里取 output 的值。
# 刻意不用 node 去 require 它：那是 TS + ESM，要额外的转译步骤，
# 而这里只需要一个字段 —— 正则足够，且不会因为导入副作用而失败。
output_kind="$(sed -nE 's/^[[:space:]]*output:[[:space:]]*"([^"]+)".*/\1/p' "$config" | head -1)"

echo "=== 桌面端前提检查 ==="
echo "next.config.ts: ${output_kind:-<未声明>}"
echo

case "$output_kind" in
  standalone)
    ok "Web 构建产物形态 = standalone（一个 Node 服务，**不是**静态目录）"
    echo
    info "对桌面端的直接后果：Tauri 的 frontendDist **喂不进**当前产物。"
    info "可走的路只剩两条（都不是「套一下就行」）："
    info "  T3 加载远程 URL —— 改动最小，但**离线不可用**，它不是桌面应用，只是没地址栏的浏览器"
    info "  T2 进程内 Node sidecar —— 能离线，但要打包 Node 运行时（约 +60–100MB）"
    info "被否：T1 静态导出（output: \"export\"）—— 会关掉 Server Actions 与动态路由，"
    info "      等于重写业务逻辑，违反 ADR-0016。"
    echo
    info "决策与边界见 docs/adr/0018-desktop-shell-prerequisites.md。"
    info "本脚本只保证「前提可见且可证伪」，**不代替形态决策**。"
    ;;
  export)
    fail "检测到 output: \"export\" —— 静态导出会关掉 Server Actions 与动态路由。"
    info "那等于重写业务逻辑，违反 ADR-0016「复用服务端，不重写」。"
    info "如果你是有意改成静态导出，先读 ADR-0018 并改它的状态，再改这里。"
    exit 1
    ;;
  "")
    fail "读不出 next.config.ts 的 output —— 形态无法判定。"
    info "要么是写法变了（例如改成变量、或去掉了 output），要么是解析规则过期。"
    info "无论哪种，桌面端的前提都需要重新评估。"
    exit 1
    ;;
  *)
    fail "未知的 output 形态：$output_kind"
    info "ADR-0018 只对 standalone 做过判断。新形态需重新评估桌面端前提。"
    exit 1
    ;;
esac
