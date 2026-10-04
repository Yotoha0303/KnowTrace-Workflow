# deploy/ —— 分层职责

这个目录按**生命周期**分层，每一层只干一件事。
依据是 [`../其他收获/部署与运维工具了解.md`](../../其他收获/部署与运维工具了解.md) §一/§四。

| 层 | 时机 | 负责 | 载体 | 在哪儿 |
| --- | --- | --- | --- | --- |
| **Day 0 宿主机** | 一次 | OS 依赖、`authorized_keys`、sshd 加固、内核参数、UFW、fail2ban | **Ansible** | [`ansible/`](ansible/) |
| **Day 1 服务编排** | 每次发版 | 应用与监控容器怎么起、怎么组网、内存上限 | **Docker Compose** | 仓库根 `compose*.yaml`（不在本目录） |
| **Day 1 流量入口** | 一次 | 域名 → 证书 → 反代 | **Caddy** | [`caddy/`](caddy/) |
| **Day 2+ 周期任务** | 定时 | 备份、清理、巡检、审计 | **systemd timer + 脚本** | [`systemd/`](systemd/) + `../scripts/ops/` |

各层**不得越界**（文档原话）：Ansible 不管容器内配置；Compose 不管宿主机安全；
Caddy 不承担核心加固；周期任务只管触发。

---

## 目录内容

```
deploy/
├── ansible/      Day 0 宿主机（依赖 / sshd / sysctl / UFW / fail2ban）
├── caddy/        Caddyfile（域名→证书→反代）
├── alloy/        采集：容器 / Caddy / Nginx 日志 → Loki
├── loki/         Loki 单机配置（本地文件系统 + 7 天保留）
├── grafana/      数据源与看板的 provisioning
├── monitoring/   Prometheus 配置 / 规则 / blackbox 探针
├── nginx/        127.0.0.1:8080 的站点配置（Caddy 的下游）
└── systemd/      备份与异地备份两组单元
```

**三个刻意的"不在这里"**：

| 没有 | 为什么 |
| --- | --- |
| `deploy/compose/` | 三个 compose 在**仓库根**，被 20+ 处引用（Dockerfile / Makefile / bootstrap / 所有 linux 脚本 / CI）。移动＝打断全部 |
| `deploy/ops/` | [`../scripts/ops/`](../scripts/ops/) 已是权威（22 个文件）。再建一个就是两个 ops 目录 |
| `deploy/logstash/` | 已随 ELK → PLG 删除，换成 [`alloy/`](alloy/)（见 [变更记录](../docs/changes/2026-10-03-ELK换PLG与deploy重构及Ansible引入.md)） |

`config_backup/` 是 P1 重构时的热备份，**P1 完成后已并入、目录已删除**（此处仅留此说明，不再出现在目录树里）。

---

## 脚本层与各层的关系（防止"两套并存"）

`install.sh` / `bootstrap.sh` / `prepare-host.sh` 目前**同时**做了 Day 0 与 Day 1。
引入 Ansible 之后的目标划分：

| 现有 | 归宿 | 现状 |
| --- | --- | --- |
| `install.sh` 的 apt 装包段 | → Ansible（`roles/baseline`） | **暂未删**，两者共存（2026-10-04 已对齐包清单） |
| UFW / sshd / sysctl | → Ansible（`roles/{firewall,hardening}`） | ✅ 已从 install.sh 移除，install.sh 只打印指引 |
| `prepare-host.sh` 的建卷 / nginx 站点 / 释放 :80 | **留在原处** | 它们是"让 Compose 能起来"的前置，属 **Day 1 的地基**，不是 OS 加固 |
| `bootstrap.sh --all` 的四阶段 | **保留** | 它是编排入口；Day 0 部分将来改为调用 Ansible |

> **共存是暂时的。** 最终形态是「不引入两套并存」：Ansible 就位并验证幂等后，
> `install.sh` 里的 apt/UFW/sshd 段删除，改为提示"Day 0 由 `deploy/ansible/site.yml` 负责"。
>
> **为什么这次没删**：一键部署链路（`install.sh --all`）目前是唯一被端到端验证过的路径
> （2026-10-03 裸机演练退出码 0）。在同一轮里既建 Ansible 又拆 install.sh，
> 出问题时无法判断是哪一半引起的。先让 Ansible 独立跑通幂等，下一轮再收口。
> 详见 [变更记录](../docs/changes/2026-10-03-P4-Ansible宿主机阶段与P5文档收尾.md) §6。

---

## 相关

- [一键部署入口](../scripts/install.sh) —— 目前的主链路
- [运维脚本体系](../scripts/ops/README.md) —— Day 2+ 的日/周/月任务
- [可观测性规格（阶段三）](../docs/16-stage3-observability.md) —— 监控与日志栈
