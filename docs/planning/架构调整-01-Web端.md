# 架构调整 · Web 端（Next.js → Vite SPA + Tauri 2）

| 项 | 值 |
| --- | --- |
| 建立时间 | `2026-10-18` |
| 依据 | 用户裁定 + 工作区根 `前端技术栈调整建议.md` |
| 共享契约 | [`架构调整-00-共享契约.md`](架构调整-00-共享契约.md) —— **本文不重复它** |
| 关联 ADR | 需新增 `ADR-0020`（ADR-0004 的替代）· `ADR-0021`（Tauri 2，替代 `ADR-0018` 的 T2） |
| 状态 | **草案** —— ADR 未落地前不得开工 |

---

## 1. 目标形态

**`apps/web` = Vite + React 19 + TypeScript**，同时作为 **Web 控制台**与 **Tauri 2 桌面端的渲染层**。

```
apps/web/
├── src/                    # React SPA
├── src-tauri/              # Tauri 2（Windows / macOS / Linux）
└── package.json
```

**关键取舍**：**同一个 `src/` 既跑浏览器也跑 Tauri WebView**——端差异靠 `src-tauri` 与运行时探测，不靠两套代码。

---

## 2. 与现状的差异（**迁移的真实工作量**）

| 现状 | 目标 | 工作量 |
| --- | --- | --- |
| Next.js App Router（`src/app/**`） | Vite SPA + 客户端路由 | **14 个 page.tsx 全部重写** |
| **14 个页面 Server Component 直查 DB** | 必须改走 **HTTP** | **需先有对应 API**（见 §3 前置） |
| **2 个文件 / 33 个 Server Action** | 改为 HTTP 调用 | 33 个 action 逐条映射 |
| **`src/proxy.ts` 认证网关** | **SPA 下无宿主** | 见 §4 |
| `next/link` 19 · `next/navigation` 16 处 | 换成 `react-router` / TanStack Router | 机械替换，但要重写导航语义 |
| `revalidatePath` **55 个调用点** | TanStack Query 的 `invalidateQueries` | **需逐处重定「失效什么」**——没有一处有文档 |
| `router.refresh()` 31 处 | 同上 | 同上 |
| `export const dynamic` / `runtime` | 消失 | — |
| `output: "standalone"` | 消失（Tauri 打包自己的产物） | `ADR-0018` 的 T2 前提失效 |
| `src/features/**` 86 个文件**零 `next/*`** | **可整体搬进 `packages/`** | **零改动**（前提是保留 Node 服务端） |

> **最有价值的一条**：`src/features/` 的 86 个文件是**框架无关**的（`git grep -L 'next/' src/features` 实测）。
> **它们是这次迁移中唯一"免费"的部分。** 但**前提**是：它们的调用方从「Server Component 直接调用」变成「HTTP」。**逻辑不改，接线要重做。**

---

## 3. 前置（不满足则无法开工）

| # | 前置 | 现状 | 为什么阻塞 |
| --- | --- | --- | --- |
| **W-1** | **业务 API 存在** | **不存在**——14 个页面直接调 `src/features/*/service`，绕过 HTTP | SPA 无法直接调 Node 函数 ⇒ 无 API = 无数据 |
| **W-2** | **OpenAPI 契约** | 主应用侧 **0 个**（`ISSUE-S3-017` #27） | Orval 生成不了 ⇒ 「禁止手写请求」无法执行 |
| **W-3** | **认证网关的新宿主** | `src/proxy.ts` 依赖 Next 的请求上下文 | SPA 下 `next/headers` 不存在 |
| **W-4** | **`ADR-0004` 被替代** | 仍 `accepted` | D2 门禁：ADR 未改不得开工 |

**⇒ W-1/W-2 的实质是：先把这个应用从「全栈单体」拆成「API + SPA」。**
**那是本次最大的一块工作，且用户建议里的"落地清单"完全没有覆盖它**（清单假设从零新建）。

---

## 4. 认证在 SPA 下怎么活（**最需要设计的一处**）

现状（`ADR-0013` / `ADR-0016`）：

```
浏览器 → Next.js proxy.ts（路径鉴权 + 令牌续期 + 身份头注入）
       → Server Component / Server Action（从请求头读身份）
```

SPA 下**没有"服务端渲染时读请求头"这回事**。三条候选：

| # | 方案 | 取舍 |
| --- | --- | --- |
| **A** | **认证网关独立成服务**（Go 或 Caddy 前置），SPA 只拿 Cookie | 最接近现状语义；但**新增一个服务** ⇒ 运维面扩大 |
| **B** | **保留一个薄 Node BFF**（只做认证，不做页面） | 改动小；但 SPA 的价值（去掉 Node 服务端）被削弱 |
| **C** | SPA 直接调认证服务 + **本地验签**（JWT 公钥） | 最简单；**但要改 `ADR-0016` 的信任模型**，且失去头注入 |

**⚠️ 当前主应用是「逐请求回调 auth」（`src/proxy.ts:145,186` 每请求 2 次 HTTP），没有本地验签。**
**⇒ 选 C 是一次**安全模型**变更，不是前端变更。**

**本文件不裁定**——它必须在 `ADR-0021`（或独立 `ADR-0022`）里定。

---

## 5. 迁移顺序（**按可验证性切，不按目录切**）

> 原则：**每一步都能独立验证**，不出现"半迁移"状态。

| 步 | 做什么 | 判据 |
| --- | --- | --- |
| **W-a** | 抽出一个内聚功能（建议从**只读**功能起，如 `/search`）→ 先补 HTTP API → SPA 页面 | 该页功能等价，e2e 绿 |
| **W-b** | 重复 W-a 直到 **14 个页面**全部迁移 | 每页独立提交 + e2e |
| **W-c** | 迁移 `src/proxy.ts` 的认证（按 §4 裁定） | 登录/刷新/登出等价 |
| **W-d** | 接 Tauri 2 外壳 | 桌面端可打包、可运行 |
| **W-e** | 删除 Next.js 依赖与 `next.config.ts` | `grep -r "next/" src/` 为空 |

**不得**先删 Next.js 再重建——那会失去**可运行的对照物**。

---

## 6. 验证

| 正向 | 负向（注入什么必须失败） |
| --- | --- |
| 每页 e2e 通过（现有 18 spec / 1,599 行） | 把一个 API 的错误码改掉 ⇒ **必须有 e2e 红**（否则说明 e2e 没覆盖该路径） |
| Tauri 构建产物可运行 | 桌面端**断网**时请求 ⇒ 必须出可读错误，不得白屏 |
| `grep -r "next/" src/` 为空 | 若还有人引用 `next/*` ⇒ **应视为迁移未完成**（不是"遗留可接受"） |

---

## 7. 未决

1. **路由库**：`react-router` vs TanStack Router（建议后者，与 TanStack Query 同源；但需评估包体）
2. **`revalidatePath` 55 处 / `router.refresh()` 31 处的失效语义**——**没有一处有文档**，必须逐处重定
3. Tauri 2 的**代码签名**与系统依赖（Windows 需 WebView2，Linux 需 webkit2gtk）
4. 桌面端**离线能力**：本次是否要求？（若不要求，则 `ADR-0018` 的 sidecar 议题可一并废弃）
