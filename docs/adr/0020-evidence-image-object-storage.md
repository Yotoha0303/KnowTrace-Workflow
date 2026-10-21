# ADR-0020：证据图片改用对象存储——客户端直传 Blob、服务端只做提交

- 状态：**proposed**
- 日期：2026-10-21（提出）
- 关联：`ADR-0004`（Next.js 全栈单体）· `ADR-0008`（可审计的证据来源检查）· `ISSUE-S3-024`（#59）· `D-01`（历史上同一条链路的绑定挂载属主事故）
- 依据：`src/features/claims/image-storage.ts:4,9-14` · `src/features/claims/service.ts:307-390` ·
  `next.config.ts`（`bodySizeLimit: "12mb"`）· Vercel 官方 `functions/limitations`（请求体 **4.5 MB**）·
  Vercel 官方 `vercel-blob/private-storage`（私有存储、`get()/put()/del()` 与 OIDC/`BLOB_READ_WRITE_TOKEN`）
  —— 均为 2026-10-21 实读

> ⚠️ **本文与 `ADR-0019` 同类：决策先写、实现随附**。`proposed` 只表示「决策待接受」，
> 不代表「未落地」；实施结果见 `docs/changes/2026-10-21-证据图片改客户端直传VercelBlob.md`。

---

## 1. 背景

`ISSUE-S3-024`（#59）记录：在 Render / Vercel 等无状态容器里，证据图片上传 **100% 失败**。

实测到的两条**各自独立、都足以单独致命**的事实：

| # | 事实 | 证据 |
| --- | --- | --- |
| 1 | 图片读写**硬编码本地磁盘**，云端容器文件系统只读/易失 | `src/features/claims/image-storage.ts:4,12`（`node:fs/promises` + `data/uploads/evidence`）；启动自检 `src/server/startup-checks.ts:22` 会直接报 `EACCES` |
| 2 | 上传走 **Server Action**，而 Vercel 函数**请求体上限 4.5 MB**，产品却允许**单张 10 MB** | Vercel `functions/limitations`「maximum payload size … is **4.5 MB**」；`next.config.ts` 的 `bodySizeLimit: "12mb"` 只改 Next 的检查，**改不了平台硬限** |

⇒ **只加一个「存储适配层」修不掉问题**：换掉 `node:fs` 之后，>4.5 MB 的图片仍会在进入函数**之前**被平台 413 拒绝
（错误码 `FUNCTION_PAYLOAD_TOO_LARGE`）。这条是本 ADR 与 issue 原建议（仅做 Storage Adapter）的**关键分歧**。

## 2. 决策

1. **两条上传通道并存，按存储驱动选择**：
   - **云端（Vercel Blob）**：浏览器用 `@vercel/blob/client` 的 `upload()` **直传对象存储**，
     函数只签发一次性上传令牌并接收极小 JSON 提交 → **不再经过 4.5 MB 限制**；
   - **本地单机（Docker / VPS）**：保留现有 Server Action + `FormData` 通道，行为不变。
2. **存储驱动抽象**（接口保持现有三个函数签名 `write/read/remove`）：
   - `local`：现有 `node:fs` 实现（默认）；
   - `vercel-blob`：`put/get/del`，**私有存储**（证据图片是用户隐私数据，不得公开可读）。
3. **`storage_path` 语义不变**：仍是 `<uuid>.<jpg|png|webp|gif>`；Blob 侧统一加 `evidence/` 前缀。
   **不新增迁移**、不改表结构。
4. **服务端兜底校验不外包给客户端**：提交时服务端**从存储回读字节**，重新验证魔数、大小，
   **服务端计算 SHA-256** 落库——与本地通道的可信度等价（客户端只负责搬运字节）。
5. **配置**：`EVIDENCE_IMAGE_STORAGE=vercel-blob|local`（缺省：有 `BLOB_READ_WRITE_TOKEN` 即 blob，否则 local）；
   `EVIDENCE_IMAGE_BLOB_ACCESS=private|public`（缺省 `private`）。

## 3. 备选方案与取舍

| 方案 | 结论 | 理由 |
| --- | --- | --- |
| A. 只换存储驱动（issue 原建议） | ❌ 否决 | 4.5 MB 硬限仍在，大图必败（上文事实 2） |
| B. 服务端中转上传（浏览器 → 函数 → Blob） | ❌ 否决 | 同样撞 4.5 MB；且函数多一次全量转发（FDT 计费） |
| C. **客户端直传 + 服务端提交**（本决策） | ✅ 采纳 | 绕开请求体限制；上传流量不计入函数；私有存储 + 服务端回读校验保住证据链可信度 |
| D. 自建 S3/R2 兼容层 | ⏸ 暂不采纳 | 多一套凭据/运维；`@vercel/blob` 提供同构接口，将来换 S3 只需替换一个驱动 |

## 4. 后果

**正面**：云端大图（≤10 MB）可用；跨实例/重启/重新部署持久；Docker/VPS 行为零变化。

**代价（如实列出）**：
1. **部署前提**：Vercel 项目必须**创建 Private Blob 存储并注入 `BLOB_READ_WRITE_TOKEN`**。
   这是平台侧动作，AI 做不了 → 登记于 `docs/CICD-待完成.md`（**E5**）。
2. **客户端直传窗口**：令牌有效期 1 小时、限定单个 pathname、限定 content-type 与 10 MB 上限；
   但**字节先落存储、数据库后落记录**，若提交失败会留下**孤儿 blob**（已登记 `KT-DEFER-015` 清理项）。
3. **读图多一跳**：浏览器 → 本应用 Route Handler → Blob（私有存储无法直连）。这是「私有」的必然成本。
4. **本机无凭据时无法端到端验证 Blob 驱动**：本机没有可用 token，验收以类型检查/单测/构建 + 平台侧实测为准，
   平台侧实测结果回填于变更记录与 issue。

## 5. 判据（可证伪）

1. **驱动选择**：无 `BLOB_READ_WRITE_TOKEN` 时 `evidenceImageStorageDriver()` 返回 `local`；
   设置后返回 `vercel-blob`（单测覆盖两个方向）。
2. **路径护栏**：`evidenceImageBlobPathname()` 对 `../x.png`、大写扩展名、非 uuid 一律拒绝（负向单测）。
3. **本地通道不回归**：`tests/e2e/claim-workflow.spec.ts` 的上传/读图断言在 local 驱动下必须仍然通过。
4. **云端通道**（需平台凭据）：上传 5 MB 以上图片成功、刷新页面可回读、重新部署后仍可回读。
   其中「>4.5 MB」正是**本 ADR 与方案 A 的判别用例**——方案 A 在此用例上必败。
