# 架构调整 · Mobile 端（Expo + React Native）

| 项 | 值 |
| --- | --- |
| 建立时间 | `2026-10-18` |
| 依据 | 用户裁定 + 工作区根 `前端技术栈调整建议.md` |
| 共享契约 | [`架构调整-00-共享契约.md`](架构调整-00-共享契约.md) —— **本文不重复它** |
| 关联 ADR | 需新增 `ADR-0022`（移动端形态，延伸 `ADR-0016`） |
| 状态 | **草案** |

---

## 1. 目标形态

```
apps/mobile/
├── app/                        # Expo Router（文件路由）
├── components/ui/              # React Native Reusables（RNR）
├── nativewind.config.js
└── package.json
```

- **Expo SDK 52+（Prebuild 模式）**
- **React Native + NativeWind v4**
- 持久化走 **`react-native-mmkv`**

---

## 2. 现状：**移动端还没有代码**

| 项 | 状态 |
| --- | --- |
| `apps/mobile` | **不存在** |
| 相关 ADR | `ADR-0016`（原生客户端认证，`accepted`）· `docs/18-mobile-client-plan.md` |
| **接口已就绪的部分** | `/api/v1/*`（15 个 route handler，**面向外部客户端设计**，`ADR-0016` 定的） |
| **`X-Client: native` + Bearer 分支** | **已在 `src/proxy.ts:93-123` 实现** |

**⇒ 这是**新建**，不是迁移。** 它也是四份方案里**唯一没有存量包袱**的一份。

---

## 3. 真正的工作：**复用，而不是重写**

本端最大的价值不是"再加一个端"，而是**验证共享契约是否成立**：

| 契约条款 | 在 RN 上怎么验证它成立 |
| --- | --- |
| `packages/schemas`（Zod） | RN 里 Zod 直接可用 —— **若某条 schema 用了 DOM 专有类型，立即暴露** |
| `packages/api`（Orval 生成 + TanStack Query） | RN 支持 fetch；**若生成物用了 `window` / `document`，立即暴露** |
| `packages/stores`（Zustand + 存储适配器） | 注入 `MMKV` 适配器；**若 store 里混入 localStorage 调用，立即暴露** |
| NativeWind v4 | 同一套 Tailwind 类名 —— **但见下方警告** |

> ⚠️ **NativeWind 的"同一套 Tailwind 类名"只在<u>语法</u>层成立。**
> 布局模型（flex 默认方向、`position` 语义）、可用 utility 子集、无障碍属性**都不同**。
> **不要把"类名可复用"读成"样式可复用"** —— 这是本方案最容易被误读的假设。
> **判据**：把一个 Web 组件的 `className` 原样搬进 RN，**能编译不等于能正确渲染**；
> 必须逐屏目视核对，**不能只靠类型检查通过**。

---

## 4. 前置

| # | 前置 | 现状 |
| --- | --- | --- |
| **M-1** | **共享包已建**（`packages/schemas` / `api` / `stores`） | 不存在 —— 依赖 Web 端先抽出来 |
| **M-2** | **认证服务的 OpenAPI 已可生成** | ✅ **`services/go-user-system` 已有 swagger.json**（5 个命中里含 2 个） |
| **M-3** | **业务 API 可生成** | ❌ 主应用侧无 OpenAPI（`ISSUE-S3-017` #27） ⇒ **移动端只能先接认证服务** |
| **M-4** | `ADR-0016` 未失效 | 需确认：SPA 化之后，原生客户端的 Bearer 分支搬到哪里（`src/proxy.ts` 无宿主） |

**⚠️ M-3 是关键限制**：移动端**先期只能用认证相关的能力**，业务数据接口要等主应用补 OpenAPI。

---

## 5. 迁移/新建顺序

| 步 | 做什么 | 判据 |
| --- | --- | --- |
| **M-a** | 初始化 Expo + NativeWind，跑通一个空白屏 | `pnpm turbo build` 通过；Expo 可在真机/模拟器运行 |
| **M-b** | 接 `packages/schemas` + `packages/api`（**只读认证接口**） | 登录/会话查询在真机可用 |
| **M-c** | 接 `packages/stores`（Zustand + MMKV 适配器） | Token 持久化在**冷启动后仍有效** |
| **M-d** | 第一个业务页（取决于 M-3 是否解除） | 有数据、非硬编码 |

---

## 6. 验证

| 正向 | 负向（注入什么必须失败） |
| --- | --- |
| 登录 → 冷启动 → 仍登录（MMKV 生效） | 把 MMKV 适配器换成"只写内存" ⇒ **必须表现为冷启动丢失**（否则说明适配器没真接上） |
| Token 过期 → 自动刷新 | 把 refresh 端点改为 500 ⇒ **必须走登出并给可读错误**，不得静默 |
| 断网 → 可读错误 | 飞行模式下打开 ⇒ **不得白屏** |

---

## 7. 未决

1. **`ADR-0016` 的 Bearer 分支在 SPA 化后归谁**（与 Web 端 §4 是同一个问题）
2. Expo 的 **OTA 更新**是否启用（涉及合规与回滚策略）
3. iOS 构建需要 Apple 开发者账号 —— 属**仓外动作**（`AGENTS.md` §5「待执行指令」）
