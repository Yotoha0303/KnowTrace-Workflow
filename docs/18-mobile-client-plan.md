# 多平台应用开发方案

本文件落实 `docs/00-product-brief.md` 中「移动 App UI 暂不实现」之后的阶段目标：在同一套服务端之上交付原生多平台客户端，而不是另起一套业务实现。范围与 `docs/14-deferred-issues.md` 排定的 `US-18 / 移动 App` 对齐。

已确定的形态决策由 ADR-0016 记录，本文只描述执行范围、顺序与验收。

## 1. 起点判定

服务端已经具备多平台客户端所需的大部分基础，这是本方案成立的前提：

| 能力 | 现状 |
|---|---|
| 版本化 JSON 契约 | `/api/v1` 覆盖记录生命周期与知识读取，见 `docs/12-mobile-api.md` |
| 幂等创建 | `Idempotency-Key`，冲突返回 `409` |
| 乐观锁 | `expectedVersion` / `ETag` / `If-Match`，冲突返回 `409` 并附 `currentVersion` |
| 统一响应与错误码 | `{ ok, data, error, meta }`，`fieldErrors` 可用 |
| 请求追踪 | `X-Request-Id` 双向透传 |
| 业务规则与框架解耦 | Application Service 层，Web 与 API 共用 |
| 契约回归 | `tests/e2e/mobile-api.spec.ts` 已覆盖完整生命周期 |

结论：**复用服务端，不重写。** 缺的不是能力，是三处接口形态。

## 2. 三处缺口

### 缺口一：认证对原生客户端不成立（已解决，见 ADR-0016）

原实现是 HttpOnly Cookie + Proxy 门禁（`src/features/auth/response.ts`、`src/proxy.ts`）。原生 App 没有浏览器 Cookie 罐，`Set-Cookie` 无法可靠落盘。

现状：`/api/v1/auth/*` 已支持原生令牌模式——请求带 `X-Client: native` 时响应体直接返回 access/refresh 令牌；`Authorization: Bearer` 由服务端重新向认证后端校验，不信任任何客户端提交的身份或 Workspace（`src/features/auth/access.ts`）。

### 缺口二：写接口只覆盖了 Capture

`/api/v1` 当前可写的只有 Capture 的增删改。以下操作在 Web 端走 Server Action，**原生 App 无法调用**：

- 触发 AI 整理（`src/features/ai-processing/`）
- 证据图片上传——`src/app/api/evidence-images/[id]/route.ts` **只有 GET**
- 主张与证据的创建与审核（`src/features/claims/service.ts`）
- Category 增删改名、Capture 归档与恢复

### 缺口三：AI 调用是「请求内等待」

`docs/06-architecture.md` 第 6 节列出了迁移到 Worker 的触发条件。移动端一次命中三条：模型调用超时、需要重试、弱网下请求不稳。

## 3. 阶段划分

### M0 骨架与决策

- ADR-0016（客户端形态与认证边界）——**已完成**。
- 抽取契约层到 `packages/contracts`：`/api/v1` 的 Zod schema 目前内联在各 route 中，服务端与客户端需要共用一份。
- 仓库改为 pnpm monorepo（`pnpm-workspace.yaml` 现仅含 `allowBuilds`/`overrides`，增加 `packages:` 即可）。

验收：`pnpm typecheck` 通过，Web 端行为零变化。

### M1 服务端补齐

1. ~~原生令牌模式认证~~——**已完成**。
2. `POST /api/evidence-images/:evidenceId`：multipart 上传，复用 `prepareEvidenceImage` 与 `uploadEvidenceImage`。
3. 补齐写接口：categories 增删改、captures 归档/恢复、claims/evidence 写。
4. AI 触发异步化：`POST /api/v1/ai-runs` 返回 runId，`GET /api/v1/ai-runs/:id` 取状态与建议。

验收：`tests/e2e/mobile-api.spec.ts` 扩展出图片上传、AI 异步、原生认证三条链路并全部通过。

### M2 App 首期闭环

范围：登录 → Workspace 选择 → 快速记录 → 列表/详情 → 搜索 → 图片 Evidence 上传。

离线底座同期落地：

- 本地 SQLite 写入队列，先落本地再同步。
- 重复提交消解复用 `Idempotency-Key`，冲突检测复用 `expectedVersion`——服务端已现成。
- 冲突策略首期只做「提示并显示两版」，不做自动合并。

### M3 语音输入（FEAT-005）

按 ADR-0016 走**端上转写**：使用系统语音识别，转成文本后进入现有 `/api/v1/captures` 链路，服务端无需新增音频存储与转写通道。

### M4 结构化模板（FEAT-004）

现有 AI 建议产出的是候选字段（标题、摘要、内容类型、分类、语义单元），缺的是可套用的模板骨架。做法：模板作为一等对象，AI 建议按模板槽位填充，用户在界面上逐槽取舍。

### M5 桌面端（可选）—— **前提待决，暂缓实施**

> **2026-10-05 更正**：本节原先写「Tauri 套现有 Web 构建产物；非必要不单独开发」。
> 实测读 `next.config.ts` 后确认**这句话的前提不成立**：产物是
> `output: "standalone"`（一个 Node 服务），而 Tauri 的 `frontendDist` 吃静态目录。
> 决策与判据见 **[ADR-0018](../adr/0018-desktop-shell-prerequisites.md)**，
> 前提由 [`scripts/desktop/preflight.sh`](../../scripts/desktop/preflight.sh) 持续断言。

一句话版：**桌面端缺的是决策，不是代码。** 三条路里
静态导出（T1）已被否（违反 ADR-0016），剩下 T2（进程内 Node sidecar，可离线，较重）
与 T3（加载远程 URL，轻，但离线不可用）。**选择的判据只有一条**：
桌面端是否需要「断网也能记录」。若无相反的产品理由，倾向 T2 ——
因为 `docs/18` §M2 已把移动端的离线队列列为必做项，两端行为不一致会破坏「随手记录」这条主路径。

在 ADR-0018 从 `proposed` 转为 `accepted` 之前，**M5 不进入实施**。

## 4. Bug 与 App 的先后关系

| 条目 | 时机 | 理由 |
|---|---|---|
| BUG-002 错误码 | **已完成** | 上游业务码现在被翻译为语义错误码，限流/停用不再伪装成密码错误；App 登录页同样依赖它 |
| BUG-003 图片格式 | M1 必做 | iOS 相机直出为 HEIC，与图片上传接口是同一处改动 |
| BUG-001 保存异常 | M2 期间复现 | 离线链路会重写这部分前端逻辑，先复现再决定是会话续期还是连接池问题 |
| FEAT-006 邮箱注册 | M4 之后单排 | 需改 go-user-system 账号模型（当前注册只有用户名与密码），并行会互相阻塞 |
| FEAT-007 | 先补全定义 | 原文现象与验收标准整段误填了 FEAT-006 的内容 |

详见 `docs/17-mobile-client-bugs-and-features.md`。

## 5. 风险

1. **AI 超时**（高）：M1 必须完成异步化。
2. **HEIC**（高）：BUG-003 的真实根因大概率在此。
3. **弱网上传**（中）：10 MB 上限在移动网络下需要重试队列或分片。
4. **凭据存储**（中）：原生必须使用 Keychain/Keystore，不得使用 AsyncStorage。
5. **离线冲突**（中）：机制够用，但需提前定 UI 策略，否则会出现大量「保存失败」误报。
6. **AI 凭据模型**（中）：当前 API Key 仅在单次服务端调用内传递；若 App 要支持自带 Key，该链路需重新设计。

## 6. 验收口径

沿用 `docs/08-test-and-acceptance.md` 的门槛：TypeScript、ESLint、单元测试、生产构建和 GitHub CI 是每次提交的必过项。客户端新增能力必须同时补齐 `/api/v1` 契约测试，不允许出现只有 App 才能验证的接口。
