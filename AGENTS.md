# AGENTS.md — KnowTrace-Workflow 协同研发与交付约束规范

> **项目定位**：全链路可追溯知识工作流平台（Next.js 15 + TypeScript + Drizzle ORM + PostgreSQL + Redis + Go 认证子系统）。
> 本文件是本仓库协同研发的**唯一约束规范**。所有 AI 智能体与开发者在每次介入会话时必须优先读取本文件，并严格受其约束。

---

## 0. 双交付形态与拓扑约定

### 0.1 客户极简交付版 (Lite Edition - 首选商业交付形态)
- **核心编排**：`compose.lite.yaml`
- **目标场景**：个人研究员、独立团队及低配云服务器（1C2G / 2C4G），常驻内存 `< 800MB`。
- **服务组成（4 容器）**：
  1. `single-postgres`：单个 PostgreSQL 18-alpine 实例，双库隔离承载 `knowtrace_workflow` 与 `go_user_system`；
  2. `redis`：轻量缓存与会话状态中继；
  3. `auth-server`：Go 用户认证中心服务；
  4. `app-server`：Next.js 生产应用主服务。
- **初始化与启动入口**：
  - 双库与角色初始化：`bash deploy/lite/init-unified-db.sh`
  - 一键启动与环境自检：`bash deploy/lite/run-lite.sh`
  - 交付运维操作手册：`deploy/lite/README.md`

### 0.2 完整监控生产版 (Full Observability Edition)
- **核心编排**：`compose.yaml` + `compose.observability.yaml`
- **目标场景**：企业级高可用集群与深度 SRE 可观测性环境。
- **服务组成（10 容器）**：包含 Alloy、Prometheus、Grafana、Loki、Alertmanager 与独立认证数据库实例。

---

## 1. 四大不可妥协纪律 (Zero Tolerance Disciplines)

### D1 · 读到才算，严禁推断 (Read First, Zero Guesswork)
- 严禁从未经验证的文件名或接口名臆测系统行为。所有结论必须基于实际读取的文件内容或命令的真实 stdout。
- 严禁为了“看起来高大上”向客户虚假承诺未实现的功能（如严禁虚假声称具备完整的自主 RAG 引擎，如实标注为基于 Drizzle 与结构化数据的知识追溯引擎）。

### D2 · 数据库版本受控与双库权限隔离
- 数据库变更必须通过 Drizzle 迁移脚本受控管理；
- 在单实例交付版中，必须严格恪守非特权原则：`go_user_system` 用户只拥有认证库的属权，严禁授予超级管理员权限。

### D3 · 零破坏性与可证伪性 (Falsification & Negative Cases)
- 任何 bugfix 或功能迭代，必须提供正向验证与负向防御用例；
- 严禁随意引入庞大的第三方依赖包，保持前端与容器镜像轻量化。

### D4 · 极简工程表达与零装饰噪音 (CASE-ARCH-03)
- 文档与代码注释中绝对禁止装饰性 Emoji 符号；
- 时间统一采用规范时间格式（`YYYY-MM-DD HH:MM`）；
- 涉及网络协议与架构图表，仅使用白名单 Mermaid 语法（`flowchart TD` / `flowchart LR`）。

---

## 2. 常用开发与测试指令

### 依赖安装与本地运行
```bash
pnpm install
pnpm dev
```

### 数据库迁移执行
```bash
pnpm db:generate
pnpm db:migrate
```

### 单元测试与端到端测试
```bash
pnpm test
pnpm test:e2e
```

### 客户轻量版离线演练
```bash
docker compose -f compose.lite.yaml config
bash deploy/lite/run-lite.sh
```
