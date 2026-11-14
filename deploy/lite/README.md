# KnowTrace-Workflow 交付轻量版 (Customer Lite Edition)

- **适用场景**：个人独立研究员、一人工作室、小微企业私有化部署。
- **最低硬件需求**：1 核 CPU / 2GB 内存 / 10GB 磁盘空间（常驻内存实际消耗 < 800MB）。
- **编排文件**：[`compose.lite.yaml`](../../compose.lite.yaml)
- **部署脚本**：[`deploy/lite/run-lite.sh`](./run-lite.sh)

---

## 一、 为什么打造客户轻量版？

在 KnowTrace 完整的全链路生产环境（拓扑 B）中，为了满足企业级可观测性需求，系统集成了 Prometheus、Grafana、Loki、Alloy、Alertmanager、Blackbox-exporter 等全套监控栈，并配置了两个独立的 PostgreSQL 实例与多层网络隔离，常驻容器多达 12 个，内存消耗达 3.5GB 以上。

对于单兵客户、独立撰稿人或小型团队而言，繁重的监控栈不仅造成极大的硬件开销，更可能在低配云主机上引发内存溢出（OOM）崩溃。

**客户轻量版四大优化**：
1. **剥离纯运维监控栈**：彻底剔除 6 个 Prometheus/Loki 监控容器，普通业务用户无需维护监控指标；
2. **收敛数据库实例**：通过 [`deploy/lite/init-unified-db.sh`](./init-unified-db.sh) 在单一 PostgreSQL 18 实例内无缝承载业务库（`knowtrace_workflow`）与认证库（`go_user_system`）；
3. **单人丝滑模式 (`WORKFLOW_SINGLE_USER_MODE`)**：允许单人买家直接对 AI 生成的候选观点与证据链进行一键冻结发布，免去必须切换审核员账号的双人独立复核门禁；
4. **四容器核心极简闭环**：仅保留 `single-postgres`、`redis`、`auth` (Go 微服务) 与 `app` (Next.js 核心前端)。

---

## 二、 真实功能边界防翻车说明

在向客户交付或进行商务介绍时，必须坚守真实代码边界，**严禁过度包装**：
- **本项目明确不含**：RAG 向量数据库、上传百份 PDF 自动聊天问答、自动高亮定位 PDF 原始页码。
- **核心硬核价值**：
  1. **证据链绝对溯源**：对输入的权威文献、研报、合同碎片建立防篡改的快照与哈希存证；
  2. **AI 候选不越权**：大模型仅提供摘要与主张候选提取，必须由人类点击确认或修改，绝不允许 AI 自由篡改知识版本；
  3. **门禁发布法典**：八项严苛布尔指标全过才可冻结为可引用知识版本。

---

## 三、 一键部署指南

### 1. 启动服务
确保本地已安装 Docker 与 Docker Compose，在项目根目录运行：
```bash
./deploy/lite/run-lite.sh
```
或直接通过 Docker Compose 启动：
```bash
docker compose -f compose.lite.yaml up -d --build
```

### 2. 访问系统
- **主应用前端**：`http://localhost:3000`
- **Go 认证微服务**：`http://localhost:8082`
- **默认管理员凭据**：
  - 用户名：`KnowTrace-Admin`
  - 初始密码：`KnowTrace@123456`

### 3. 日常维护命令
- 查看运行状态：`docker compose -f compose.lite.yaml ps`
- 查看系统日志：`docker compose -f compose.lite.yaml logs -f app`
- 安全停止服务：`docker compose -f compose.lite.yaml down`
