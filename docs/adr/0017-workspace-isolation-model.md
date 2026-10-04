# ADR-0017：以 Workspace 为数据边界的应用层隔离模型

- 状态：accepted
- 日期：2026-10-04
- 扩展：ADR-0015
- 依据：`drizzle/0020_workspace_foundation.sql`、`drizzle/0021_workspace_audit_identity.sql`、
  `src/features/workspace/{policy,service}.ts`、`src/shared/workspace.ts`、
  `src/features/auth/access.ts`（均 2026-10-04 实读）

> 说明：本文是**补记**。Workspace 隔离已于 `0020`/`0021` 落地并进入生产，
> 但当时未留下决策记录。补记的目的不是复述实现，而是保住「为什么不那样做」——
> 数据隔离是最不该事后靠猜的一类决定。

## 背景

ADR-0015 建立的隔离模型是**按创建者**（creator-scoped）：`captures` / `categories` 保存
`created_by_id`，普通成员只见本人内容，`admin` 角色拥有实例级全局范围，管理员内容默认
`shared`。它解决的是「同一实例内成员之间不要互相看见」。

到 2026-10-02 前后，这个模型的边界开始不够用：

- 同一个人的内容无法按用途或项目分组，全部落在同一个平面里；
- 「多人共享一小块内容」无法表达 —— 只有「管理员对全体共享」这一种共享形态，
  没有「我和另外两个人」的中间粒度；
- `created_by_id` 是**人**的标识。当所有权需要转移、或一个协作单元需要独立生命周期时，
  以人为键的模型无处追加维度。

结论是需要引入一个**协作容器**：内容归属于容器，人通过成员关系进入容器。
问题是这个容器怎么落在既有的、已经在生产跑着数据的库上。

## 决策

### 1. 新增 `workspaces` 与 `workspace_memberships`，所有可归属的业务行加 `workspace_id`

- `workspaces`：`id`(uuid) / `name` / `slug`（CHECK `^[a-z0-9]+(?:-[a-z0-9]+)*$`，
  唯一）/ `created_by_id` / `created_by_name` / 时间戳。
- `workspace_memberships`：主键 `(workspace_id, actor_id)`，`role` ∈ {`owner`, `member`}，
  外键 `ON DELETE cascade`。
- 加 `workspace_id` 的表：`captures`、`categories`、`data_import_runs`、
  `data_import_objects`（`0020`），`ai_processing_runs`、`topic_syntheses`（`0021`）。
- `workspace_id` 外键一律 **`ON DELETE restrict`**。

### 2. 隔离在**应用层**强制，不启用数据库 RLS

判据是 `src/features/auth/access.ts` 里每条查询都显式带 `eq(captures.workspaceId, scope.workspaceId)`，
而 `0020`/`0021` 的迁移里**没有任何 `CREATE POLICY` / `ENABLE ROW LEVEL SECURITY`**。

### 3. 客户端提交的 Workspace 只是「优先项」，不是授权

`resolveActorWorkspace(identity, preferredWorkspaceId)` 的语义是：

- `selectWorkspaceMembership`（`policy.ts`）**只在身份确实是该 Workspace 的成员时**才采纳
  `preferredWorkspaceId`，否则返回 `null`；
- 拿到 `null` 后回落到「该身份的 owner 空间 → 该身份的第一个空间」；
- 最后 `requireWorkspaceMembership` 再查一次成员表，查不到抛 `WORKSPACE_ACCESS_DENIED`。

即：越权值不会报错，而是被**静默忽略并回落**——跨空间探测拿不到「不存在」与「无权限」的区别。

### 4. 历史数据整体并入一个固定 UUID 的默认空间

`LEGACY_DEFAULT_WORKSPACE_ID = "00000000-0000-4000-8000-000000000001"`
（slug `legacy-default`，名「默认空间」），写死为常量而非随机生成。

### 5. 迁移采用「加列带 DEFAULT → 回填 → `DROP DEFAULT`」三步

`0020` 加列时给 `DEFAULT 默认空间`；`0021` 在回填后把 `workspace_id` / `actor_id` /
`actor_name` 三列的 DEFAULT **全部撤掉**，使此后新写入必须显式给归属。

### 6. 账号首次出现时自愈式补成员关系

`ensureLegacyWorkspaceMembership`：新身份（迁移之后才首次登录的账号）在解析空间时
`INSERT ... ON CONFLICT DO UPDATE` 补一条默认空间成员，`isAdmin ? owner : member`。
这让 `0020` 的批量回填不必穷举「以后才会出现的人」。

## 被否的替代方案

| 方案 | 为什么否 |
|---|---|
| **启用 PostgreSQL RLS**（`CREATE POLICY` + `SET LOCAL app.workspace_id`） | 隔离会退化成「连接层的会话变量」——连接池复用下，忘了 `SET LOCAL` 就静默跨租户读；且现有测试与巡检都按应用层断言，RLS 会让失败模式从「抛错」变成「返回空集」，更难发现。数据库 RLS 是更强的承诺，但需要连接级配合，与本项目「单一事实源在应用服务层」的既有边界冲突。 |
| **把 `workspace_id` 做成 `NOT NULL` 且不加默认、直接迁移** | 生产库已有数据，加无默认的非空列会直接失败；先删后建则要停机。 |
| **`workspace_id` 外键用 `ON DELETE cascade`** | 删空间会连带删光里面的内容 —— 这是最不该发生的一类误删。`restrict` 强制先清空再删，且服务层 `deleteEmptyWorkspaceForActor` 已经做了「非空即拒」。 |
| **回填时把所有历史行塞进默认空间** | `0021` 明确不这么做：`ai_processing_runs.workspace_id` 跟随所属 `captures.workspace_id`，`topic_syntheses.workspace_id` 跟随 `categories.workspace_id`。理由是审计行应与其主体同属一个边界，否则一条 Capture 与它自己的 AI 运行会跨空间。 |
| **默认空间用 `gen_random_uuid()`** | 该 ID 会被单测与恢复演练引用，必须是可预期常量。固定 UUID 也让迁移可重复判定。 |
| **把 `created_by_id` 换成 `workspace_id`（替换而非新增）** | 人的归属与容器的归属是两个维度：同一个空间内仍需区分「谁创建的」。`0020` 是**叠加**维度，不是替换 —— 唯一索引从 `(created_by_id, …)` 变成 `(workspace_id, created_by_id, …)` 正说明这一点。 |
| **`decision` / `visibility` 等以枚举列表达共享** | `capture_visibility`（`private`/`shared`，`0017`）只表达「管理员对全体」，无法表达任意成员集合。成员集合必须是一张关系表。 |

## 后果

- **所有新增读写入口都必须解析 Workspace 并带上 `eq(…workspaceId, scope.workspaceId)`**；
  漏掉一处就是跨空间读。目前这是靠代码评审与 `policy.test.ts` 保证的，**没有数据库兜底**。
- `captures` 的唯一约束从 4 个维度（`workspace_id, created_by_id, idempotency_key` /
  `…, import_fingerprint` / `…visibility…` / `…created…`）重建，
  **`0016`/`0017` 建立的旧索引在生产库里已被取代**，读旧迁移时不要以为它们还在生效。
- `data_import_objects` 的唯一键在 `0020` 里再加一维 `workspace_id`；
  与 `0019` 的 `format_version` 合起来是五元组。
- `task_syntheses` 的 `decision` 决策字段新增 `decided_by_id` / `decided_by_name`（`0021`），
  使「谁驳回了这份综合」可追溯。
- `created_by_id` 维度**未删除**：空间内仍按创建者区分。ADR-0015 的可见性规则
  （成员只见本人 + 管理员共享内容）在当前空间内继续生效，Workspace 是它外面的第二层边界。
- 默认空间不可删除（`WORKSPACE_DEFAULT_DELETE_FORBIDDEN`），只有空空间可删除。
- **未解决**：本模型没有跨空间转移内容的路径，也没有成员邀请（成员只能靠
  首次登录自愈补进默认空间）。前者需要在两个空间同时满足唯一约束，后者属于待办，
  见 `docs/14-deferred-issues.md`。

## 相关

- [`../04-database-design.md`](../04-database-design.md) §10、§11（表结构与迁移演进）
- [`../06-architecture.md`](../06-architecture.md)（架构侧影响）
- [ADR-0015](0015-creator-scoped-data-access.md)（被本决策**叠加**而非取代）
- [ADR-0016](0016-native-client-auth.md)（原生客户端的 Workspace 头同属「优先项」语义）
