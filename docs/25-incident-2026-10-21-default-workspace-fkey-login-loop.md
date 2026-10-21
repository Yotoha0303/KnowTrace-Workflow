# 2026-10-21 生产环境认证死循环事故：成因与复盘 (INC-2026-10-21-01)

| 项 | 值 |
| --- | --- |
| 事故标识 | `INC-2026-10-21-01` · 生产环境登录循环故障 |
| 影响环境 | 生产环境 `https://knowtrace-workflow.vercel.app` + `go-user-system` |
| 发生时间 | 2026-10-20 15:30Z ~ 2026-10-21 18:10Z |
| 发现方式 | 真实用户在线注册后尝试登录，发现“可注册但无论如何无法登录” |
| 故障定级 | **P0**（核心认证阻断，已注册与新注册用户均无法进入系统） |
| 恢复时间 | 2026-10-21 18:10Z（恢复默认空间锚点并完成端到端全生命周期自动化实测验证） |

---

## 1. 故障现象与用户感知

- **外部表现**：
  - 用户在 `/register` 可以正常注册新账号（如账号 `测试测试`）。
  - 用户在 `/login` 输入正确的账号与密码并点击登录，界面加载动画结束后，页面并未进入个人工作区仪表盘，而是重新停留在 `/login`，或被 307 重定向弹回登录页。
  - 无论重试多少次、无论换任何新注册账号，均无法登录进入系统。

---

## 2. 直接成因：数据库外键违约引发首页 500 崩溃

Next.js 在处理登录表单提交时，调用 `/api/v1/auth/login`：
1. **认证微服务正常响应**：Go 认证微服务（`go-user-system`）密码比对通过，正确更新了数据库中的 `last_login_at`，签发了有效 JWT，并由 Next.js BFF 将 `knowtrace_workflow_access_token` 与 `refresh_token` 写入浏览器 Cookie（HTTP 200）。
2. **客户端跳转首页**：登录成功后，前端执行 `router.replace("/")` 导航到首页。
3. **服务端加载工作区抛出致命异常**：
   首页与根布局 `RootLayout`（`src/app/layout.tsx`）在服务端执行时调用 `currentDataAccessScope()` ➔ `resolveActorWorkspace(identity)`。
   在该函数内部，为了向下兼容迁移并给所有新旧用户提供默认空间，调用了保底逻辑 `ensureLegacyWorkspaceMembership`（`src/features/workspace/service.ts:233`）：
   ```typescript
   await db
     .insert(workspaceMemberships)
     .values({
       workspaceId: LEGACY_DEFAULT_WORKSPACE_ID, // '00000000-0000-4000-8000-000000000001'
       actorId: identity.actorId,
       actorName: identity.actorName,
       role: identity.isAdmin ? "owner" : "member",
     })
     .onConflictDoUpdate({ ... });
   ```
4. **数据库阻断报错**：
   PostgreSQL 抛出外键违约异常：
   ```text
   PostgresError: insert or update on table "workspace_memberships" violates foreign key constraint "workspace_memberships_workspace_id_fkey"
   Key (workspace_id)=(00000000-0000-4000-8000-000000000001) is not present in table "workspaces".
   ```
5. **导致 Next.js 根路径返回 500**：
   服务端渲染崩溃，HTTP 状态码为 500 Internal Server Error。客户端路由跳转被中断拒绝，直接回退并停留在登录页。

---

## 3. 根因穿透（5 Whys）

1. **Why 1：为什么用户登录后会被弹回登录页？**
   - 因为前端跳转目标 `/` 返回了 500 Internal Server Error，Next.js App Router 无法完成导航。
2. **Why 2：为什么 `/` 会报 500 崩溃？**
   - 因为 `layout.tsx` 执行 `ensureLegacyWorkspaceMembership` 向 `workspace_memberships` 插入记录时触发了外键违约异常。
3. **Why 3：为什么会外键违约？**
   - 因为外键引用的目标 `workspaces` 表中，根本不存在 `00000000-0000-4000-8000-000000000001`（系统默认空间锚点）这一行。
4. **Why 4：为什么默认空间锚点在数据库中不存在？**
   - 2026-10-20 15:28Z 在执行线上演示数据初始化时，执行了临时播种脚本 `seed_demo.mjs`。该脚本为了清空旧演示数据，执行了无差别的 `DELETE FROM workspaces;`，并将新生成的演示数据挂载到了一个全新的 `randomUUID()` 随机空间下。
5. **Why 5：为什么脚本会去全表清空 `workspaces`？（根本认知缺陷）**
   - **认知混淆**：脚本编写者将 `workspaces` 视为了“纯粹的临时业务数据表”，未意识到 `00000000-0000-4000-8000-000000000001` 是硬编码在代码、迁移（`0020_workspace_foundation.sql`）与架构契约中的**系统底层不可变基座锚点**。
   - **防御性缺失**：数据库层未对该硬编码系统保留 ID 设置不可删除防护，导致运维/开发脚本能够单行语句物理抹除系统基座。

---

## 4. 处置动作与实测验证

| 步骤 | 动作 | 验证依据 |
| --- | --- | --- |
| 1. 恢复核心基座锚点 | 以事务原子化在 Supabase 中恢复 `00000000-0000-4000-8000-000000000001` 工作区（名称：`KnowTrace 核心工程与架构工作区`） | SQL 实测查询确认行存在 |
| 2. 存量业务资产归拢 | 将既有高质量技术捕获与分类关联的 `workspace_id` 迁移至默认空间，删除失效的临时空间 | SQL 查询验证 2 条核心捕获与 3 项分类均已安全挂载至默认空间 |
| 3. 用户成员关系修复 | 为存量管理员（`yotoha`）及已注册普通用户补齐该空间的成员关系（`owner` / `member`） | `workspace_memberships` 查询验证 |
| 4. 机器原生端到端闭环验证 | 编写独立探测脚本，自动创建全新随机用户 `user_e2e_1792606192369`，串行执行【注册 ➔ 登录 ➔ 提取 Cookie ➔ 带 Cookie 访问根路径 `/`】 | 状态码由 **500 彻底转为 200 OK**，HTML 成功渲染完整的 `AppShell` 且包含该新用户名 |

---

## 5. 防复发改进项（Action Items）

1. **数据库层硬约束（P1）**：
   在 PostgreSQL 中为 `workspaces` 表建立行级防删除触发器或 RLS/Check 约束，任何对 ID `00000000-0000-4000-8000-000000000001` 的 `DELETE` 操作由数据库内核级强行报错阻断。
2. **代码容错与自愈加固（P2）**：
   在 `src/features/workspace/service.ts` 中，`ensureLegacyWorkspaceMembership` 执行前增加存在性快速检查与自愈创建，即使数据库出现异常缺失也能自动幂等建回，杜绝 500 级崩溃。
3. **数据管理脚本纪律（P1）**：
   严禁在任何数据初始化或测试脚本中编写无条件的 `DELETE FROM workspaces`；所有数据管理脚本必须显式排除系统保留锚点（`WHERE id != '00000000-0000-4000-8000-000000000001'`）。
