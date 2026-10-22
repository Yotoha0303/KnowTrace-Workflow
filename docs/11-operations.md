# 运行、备份与恢复

> **部署形态**（[`ADR-0021`](adr/0021-dual-track-deployment.md)，`2026-10-22` 裁定）：**优先双轨**——
> 拓扑 A（Vercel + Render + Supabase）为**生产在线**形态；拓扑 B（本文件所述的单机 Docker Compose）为
> **自托管**形态。若某轨不可行，**优先保留拓扑 A**。
> **本文件的自托管内容一律保留、不得删除**；但请注意：拓扑 B **自 `2026-10-08` 起未经真实运行验证**，
> 下列步骤应按「**待复验**」执行——首次复跑时请把实际读数回填，而不是照抄本文当结论。

## 1. 部署边界

KnowTrace-Workflow 的统一容器栈默认启用仓库内 `services/go-user-system` 认证后端，并默认把 Web 与认证端口绑定到 `127.0.0.1`。账户中心复用 Go 后端的资料、密码和 RBAC 管理；`admin` 角色拥有实例级全部业务数据范围，管理员创建内容默认共享；普通成员可管理本人内容并只读查看管理员共享内容，成员私有内容之间仍隔离。Workspace/组织分组和更细粒度业务角色尚未实现。公网部署仍需要 HTTPS、`AUTH_COOKIE_SECURE=true`、网络隔离和安全运维，不能只凭“出现登录页”就声称可安全暴露。

统一启动：

```powershell
make up
# 或
.\scripts\start-all.ps1
```

首次启动会在 `.env` 生成 MySQL/JWT 随机密钥，**以及管理员随机口令**，并在尚无管理员时创建管理员 `KnowTrace-Workflow`。口令默认随机；想用固定值 `KnowTrace-Workflow@123` 需显式传 `--use-fixed-admin-credential`（Linux）/ `-UseFixedAdminCredential`（PowerShell），那**只适合绑定 `127.0.0.1` 的本机首次登录**。2026-10-02 之前默认就是那对固定凭据，而它写在公开 README 里，公网机器因此会带着公开口令上线。重复启动只检查管理员是否已存在，不会把用户后来修改的密码重置回默认值；修改密码后，MySQL 中的 bcrypt 哈希是当前凭据，`.env` 中的值仍只是初始化默认值。需要独立复核时仍须准备另一个不同账号；结论作者与复核者不能共享账号。修改密码会使该账号的全部会话失效；当前认证后端不提供设备会话列表和单设备撤销接口。管理员角色分配依赖数字用户 ID，因为后端尚无用户列表接口。

## 2. 容器运行

根级 `Makefile` 是统一入口；`make up`、`make down`、`make restart`、`make ps` 和 `make logs` 分别管理完整栈。直接调用 Compose 前必须先运行 `make init` 生成本机密钥。

启动顺序：MySQL → go-user-system Migration → 幂等管理员初始化 → Redis 与认证后端 → PostgreSQL → KnowTrace-Workflow Migration → 中断 AI Run 恢复 → Next.js。任一步失败，依赖服务不会以“看似可用”的状态继续启动。

健康检查：

```text
GET /api/health/live   进程存活，不依赖数据库
GET /api/health/ready  应用与 PostgreSQL 均可用
GET /api/health        兼容旧检查，语义等同 ready
GET :8082/readyz       go-user-system、MySQL 与 Redis 就绪
```

Compose 使用 ready 端点判断应用健康。

## 3. 中断 AI Run 恢复

`AI_RUNNING_STALE_AFTER_MS` 默认 300000，允许范围为 60000～86400000。启动维护会把超时的 `running` Run 更新为：

```text
status       failed
error_code   AI_RUN_INTERRUPTED
completed_at 当前时间
latency_ms   从 started_at 计算
```

手动执行：

```powershell
pnpm db:maintenance
```

## 4. 备份

页面中的 Excel 导出属于可移植数据交换，只覆盖记录、对象、时间、状态、分类和分类关联。它不能恢复 AI 处理历史、主张证据链、审核发布快照或图片，因此不得替代下述 PostgreSQL 与 `data/uploads` 备份。Excel 导入必须先预检；预检结果会保存为 `data_import_runs`，人工确认后才以单个数据库事务写入。

```powershell
make backup
```

统一备份分别生成 PostgreSQL custom-format 归档、带 SHA-256 manifest 的 go-user-system MySQL SQL 归档，以及 `data/uploads` 图片 ZIP。已有备份不会被覆盖，`backups/` 已加入 `.gitignore`。Excel 导入导出不能替代其中任何一项。

这些备份包含全部知识内容、账号资料、密码哈希、会话元数据和证据图片，应视为敏感文件。至少保留一份不与运行机器共盘的加密副本。

## 5. 恢复

恢复是破坏性操作。先复制一份当前备份，再显式确认：

```powershell
.\scripts\restore.ps1 `
  -BackupPath .\backups\knowtrace-20260815-000000-abcd1234.dump `
  -ConfirmDatabaseReset
```

脚本会：校验归档 → 停止 app → 清理并重建 `knowtrace` 数据库 → 恢复归档 → 重新启动 app。恢复后检查：

```powershell
Invoke-WebRequest http://localhost:3000/api/health/ready
docker compose logs --tail=100 app
```

首次验证新备份时，应恢复到隔离临时数据库，不要直接覆盖当前数据。2026-08-15 已执行一次隔离恢复演练，确认 4 个 Migration 记录以及 `captures`、`claim_reviews` 等核心表可恢复。

## 6. 升级步骤

1. 执行 `make backup` 并保存三类输出路径。
2. 运行 `make check`。
3. 执行 `make up`。
4. **执行属主修复**（见第 7 节）：`sudo PROJECT_DIR=/opt/knowtrace bash scripts/linux/fix-uploads-ownership.sh`
5. 检查两个 ready 健康端点、两套 Migration 日志和关键 Playwright 流程。
6. 出现不可兼容问题时，停止应用并从升级前备份恢复。

## 7. 证据图片目录属主

> **先看驱动**（`ADR-0020`）：`EVIDENCE_IMAGE_STORAGE=vercel-blob` 或环境中存在
> `BLOB_READ_WRITE_TOKEN` 时，图片写入**对象存储**、不落本地磁盘，**本节整节不适用**——
> 此时启动自检只检查 Blob 凭据是否在场，不再探测本地目录。下面所有内容只对**本地驱动**
> （Docker / VPS 单机，默认）成立。

`compose.yaml` 把 `./data/uploads` 绑定挂载到 `/app/data/uploads`，**这会盖掉 Dockerfile 中 `chown -R nextjs:nodejs /app/data` 的结果**。宿主机首次 `docker compose up` 时该目录由 root 创建，而容器内进程是 `uid=1001(nextjs) gid=65533(nogroup)`，于是 `writeEvidenceImage` 的 `writeFile(..., {flag:"wx"})` 每次都抛 `EACCES`，图片上传完全不可用。

这个故障在 2026-09-13 与 09-19 静默发生了 42 次（只在图片上传请求层表现为「上传失败」），2026-09-30 定位并修复。

**每次 `docker compose up` 之后、以及从备份重新落地 `data/uploads` 之后，都要执行：**

```bash
sudo PROJECT_DIR=/opt/knowtrace bash scripts/linux/fix-uploads-ownership.sh
```

脚本幂等，属主正确时不产生变更，并会以目标 uid 真实写入一个探测文件确认；成功输出 `UPLOADS_OWNERSHIP=PASS`。

应用启动时也会自检该目录：不可写会打印带修复命令的显式告警（见 `src/server/startup-checks.ts`），不会再静默失败。

### 7.1 云端部署（Vercel 等无状态平台）

容器文件系统只读、且实例重启/重新部署即清空，因此**不能**用本地驱动。切换方式：

1. 在 Vercel 项目的 Storage 中创建 **Private** Blob 存储并连接到项目
   （项目环境变量会自动获得 `BLOB_READ_WRITE_TOKEN`）。
2. 确认 `EVIDENCE_IMAGE_STORAGE` 为空（留空即按凭据自动选择 `vercel-blob`）或显式设为 `vercel-blob`；
   `EVIDENCE_IMAGE_BLOB_ACCESS` 保持 `private`——证据图片是用户隐私数据。
3. 部署后触发一次上传：浏览器应出现一次**直传**（对象存储域名），随后页面刷新出缩略图。
4. **判据（可证伪）**：上传一张 **>4.5 MB** 的图片。旧实现必败（平台 413
   `FUNCTION_PAYLOAD_TOO_LARGE`），新实现应成功——这正是「只换存储驱动」与「直传」的分水岭。

排查线索：启动日志出现「缺少 `BLOB_READ_WRITE_TOKEN`」= 存储未连接；
上传报「Failed to retrieve the client token」= 签发令牌被拒（多数是证据状态/数量门槛，见 `/api/evidence-images/upload` 的 GET 预检）。
本项外部动作见 `CICD-待完成.md` 的 **E5**。

## 8. 本节之外：运维总入口

本文件只覆盖**应用侧**的部署边界、容器运行、备份恢复与属主修复。监控告警、巡检
定时器、异地备份和事故复盘不在本文件内，入口如下：

| 要做什么 | 去哪里 |
| --- | --- |
| 运维全局索引、VPS 连接方式、脚本体系 | `../KnowTrace-ops/notes/`（先读 `04-文档索引与任务.md`） |
| 运维执行记录与事故复盘 | `../KnowTrace-ops/docs/` |
| 监控栈部署与告警链路 | [`16-stage3-observability.md`](16-stage3-observability.md) |
| 备份、恢复、压测与故障迭代 | [`15-stage2-vps-reliability.md`](15-stage2-vps-reliability.md) |
| 从零部署 | [`../scripts/install.sh`](../scripts/install.sh)（一键部署）；手工步骤见 `../scripts/bootstrap/README.md` |
| 运维脚本用法与说明 | `../scripts/ops/README.md`、`../scripts/bootstrap/README.md` |
| 历史部署档案（已移出仓库） | `../KnowTrace-ops/archive/` —— 阶段一至三的学习档案。**为什么移出**见该目录 `README.md` |

> [!IMPORTANT]
> 部署命令的**权威写法**在 [`../CONTRIBUTING.md`](../CONTRIBUTING.md) 的「部署验证」一节：
> 用 `scripts/linux/deploy-observability.sh --build-app`，**不要手写 `docker compose up -d --build`**。
> 漏掉 `--build-app` 会只重启旧镜像却报成功。
