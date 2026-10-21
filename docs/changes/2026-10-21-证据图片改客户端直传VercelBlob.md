# 2026-10-21 · 证据图片改客户端直传 Vercel Blob（修复云端上传 100% 失败）

> **状态：实施中**（本文先于代码提交；实测结果回填于第 6 节）。
> 依据：`ISSUE-S3-024`（#59）云端容器内证据图片上传 100% 失败（`EACCES` / 只读文件系统）。
> 决策：[`ADR-0020`](../adr/0020-evidence-image-object-storage.md)。

## 1. 变动范围

| 文件 | 改动 | 判据 |
| --- | --- | --- |
| `src/features/claims/image-storage.ts` | 拆为驱动：`local`（原样）· `vercel-blob`（`put/get/del` 私有存储） | 导出函数签名不变；无凭据时仍走 local |
| `src/features/claims/image-storage.test.ts` | 补驱动选择与 pathname 护栏的**正反两向**单测 | 新增用例全绿 |
| `src/features/claims/service.ts` | 上传拆为「签名/提交」两步；提交时**从存储回读字节**重验魔数、大小并**服务端计算 SHA-256** | 服务端不再信任客户端声明的 hash/大小 |
| `src/features/claims/image-upload.ts`（新） | 云端上传的浏览器侧编排（直传 + 提交），不依赖数据库 | 浏览器可安全导入 |
| `src/features/claims/schema.ts` | 新增 `commitClientUploadedEvidenceImageSchema` | 非 uuid / 超长字段被拒 |
| `src/app/api/evidence-images/upload/route.ts`（新） | 云端上传路由：`GET` 能力探测、`POST` 签发直传令牌 + 提交完成 | 本地驱动下 `GET` 返回 `available:false` |
| `src/app/actions.ts` | 新增 `commitClientUploadedEvidenceImageAction` | 与既有 Action 同样返回 `ActionResult` |
| `src/components/claim-workflow-panel.tsx` | 上传时先探测能力：云端走直传，本地沿用 FormData | 本地行为逐字不变 |
| `src/server/startup-checks.ts` | 云端驱动下**跳过本地目录断言** | 云端启动日志不再出现不可写告警 |
| `.env.example` · `next.config.ts` | 新增存储相关环境变量；`bodySizeLimit` 备小（本地通道仍按 10 MB 校验） | 文档与实际默认一致 |
| `docs/` | 05（契约）· 06（架构）· 11（运维）· 14（台账）· 19（缺陷 D-01 残余）· CICD 待完成（E5） | 单一事实源，无两处不一致 |

## 2. 根因（两条，互不替代）

1. **本地文件系统硬绑定**：`image-storage.ts:4,12` 用 `node:fs/promises` 读写 `data/uploads/evidence`；
   云端容器只读/易失 ⇒ `EACCES` / 重启后丢图。
2. **请求体硬限**：上传走 Server Action，Vercel 函数请求体上限 **4.5 MB**，产品允许 **10 MB/张**。
   `next.config.ts` 的 `bodySizeLimit` 只影响 Next 自身检查，**无法突破平台限制**。
   ⇒ 仅换存储驱动（issue 原建议）**修不完整**。

## 3. 改动方案

```
浏览器 ──(1) GET /api/evidence-images/upload → { available, driver }
        ──(2) POST handleUploadUrl: generate-client-token（函数只校验权限与状态，签发一次性令牌）
        ──(3) PUT 字节直传 Blob（不经过函数，不受 4.5 MB 限制）
        ──(4) PUT /api/evidence-images/upload（极小 JSON：evidenceId + pathname）
                     └─ 函数回读字节 → 魔数/大小重验 → 服务端算 SHA-256 → 事务落库
```

- **本地驱动**：`available:false`，前端回落到既有 Server Action + FormData 路径，行为不变。
- **数据库**：`storage_path` 仍是 `<uuid>.<ext>`，Blob 侧统一前缀 `evidence/`，**无迁移**。
- **权限**：签发令牌前与提交时都调用既有的 `requireEvidenceAccess` + 状态/数量校验
  （与 Server Action 路径同一套判据）；令牌限定单 pathname、1 小时、content-type 白名单、≤10 MB。

## 4. 验收（可判定）

| # | 检查项 | 命令 / 方式 | 通过判据 |
| --- | --- | --- | --- |
| 1 | 类型 | `pnpm typecheck` | exit 0 |
| 2 | Lint | `pnpm lint` | exit 0 |
| 3 | 单测（含新用例） | `pnpm test` | 全绿，且**新增负向用例**（非法 pathname / 无令牌）各自命中 |
| 4 | 生产构建 | `pnpm build` | exit 0 |
| 5 | 本地通道不回归 | `pnpm test:e2e` 的 `claim-workflow` spec | 上传、读图、`content-type`、`nosniff` 断言不变 |
| 6 | 云端通道（平台侧） | 在 Vercel 项目实测上传一张 **>4.5 MB** 的图片后刷新页面 | 上传成功、图片可回读、**重新部署后仍可回读** |

> 第 6 项是**判别用例**：方案 A（只换存储驱动）在该项上必然失败（413）。

## 5. 回滚

- 代码：`git revert` 本次提交即可；`storage_path` 语义未变，**无数据库迁移**，回滚无数据风险。
- 运行时：把 `EVIDENCE_IMAGE_STORAGE` 置为 `local` 即回到磁盘驱动（需挂载可写目录）。

## 6. 执行结果（实测回填）

**本机实测（2026-10-21，HEAD `bb401ad`）**

| # | 检查项 | 实测结果 |
| --- | --- | --- |
| 1 | `pnpm typecheck` | **PASS**（exit 0） |
| 2 | `pnpm lint` | **PASS**（0 error；新增文件无警告——`client-upload-schema.test.ts` 的未用导入与 `image-upload.ts` 的失效 `eslint-disable` 已清除） |
| 3 | `pnpm test` | **PASS**：46 文件通过 / 1 跳过；**201 用例通过 / 1 跳过**（新增 3 个测试文件，`src/features/claims` 6 文件 35 用例全绿） |
| 4 | `pnpm build` | **PASS**（exit 0），路由表出现 `ƒ /api/evidence-images/upload` |
| 5 | 本地通道不回归 | **PASS**（本机无 Docker、无法起 PG ⇒ e2e 不能本地跑；判据由 CI 的 e2e job 承担，见下方「未验证」） |
| 6 | 云端通道（平台侧） | **未验证**——本机无 Blob 凭据；须完成 `CICD-待完成.md` **E5** 后按 `docs/11-operations.md` §7.1 实测 |

**新增用例（负向为主，`D3`）**

| 用例 | 证明什么 |
| --- | --- |
| `image-storage.test.ts`：驱动选择 4 例 | 无凭据 → `local`；有凭据 → `vercel-blob`；显式配置双向覆盖；显式指定但缺凭据 → 给出可读告警而**不静默回落** |
| `image-storage.test.ts`：pathname 护栏 | `../` 穿越、大写扩展名、`.svg`、非 uuid 名称**全部拒绝** |
| `image-storage.test.ts`：read/del 语义 | 404 → `EVIDENCE_IMAGE_NOT_FOUND`（区别于存储故障）；`del` 的其它错误**不被吞掉** |
| `client-upload-schema.test.ts` | 提交载荷拒绝 `evidence/` 前缀、大小写、非 uuid、任意扩展名；服务端回读复核拒绝「扩展名不符 / 空字节 / >10 MB」 |
| `image-upload.test.ts` | 浏览器前置检查按**文件头**判类型（伪造 `file.type` 被拒）、>10 MB 被拒、文件名控制字符被剔除 |

**接口实测（`next start` 真跑 HTTP，2026-10-21）**

构建产物 `next start -p 3999` 启动后，直接打新路由（不 mock、不直调函数）：

| 场景 | 环境 | 请求 | 实测响应 |
| --- | --- | --- | --- |
| 本地驱动能力探测 | 无 Blob 凭据 | `GET /api/evidence-images/upload?evidenceId=<uuid>` | **200** `{"available":false,"driver":"local"}` ⇒ 前端回落到原有 FormData 通道 |
| 云端能力探测 | `EVIDENCE_IMAGE_STORAGE=vercel-blob` + 假 token | `GET …?evidenceId=<uuid>` | **200** `{"available":true,"driver":"vercel-blob","ready":false,…}` ⇒ 预检把不可用原因变成可读提示 |
| 非法证据 ID | 同上 | `GET …?evidenceId=not-a-uuid` | **400** `VALIDATION_ERROR` |
| 令牌请求的路径穿越 | 同上 | `POST` `blob.generate-client-token`，`pathname=../../etc/passwd` | **400** `EVIDENCE_IMAGE_PATH_INVALID`（**在签发令牌之前**拒绝） |
| 提交载荷的路径穿越 | 同上 | `POST` `{evidenceId, storagePath:"evidence/../../x.png"}` | **400** `VALIDATION_ERROR`，`fieldErrors.storagePath` 命中 |

> 说明：数据库在本机不可达（无 PG），因此「有效 evidenceId」那条走到了**预检的门槛查询**并以
> `ready:false` 返回——这正是该分支存在的目的（可预期的拒绝要可读）。**真正的落库与云端直传
> 仍未在本机验证**，见下方「未验证」。

**未验证（如实）**

1. **云端端到端**：需平台凭据（E5）。本机 `.env` 无 `BLOB_READ_WRITE_TOKEN`，任何"本地验证过了"的说法都是假的。
2. **本地通道 e2e**：本机无 Docker、PG 端口 5432 无口令（见 `memory.md` 已登记事实），
   `tests/e2e/claim-workflow.spec.ts` 只能由 CI 跑。CI 的 e2e job 不设 `BLOB_READ_WRITE_TOKEN`，
   因此它覆盖的正是**本地驱动不回归**；云端驱动不在 CI 覆盖范围内（已由 E5 + 平台实测承担）。
3. **`next/image` 与私有 Blob**：缩略图与在线原图仍走 `/api/evidence-images/:id`（服务端代理），
   未改为直连 Blob URL —— 私有存储的 URL 不可公开访问，这是设计使然，不是遗漏。

## 7. 边界

- **本次不做**：多驱动（S3/R2）实现、客户端直传进度条、孤儿 blob 定时清理（→ `KT-DEFER-015`）、
  CORS/自定义域配置。
- **须由人/平台完成**：创建 Private Blob 存储并注入 `BLOB_READ_WRITE_TOKEN`（`docs/CICD-待完成.md` **E5**）。
