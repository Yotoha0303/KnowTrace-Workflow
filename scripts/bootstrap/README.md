# scripts/bootstrap —— Linux 侧的一键部署入口

把「从零到可用」的既有零件串成一条链。**本目录不重新实现任何东西**，
只做编排：预检 → 按阶段调用既有脚本 → 记录每一步。

## 为什么需要它

2026-09-30 核查发现：Linux 侧每个零件都能用，但**没有任何编排入口**。
README 推荐的 `make up` 走的是 PowerShell（`scripts/start-all.ps1`），
在新 Linux 服务器上实测 `make`、`powershell`、`pwsh` **一个都不存在**。
于是「从零部署」实际是 7 步手工命令。

## 用法

```bash
sudo bash scripts/bootstrap/bootstrap.sh --all                # 全跑
sudo bash scripts/bootstrap/bootstrap.sh --stage apps         # 只跑应用
sudo bash scripts/bootstrap/bootstrap.sh --stage monitoring   # 只跑监控
sudo bash scripts/bootstrap/bootstrap.sh --stage ops          # 只装巡检定时器
sudo bash scripts/bootstrap/bootstrap.sh --stage verify       # 只验收
sudo bash scripts/bootstrap/bootstrap.sh --all --dry-run      # 只打印将要做什么
sudo bash scripts/bootstrap/bootstrap.sh --all --record /tmp/rebuild.md   # 记下每一步
```

## 阶段

| 阶段 | 做什么 | 调用的既有脚本 |
| --- | --- | --- |
| `apps` | 生成 `.env` / `.env.observability`、校验 compose、构建并启动应用栈 | `scripts/linux/init-env.sh`、`init-observability-env.sh`、`docker compose up -d --build --wait` |
| `monitoring` | 监控栈 + 边缘阻断 + 自带验收 | `scripts/linux/deploy-observability.sh`（**不带** `--build-app`，apps 阶段已构建） |
| `ops` | 同步工具包、装 6 个 systemd 单元 | `scripts/ops/systemd/install.sh` |
| `verify` | 端点 / 端口 / 容器验收 | 内置 |

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `BOOTSTRAP_MIN_FREE_KIB` | `700000` | 内存预检阈值。**只在你清楚后果时下调** |
| `NODE_OPTIONS` | `--max-old-space-size=1024` | 构建期 Node 内存上限 |

## 依赖的外部命令（按用途分档）

| 命令 | 谁在用 | 缺了会怎样 |
| --- | --- | --- |
| `git`、`docker`（含 compose v2） | `apps` 阶段 | 无法继续 |
| `openssl`、`python3`、`curl`、`awk`、`sed`、`grep` | 各阶段 | 无法继续 |
| **`jq`** | **巡检**：`ops-monitor.sh`(14 处)、`weekly-check.sh`(11 处)、`monthly-ops.sh`(1 处) | **静默降级**：报告字段为空。调用点普遍带 `2>/dev/null`，错误被吞 |
| **`flock`** | **备份链路**：`backup-all.sh`、`prune-backups.sh` | 备份的并发保护失效 |
| `ss`、`systemctl`、`ufw` | 巡检的只读检查 | 少几项检查，不阻断 |
| `make`、`bc` | 仓库脚本里 **0 处调用** | 真可选（`make` 只在 PowerShell 侧的 Makefile 用） |

**为什么 `jq` / `flock` 归在"必需"**：2026-10-02 之前它们被列在"可选"，
而缺了并不是"少个功能"——是巡检**产出不完整报告却仍然退出 0**，
与本项目最贵的故障形状（"看起来成功了"）完全一致。

Debian / Ubuntu 一条装齐：

```bash
apt-get install -y git curl openssl python3 jq util-linux ca-certificates
```

> ⚠️ `jq` 在 Ubuntu 上可能因 **`fwupd` 的依赖而碰巧存在**
> （`apt-mark showauto` 里有它、`showmanual` 里没有）——
> 所以"这台机器能跑"不代表"下一台也能"。预检因此显式要求它。

---

## 预检为什么比 `deploy-observability.sh` 严

本脚本要跑 `docker build`，而那个脚本只起容器。
2026-09-30 的事故里，`next build` 把 2 vCPU / 1.8 GB 的实例压到**负载 124、可用内存 15 MB**，
造成约 **70 分钟全站不可用**（见 `KnowTrace-ops/docs/2026-09-30-全站500事故复盘.md`）。

所以这里是 700 MiB / 12 GiB，比 `deploy-observability.sh` 的 500 MiB / 8 GiB 更严。
内存不够时的三条出路（脚本不替你选）：

1. 在另一台机器上构建镜像，再 `docker save` / `docker load` 过来
2. 临时加 swap，并确保构建期间没有别的重活在跑
3. 换一台内存更大的机器

## 明确不自动化

| 不做 | 原因 |
| --- | --- |
| 云厂商侧（买机器、DNS、安全组） | 有凭据与计费边界 |
| 首次 SSH 连接 | 鸡生蛋问题 |
| 系统包安装 | 依赖发行版，且需要判断 |
| **sshd 加固与 UFW** | **有「自锁」风险**：`ufw enable` 前未放行 SSH 端口会立即失联，且无法从远程改回来；改 `sshd_config` 后重启失败同理 |
| 反向代理与证书 | 与 DNS 和域名强相关，且 Caddy 自带 ACME |
| 告警凭据（163 授权码） | 项目设计就是必须隐藏输入，不能进仓库 |

这几项的完整步骤见 [`docs/日常运维/运维手册.md`](../../docs/日常运维/运维手册.md)（连接、巡检、
备份恢复、部署发布、故障排查、宿主机加固，每条命令都实测过）。
VPS 部署期的完整实操教程（663 行）已随阶段档案移出仓库，现位于
`../../KnowTrace-ops/archive/docs/KnowTrace-Workflow-VPS-部署学习-2026-09-06/阶段一/文档/`。

## 设计依据与一个诚实的边界

`KnowTrace-ops/docs/2026-09-29-一键部署可行性与设计.md` §4.2 主张：

> **写 bootstrap 的最佳时机，就是做灾难恢复演练的时候。**
> 先手工重建成一次，把踩到的每一步记下来——那份记录就是一键脚本的规格说明书。

**本脚本遵守了这个约束的一半**：它编排的每一步都是**已实测过的命令**
（`init-env.sh`、`deploy-observability.sh`、`systemd/install.sh` 都有各自的实测记录），
没有推断出来的步骤。

**但另一半没做**：**整机重建演练仍未进行**。也就是说——
这些命令在「当前这台机器上装东西」是验证过的，
但「从一份备份把整台机器重建出来」这条路径**从未端到端跑过**。

所以本脚本的定位是：**它让新机器上的部署变成一条命令，但它还不是一条经过演练的恢复路径。**
`--record` 就是为那次演练准备的。

## 相关

- 设计文档与三块拦路石：`KnowTrace-ops/docs/2026-09-29-一键部署可行性与设计.md`
- 事故复盘（预检阈值的依据）：`KnowTrace-ops/docs/2026-09-30-全站500事故复盘.md`
- 从零部署人工教程：见 [`docs/日常运维/运维手册.md`](../../docs/日常运维/运维手册.md)；
  VPS 部署期教程已随阶段档案移出仓库（`../../KnowTrace-ops/archive/`）
- 监控栈细节：`docs/16-stage3-observability.md`
