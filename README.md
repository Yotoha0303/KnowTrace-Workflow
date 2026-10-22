# KnowTrace-Workflow

![KnowTrace-Workflow 主页面](./images/knowtrace_main_1.png)

<p align="center">
  <a href="https://github.com/Yotoha0303/KnowTrace-Workflow/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Yotoha0303/KnowTrace-Workflow/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/Yotoha0303/KnowTrace-Workflow/actions/workflows/production-health-check.yml"><img alt="Production Health & Smoke Check" src="https://github.com/Yotoha0303/KnowTrace-Workflow/actions/workflows/production-health-check.yml/badge.svg"></a>
  <img alt="Next.js 16" src="https://img.shields.io/badge/Next.js-16-black?logo=next.js">
  <img alt="Go 1.25" src="https://img.shields.io/badge/Go-1.25-00ADD8?logo=go">
  <img alt="PostgreSQL 18" src="https://img.shields.io/badge/PostgreSQL-18-4169E1?logo=postgresql&logoColor=white">
  <a href="https://knowtrace-workflow.vercel.app"><img alt="Deployed on Vercel" src="https://img.shields.io/badge/Frontend-Vercel-black?logo=vercel"></a>
  <a href="https://go-user-system.onrender.com/readyz"><img alt="Auth on Render" src="https://img.shields.io/badge/Auth-Render-46E3B7?logo=render&logoColor=black"></a>
  <img alt="Database Supabase" src="https://img.shields.io/badge/Database-Supabase-3ECF8E?logo=supabase&logoColor=white">
  <a href="LICENSE"><img alt="Apache-2.0 License" src="https://img.shields.io/badge/license-Apache--2.0-blue.svg"></a>
  <a href="https://github.com/Yotoha0303/KnowTrace-Workflow/issues"><img alt="GitHub Issues" src="https://img.shields.io/github/issues/Yotoha0303/KnowTrace-Workflow"></a>
</p>

> 🚀 **Live Demo 在线体验**：[https://knowtrace-workflow.vercel.app](https://knowtrace-workflow.vercel.app)
>
> 体验账号可直接通过登录页注册，或使用内置演示账号浏览。生产环境由 **Vercel**（前端）+ **Render**（Go 认证后端）+ **Supabase**（PostgreSQL 18 云数据库）持续承载并运行自动化巡检。

KnowTrace-Workflow 是一个**“记录优先、AI 辅助整理、证据可追溯”**的认知溯源与可靠知识管理工作流系统（Cognitive Tracing & Verifiable Knowledge Workflow System）。

它首先保存用户的原始记录，再通过 AI 提供分类、摘要、主张候选、证据审查和主题综合等辅助能力。AI 输出与具体记录版本强绑定，不能未经人工确认覆盖原始内容；最终结论、独立复核和可靠发布始终由人掌控。

系统以**全栈 TypeScript 应用 + 独立 Go 认证微服务 + 多引擎数据层 + 全生命周期可观测体系**交付。支持**云原生生产矩阵（Vercel + Render + Supabase）**与**极简资源集约型自托管（2 vCPU VPS 单机 12 容器编排）**双轨部署形态。

## 业务痛点

知识工作流类产品普遍卡在四个地方，KnowTrace-Workflow 针对性地给出了工程解：

| 痛点 | 行业常见表现 | 本项目的处理方式 |
| --- | --- | --- |
| **记录动作被整理要求打断** | 保存前必须填标题、选分类、套模板，于是想法在入口就流失了 | 单一聚焦输入框，零必填字段；发生时间与描述对象可选填，保存即完成 |
| **内容积累后无法归位** | 关键词、经历、观察、研究问题混在一起，越攒越乱 | 分类、内容类型、描述对象三套正交维度；一条记录可属多个分类 |
| **AI 处理过程不可复现** | 只留最终结果，无法回答「用了哪版原文、哪个模型、哪版 Prompt」 | 每次调用持久化为 AI Run，绑定输入快照与内容哈希；建议与记录版本强关联，版本漂移即判 stale |
| **AI 结论越权** | AI 直接改写正式数据，人工审核沦为摆设 | AI 只产出 `pending` 候选；采纳是第二次独立鉴权动作，且从不直接写正式数据 |

## 系统能力

- **记录优先**：AI 失败不影响原始记录保存。
- **版本与可追溯性**：Capture、Revision、AI Run、Claim、Evidence 和可靠发布版本具有明确边界。
- **证据工作流**：支持来源检查、证据快照、人工结论、来源权威性评估和独立复核。
- **可判定的发布门槛**：`evaluateReleaseReadiness()` 八项检查全过才允许冻结为可引用的知识版本——权威性、来源独立性、复核者身份分离都落成布尔判定，而非口号。
- **Workspace 隔离**：记录、分类、主张、证据、检索、附件与迁移流程按 Workspace 进行服务端隔离。
- **统一检索**：支持记录、主张、证据、结论、分类、对象和时间等维度检索。
- **数据迁移**：支持带预检、版本化指纹和事务确认的 Excel 数据迁移，导入包中的可信状态一律安全降级重建。
- **统一认证**：内置独立的 Go 用户认证与 RBAC 服务，使用 PostgreSQL + Redis。
- **容器化运行**：Docker Compose 统一编排 Web、PostgreSQL（业务与认证两实例）和 Redis。
- **健康检查与恢复**：提供应用/认证 ready 检查、数据库备份、上传文件备份和隔离恢复验证。

## 全栈架构与双轨部署拓扑

KnowTrace-Workflow 面向生产设计了**双轨拓扑**：既具备**零服务器运维负担的云原生全托管矩阵**，又具备**低成本私有化的一台 2 vCPU VPS 自托管韧性**。

> **部署形态已裁定（[`ADR-0021`](docs/adr/0021-dual-track-deployment.md)，`2026-10-22`）**：
> **优先双轨**；若某轨在某些条件下不可行，**优先保留拓扑 A（托管）**作为兜底。
> **自托管资产（`compose.yaml` · `deploy/` · `scripts/linux/` · `scripts/ops/` · `Dockerfile` · `Makefile`）
> 一律保留，不得删除**——即使某段时间未验证，也只标注为「暂未验证 / 冷备」。
>
> ⚠️ **自托管轨的验证状态（如实）**：其最近一次真实运行在 **`2026-10-08` 之前**（VPS 停机且不续），
> 此后**未经真实运行验证**。因此本文档中拓扑 B 的描述应按「**未验证**」理解，而不是「当前在跑」。

### 拓扑 A：云原生生产架构（生产在线 Demo）

在线生产环境采用现代 Serverless 与微服务分离架构，天然具备全球分发加速与高可用特性：

```
浏览器 / 终端客户端
        │
        ├─────────────────────────────────────────┐
        │ (HTTPS 页面交互 / Server Actions)        │ (REST API / JWT 鉴权)
        ▼                                         ▼
[Vercel Serverless Platform]           [Render Managed Service]
Next.js 16 App Router (Node.js/Edge)   Go 认证与 RBAC 微服务 (Gin + GORM)
React / Tailwind CSS / Dynamic SEO     `/readyz` · 令牌刷新 · 权限状态机
        │                                         │
        └──────────────────┬──────────────────────┘
                           │ (TLS 连接池 / SSL 强加密)
                           ▼
               [Supabase Cloud Platform]
               PostgreSQL 18 托管数据库
               (主张 · 证据链 · 知识版本 · 账号与角色)
                           ▲
                           │ (每 12 小时定时探活巡检)
               [GitHub Actions Health Probes]
```

- **前端层（Vercel）**：托管 Next.js 16 App Router，开箱支持 `sitemap.xml` / `robots.txt` 动态 SEO 索引、OpenGraph 社交预览卡片与 Server Actions 流式渲染；
- **认证微服务（Render）**：Go 语言编写的高性能独立认证服务，提供 `/readyz` 存活探针、双 Token 无感刷新与细粒度 RBAC 拦截；
- **数据层（Supabase）**：云端托管的 PostgreSQL 18 数据库实例，22 个版本化迁移严格管理；
- **可观测巡检（GitHub Actions）**：`.github/workflows/production-health-check.yml` 定时巡检四大端点，持续输出 UTC 探活状态报告并防止 Render 免费实例休眠。

### 拓扑 B：单机 VPS 极简全栈自托管（私有化 / 局域网）

针对数据敏感或资源集约场景，仅需一台 2 vCPU / 4GB RAM 的 Linux 云主机即可运行完整业务与可观测栈：

```
浏览器 / 原生客户端
        │
        ▼
边缘层    Caddy（TLS 终结 + 安全响应头）
        │
        ▼
代理层    Nginx（限流、真实 IP 还原、指标路径边缘 404）
        │
        ▼
应用层    Next.js 应用（App Router + Server Action + BFF）  ◄──►  Go 认证服务（JWT / Refresh / RBAC）
        │                                                              │
        ▼                                                              ▼
数据层    PostgreSQL（业务、主张与证据链）                      PostgreSQL（账号与角色）+ Redis（会话与限流）
        │
        ▼
可观测层  Prometheus ──► Grafana ──► Alertmanager ──► 邮件告警
          Loki ← Alloy ← 边缘与全部容器日志
          Blackbox Exporter ｜ Node Exporter ｜ 结构化日志（Request ID 贯穿）
```

**四条正交链路各自独立演进**：

- **前端交互**：App Router 服务端渲染为主，Client Component 只承载局部交互状态；表单与变更经 Server Action 进入 Application Service，依赖方向单向且可静态校验。
- **后端服务**：业务规则收敛在 13 个 `src/features/*` 域内的 Application Service 层，与框架解耦；认证是**独立部署的 Go 微服务**，不是同进程模块。
- **数据存储**：PostgreSQL 承载业务、主张与证据链以及认证账号与角色；Redis 承载会话与限流。22 个版本化迁移只追加不修改。
- **容器化可观测**：12 个常驻容器统一编排；指标、日志与主动探测三路采集（应用私有 `/api/metrics` 需 Bearer Token），全部端点仅绑回环、经 SSH 隧道访问。

## 技术栈

### 应用

- Next.js 16 App Router
- TypeScript / React / Tailwind CSS
- PostgreSQL / Drizzle ORM
- Zod
- OpenAI / DeepSeek Provider Adapter

> AI 相关：运行时 provider 是 DeepSeek（及 OpenAI 兼容端点）。代码里的 `claude-*`
> 是 CC-Switch 路由的**入站协议别名**，不代表使用 Claude 模型。见 `docs/22-团队视角-接手与协作.md` §3.3。

### 认证

- Go / Gin / GORM
- PostgreSQL（ADR-0019）
- Redis
- JWT / Refresh Token / RBAC

### 交付与运行

- 云原生：Vercel + Render + Supabase
- 自托管：Linux / Ubuntu / Docker / Docker Compose / Nginx / Caddy
- GitHub Actions（CI 门禁 + 生产健康定时探活；镜像在部署侧构建，不经注册表推送）
- Makefile / Shell / Python / Ansible
- 备份、恢复、SHA-256 完整性校验

### 可观测性

日志侧采用轻量 **PLG** 路线，在资源集约型主机上与监控栈同等待遇常驻运行：

```
Prometheus → Grafana → Alertmanager
                 ↑
Loki ← Alloy ← Caddy / Nginx / Docker Logs
```

同时使用：

- Prometheus Metrics（12 个活跃抓取目标、29 条告警规则）
- Grafana Dashboard（数据源与面板 provisioning 化）
- Alertmanager 告警（含投递计数断言，见下）
- Blackbox Exporter（内部与公网双路径探测）
- Loki / Alloy（7 天保留，与 Prometheus 保留策略对齐）
- 结构化日志与 Request ID 贯穿（错误日志按 `route_type` / `route_path` 对照定位）
- Health / Readiness（应用、认证、数据库三层就绪判据）
- 有界压测与 P50 / P95 / P99

选型取舍见 `changes/` 与 [`docs/16-stage3-observability.md`](docs/16-stage3-observability.md)：Loki 无 JVM，实测常驻内存合计约 140 MiB，低于原 ELK 方案的按需启停心智负担。

## 量化工程收益

以下数字均可在仓库内对应文档中复核，出处逐行标注：

| 维度 | 实测结果 | 出处 |
| --- | --- | --- |
| 应用层规模 | `src/` 约 **26.3k 行**，13 个业务域，22 个版本化迁移 | `git ls-files` |
| 服务编排 | **12 个常驻容器**，统一 Compose 编排与健康门禁启动顺序 | [`docs/24`](docs/24-architecture-diagrams.md) §1 |
| 数据层恢复 | 隔离环境数据层恢复验证 **36 秒** | `docs/日常运维/2026-10-04-恢复演练记录.md` |
| 应用层基线 | nginx 前置 **1000 请求 / 并发 20**：成功率 100%、p50 65.8 ms、p95 161.0 ms、p99 542.9 ms | [`docs/15`](docs/15-stage2-vps-reliability.md) §5.4 |
| 低并发基线 | nginx 前置 **200 请求 / 并发 5**：RPS 211.4、p50 18.3 ms、p95 37.8 ms | 同上 |
| 资源占用 | 压测峰值 app 内存 154 MB / 限额 1.8 GB、CPU 1.23%，数据库全程 0% | 同上 |
| CI 门禁 | **4 个 job**：类型检查 + Lint + 单元测试 + 覆盖率采集 + 生产构建 + Go 测试 + 认证端到端 + 生产健康探活 | [`.github/workflows/`](.github/workflows/) |
| 测试资产 | 43 个与被测文件同目录的单元测试、18 个 Playwright 端到端 spec，另有认证服务 26 个 Go 测试文件与独立前端测试 | `git ls-files` |
| 可观测覆盖 | 12 个抓取目标全 UP、29 条告警规则、告警**投递计数**增量断言 | [`docs/16`](docs/16-stage3-observability.md) |
| 决策留痕 | **18 条 ADR**（含 superseded 关系）+ 变动前记录机制 | `docs/adr/`、`docs/changes/` |

其中两项值得单独说明，因为它们修的是「看起来正常」这一类最难发现的缺陷：

- **运行态同一性断言**：4 层健康检查 + 12 个抓取目标 + 29 条告警规则全绿，**仍然不能证明跑的是这一版代码**。部署脚本末尾因此断言运行态 revision，并区分「应用代码变了」与「只有文档落后」两种情况，避免告警被训练成忽略。
- **告警投递而非告警触发**：故障演练原先只断言「Alertmanager 收到了」，而 `group_wait` 让整组告警在首次投递前就被清除、**一封邮件都没发出**，演练却照样报 PASS。判据改为落在 `alertmanager_notifications_total{integration="email"}` 的增量上。

## 部署

Linux 服务器可以从仓库脚本开始：

```bash
sudo bash scripts/install.sh --domain knowtrace.example.org
```

部署流程包括：

```
主机预检
 ↓
系统依赖
 ↓
仓库更新
 ↓
数据卷
 ↓
应用配置
 ↓
Compose 部署
 ↓
监控栈
 ↓
运维任务
 ↓
全链路验证
```

支持 `--dry-run`，用于在真正执行前检查将要发生的操作。

部分高风险操作仍要求人工完成，例如 SSH 加固、UFW 和外部凭据配置，避免自动化脚本把远程服务器锁死。

监控、日志与数据库端点全部只绑 `127.0.0.1`，运维访问经 SSH 隧道；公网只暴露反向代理与 SSH 两个端口。详见 [`docs/16`](docs/16-stage3-observability.md)。

## 可靠性与运维

项目已建立并持续运行的实践：

- PostgreSQL（业务与认证）/ Redis / Uploads 备份，SHA-256 manifest 校验
- 隔离恢复验证（`RESTORE_VERIFY=PASS` 作为进入发布门禁的判据）
- 加密异地备份通道
- 定时备份与保留策略（每日窗口执行、至少保留最近 7 份）
- 有界健康检查与业务读取压测，保留 P50 / P95 / P99 与资源快照
- Blackbox 故障演练，含可恢复的告警链路验证
- Runbook、Bug / Incident / Postmortem 记录
- 发布前备份与验证、部署健康检查与回滚门禁

> **证据边界（面向接手与评估者）**：上述结果的采集环境为**单区域、单节点拓扑**，
> 覆盖当前样本与测试窗口。架构上应用层无状态、会话与数据层外置，
> 已具备向多副本水平扩展的前提；多可用区、跨区域容灾、正式 SLA 与容量模型
> 属于下一阶段的演进目标，不在当前已验证范围内。
> 逐项证据分级见 [`docs/21-path-to-100-percent.md`](docs/21-path-to-100-percent.md)。

## 范围边界

以下是**产品层面的有意取舍**，不是能力缺口：

- RAG、向量检索和知识图谱
- AI 自动联网补证
- AI 自动作出最终真实性结论
- 大规模团队复杂权限与计费系统
- 移动端应用（`/api/v1` 契约已交付，为未来客户端准备）
- 为“技术栈数量”而引入不必要的中间件

产品优先验证已有系统是否真正有效，而不是为了完成度继续堆功能。当前部署面向
**可信小群体或受保护网络**；直接对匿名公众开放需要额外的加固与容量验证，
相关前置条件见 [`SECURITY.md`](SECURITY.md)。

## 文档入口

完整文档索引：

[`docs/README.md`](docs/README.md)

| 目标 | 文档 |
| --- | --- |
| 产品范围 | [`docs/00-product-brief.md`](docs/00-product-brief.md) |
| 技术架构 | [`docs/06-architecture.md`](docs/06-architecture.md) |
| 架构图（10 张） | [`docs/24-architecture-diagrams.md`](docs/24-architecture-diagrams.md) |
| 运行、备份与恢复 | [`docs/11-operations.md`](docs/11-operations.md) |
| 移动端 API | [`docs/12-mobile-api.md`](docs/12-mobile-api.md) |
| 可靠性工程 | [`docs/15-stage2-vps-reliability.md`](docs/15-stage2-vps-reliability.md) |
| 可观测性 | [`docs/16-stage3-observability.md`](docs/16-stage3-observability.md) |
| 缺陷清单 | [`docs/19-product-defect-inventory.md`](docs/19-product-defect-inventory.md) |
| 真实验证路径 | [`docs/21-path-to-100-percent.md`](docs/21-path-to-100-percent.md) |
| 团队接手视角 | [`docs/22-团队视角-接手与协作.md`](docs/22-团队视角-接手与协作.md) |
| 用户信任边界 | [`docs/23-用户视角-使用与信任边界.md`](docs/23-用户视角-使用与信任边界.md) |

## 工程原则

- **写完 ≠ 验证通过**：代码存在不能代替真实运行证据。
- **备份 ≠ 恢复**：只有经过隔离恢复验证的备份才具有明确恢复价值。
- **监控 ≠ SRE**：Metrics、Logs、Traces 必须服务于发现、定位和恢复。
- **自动化建立在理解之上**：先手工验证流程，再自动化。
- **结论可证伪**：每条能力都标注证据等级，不把「已实现」写成「已验证」。
- **可靠性优先于技术堆叠**：优先解决已经出现的故障和验证缺口。

## 开源

KnowTrace-Workflow 自有代码采用 [Apache License 2.0](LICENSE)。

GitHub：<https://github.com/Yotoha0303/KnowTrace-Workflow>
