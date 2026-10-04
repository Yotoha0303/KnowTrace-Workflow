# KnowTrace-Workflow

![KnowTrace-Workflow 主页面](./images/knowtrace_main_1.png)

<p align="center">
  <a href="https://github.com/Yotoha0303/KnowTrace-Workflow/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Yotoha0303/KnowTrace-Workflow/actions/workflows/ci.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <a href="https://github.com/Yotoha0303/KnowTrace-Workflow/issues"><img alt="GitHub Issues" src="https://img.shields.io/github/issues/Yotoha0303/KnowTrace-Workflow"></a>
</p>

KnowTrace-Workflow 是一个**“记录优先、AI 辅助整理、证据可追溯”**的知识采集与可靠知识工作流系统。

它首先保存用户的原始记录，再通过 AI 提供分类、摘要、主张候选、证据审查和主题综合等辅助能力。AI 输出与具体记录版本绑定，不能未经人工确认覆盖原始内容；最终结论、独立复核和可靠发布由人完成。

当前项目同时作为一个 **AI 应用 + 多服务交付 + 可靠性工程实验项目** 持续演进。

> [!IMPORTANT]
> 项目仍在持续开发。当前重点是把已经实现的能力进行真实验证，并完善部署、可观测性、备份恢复、故障演练与自动化运维。公网运行能力必须以实际验证结果为准，不能仅凭“已经部署”视为生产级高可用系统。

## 项目定位

```
原始记录
   ↓
AI 辅助整理
   ↓
Claim / Evidence
   ↓
来源检查
   ↓
人工结论
   ↓
独立复核
   ↓
可靠发布
```

同时围绕运行可靠性形成：

```
代码
 ↓
CI
 ↓
构建 / 部署
 ↓
Metrics / Logs / Traces
 ↓
告警
 ↓
备份 / 恢复
 ↓
故障演练
 ↓
Runbook / Postmortem
```

## 当前能力

- **记录优先**：AI 失败不影响原始记录保存。
- **版本与可追溯性**：Capture、Revision、AI Run、Claim、Evidence 和可靠发布版本具有明确边界。
- **证据工作流**：支持来源检查、证据快照、人工结论、来源权威性评估和独立复核。
- **Workspace 隔离**：记录、分类、主张、证据、检索、附件与迁移流程按 Workspace 进行服务端隔离。
- **统一检索**：支持记录、主张、证据、结论、分类、对象和时间等维度检索。
- **数据迁移**：支持带预检、版本化指纹和事务确认的 Excel 数据迁移。
- **统一认证**：内置独立的 Go 用户认证与 RBAC 服务，使用 MySQL + Redis。
- **容器化运行**：Docker Compose 统一编排 Web、PostgreSQL、认证服务、MySQL 和 Redis。
- **健康检查与恢复**：提供应用/认证 ready 检查、数据库备份、上传文件备份和隔离恢复验证。
- **可靠性实验**：已建立 VPS 部署、压测、备份恢复、故障演练和可观测性阶段。

## 技术栈

### 应用

- Next.js App Router
- TypeScript / React / Tailwind CSS
- PostgreSQL / Drizzle ORM
- Zod
- OpenAI / DeepSeek Provider Adapter

> AI 相关：运行时 provider 是 DeepSeek（及 OpenAI 兼容端点）。代码里的 `claude-*`
> 是 CC-Switch 路由的**入站协议别名**，不代表使用 Claude 模型。见 `AGENTS.md`。

### 认证

- Go / Gin / GORM
- MySQL
- Redis
- JWT / Refresh Token / RBAC

### 交付与运行

- Linux / Ubuntu
- Docker / Docker Compose
- Nginx / Caddy
- GitHub Actions / GHCR
- Makefile / Shell / Python
- 备份、恢复、SHA-256 完整性校验

### 可观测性

当前 VPS 阶段采用轻量 **PLG** 日志路线，而不是继续使用资源开销较高的 ELK：

```
Prometheus → Grafana → Alertmanager
                 ↑
Loki ← Alloy ← Caddy / Nginx / Docker Logs
```

同时使用：

- Prometheus Metrics
- Grafana Dashboard
- Alertmanager 告警
- Blackbox Exporter
- Loki / Alloy
- OpenTelemetry / OTLP / Tempo
- Request ID / Trace Context
- Health / Readiness
- 有界压测与 P50 / P95 / P99

> 2026-10-03 起，VPS 阶段三由 ELK 调整为 PLG。原因是当前 1.8 GiB 级 VPS 的资源约束：Loki + Alloy 更适合常驻运行。具体变更记录见 `changes/` 与 `docs/16-stage3-observability.md`。

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

## 可靠性与运维

项目目前已经建立以下实践：

- PostgreSQL / MySQL / Redis / Uploads 备份
- SHA-256 manifest
- 隔离恢复验证
- 加密异地备份设计
- 定时备份与保留策略
- 有界健康检查和业务读取压测
- Blackbox 故障演练
- Runbook
- Bug / Incident / Postmortem 记录
- 发布前备份与验证
- 版本、部署、健康检查和回滚门禁

但这些证据**只代表当前单 VPS、当前环境和当前测试窗口**，不等同于高可用、长期容量、真实 SLA 或多节点生产能力。

## 当前明确不做

- RAG、向量检索和知识图谱
- AI 自动联网补证
- AI 自动作出最终真实性结论
- 大规模团队复杂权限与计费系统
- 移动端应用（API 已为未来客户端准备）
- 为“技术栈数量”而引入不必要的中间件

项目优先验证已有系统是否真正有效，而不是为了完成度继续堆功能。

## 文档入口

完整文档索引：

[`docs/README.md`](docs/README.md)

| 目标 | 文档 |
| --- | --- |
| 产品范围 | [`docs/00-product-brief.md`](docs/00-product-brief.md) |
| 技术架构 | [`docs/06-architecture.md`](docs/06-architecture.md) |
| 运行、备份与恢复 | [`docs/11-operations.md`](docs/11-operations.md) |
| 移动端 API | [`docs/12-mobile-api.md`](docs/12-mobile-api.md) |
| VPS 可靠性 | [`docs/15-stage2-vps-reliability.md`](docs/15-stage2-vps-reliability.md) |
| 可观测性 | [`docs/16-stage3-observability.md`](docs/16-stage3-observability.md) |
| 当前缺陷 | [`docs/19-product-defect-inventory.md`](docs/19-product-defect-inventory.md) |
| 真实验证路径 | [`docs/21-path-to-100-percent.md`](docs/21-path-to-100-percent.md) |
| 团队接手视角 | [`docs/22-团队视角-接手与协作.md`](docs/22-团队视角-接手与协作.md) |
| 用户信任边界 | [`docs/23-用户视角-使用与信任边界.md`](docs/23-用户视角-使用与信任边界.md) |

## 工程原则

- **写完 ≠ 验证通过**：代码存在不能代替真实运行证据。
- **备份 ≠ 恢复**：只有经过隔离恢复验证的备份才具有明确恢复价值。
- **监控 ≠ SRE**：Metrics、Logs、Traces 必须服务于发现、定位和恢复。
- **自动化建立在理解之上**：先手工验证流程，再自动化。
- **不包装实验能力**：明确区分单 VPS 实验、已验证能力和真正生产能力。
- **可靠性优先于技术堆叠**：优先解决已经出现的故障和验证缺口。

## 开源

KnowTrace-Workflow 自有代码采用 [MIT License](LICENSE)。

GitHub：<https://github.com/Yotoha0303/KnowTrace-Workflow>
