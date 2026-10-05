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
    echo
    info "**决策已定（ADR-0018，accepted）：走 T2 —— 进程内 Node sidecar。**"
    info "  理由：\`docs/18\` §M2 已把移动端的离线队列列为必做，而「随手记录」是主路径；"
    info "        桌面端若不能离线记录，同一用户在两端的采集行为会不一致。"
    info "  出局：T3（加载远程 URL）离线时连界面都出不来，只是「没有地址栏的浏览器」；"
    info "        T1（静态导出）会关掉 Server Actions 与动态路由，违反 ADR-0016。"
    echo
    info "**但形态定了不等于能开工。** T2 有三个未定子问题（\`KT-DEFER-010\`）："
    info "  ① Node 运行时的打包与体积预算（约 +60–100MB）"
    info "  ② sidecar 的进程生命周期与端口分配（崩溃重启 / 端口冲突 / 退出清理）"
    info "  ③ 离线队列与 \`Idempotency-Key\` 的对接"
    info "三者任一未定都不动工，且不与 M2/M3/M4 并行。"
    echo
    info "决策与边界见 docs/adr/0018-desktop-shell-prerequisites.md。"
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
