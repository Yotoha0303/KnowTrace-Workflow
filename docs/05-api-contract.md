# 服务端操作契约

> 最后核对：**2026-10-01**，依据 `c4bdca7`。
> 本行**只在内容变更时**更新，不随改名/格式化变动——约定见 [CONTRIBUTING.md](../CONTRIBUTING.md)「目录与命名约定」。

## 1. 当前接口策略

Web 交互仍以 Server Components 和 Server Actions 为主，同时维护一组面向未来 App 的版本化 REST API：

- Server Components 直接通过 Application Service 读取数据库。
- Web 表单和交互写操作使用 Server Actions。
- 健康检查和 `/api/v1` App/外部客户端契约使用 Route Handlers。
- Application Service 不依赖 React、HTTP Request 或 Next.js Response，便于以后暴露 REST API或拆出独立后端。

所有操作都返回可辨别的成功/失败结果，页面不解析数据库异常文本。

## 2. 通用结果

```ts
type ActionResult<T> =
  | { ok: true; data: T }
  | {
      ok: false
      error: {
        code: string
        message: string
        requestId: string
        fieldErrors?: Record<string, string[]>
      }
    }
```

## 3. Capture Commands

### createCapture

```ts
type CreateCaptureInput = {
  content: string
  title?: string | null
  subject?: string | null
  occurredAt: string // ISO 8601 instant
  contentType?: ContentType
  categoryIds?: string[]
  idempotencyKey: string
}
```

返回：Capture ID、版本、创建时间。

### updateCapture

```ts
type UpdateCaptureInput = {
  id: string
  title?: string | null
  subject?: string | null
  content: string
  occurredAt: string // ISO 8601 instant
  contentType: ContentType
  expectedVersion: number
}
```

版本冲突：`CAPTURE_VERSION_CONFLICT`。

### setCaptureCategories

```ts
type SetCaptureCategoriesInput = {
  captureId: string
  categoryIds: string[]
}
```

以最终集合为准，事务内计算新增和移除关系；重复提交幂等。

### archiveCapture / restoreCapture

输入 Capture ID，操作幂等。

## 4. Category Commands

### createCategory

```ts
type CreateCategoryInput = {
  name: string
  description?: string | null
}
```

规范化名称冲突：`CATEGORY_NAME_CONFLICT`。

### renameCategory

重命名后重新计算规范化名称，并检查冲突。

### archiveCategory / restoreCategory

归档 Category 后不能再为 Capture 新增此分类。

### deleteCategory

输入 Category ID。服务端在事务中锁定 Category 并重新统计全部 Capture 关联；计数为 0 时永久删除，存在活跃或已归档记录关联时返回 `CATEGORY_IN_USE`。页面计数和按钮禁用只用于反馈，不作为最终授权条件。

## 5. AI Commands

### organizeCapture

```ts
type OrganizeCaptureInput = {
  captureId: string
  expectedCaptureVersion: number
  provider?: 'openai' | 'deepseek'
}
```

规则：

- Provider 只能从服务端允许列表选择。
- 先创建 running Run，再调用 Provider。
- 整体请求有明确超时。
- 成功返回 Run 和 Suggestion ID。
- 失败返回稳定错误码，同时 Run 已记录失败。

### decideSuggestion

```ts
type DecideSuggestionInput = {
  suggestionId: string
  decision: 'accepted' | 'modified' | 'rejected'
  acceptedFields?: {
    title?: string | null
    contentType?: ContentType
    existingCategoryIds?: string[]
    newCategoryNames?: string[]
    contentSuggestionIndexes?: number[]
    claimCandidateIndexes?: number[]
  }
}
```

来源版本落后时返回 `AI_SUGGESTION_STALE`，除非使用者明确进入对比处理流程；MVP 默认阻止直接接受。

`claimCandidateIndexes` 默认空数组，最多 3 个。只有明确选择的候选会创建独立 Claim。

### auditClaim

```ts
type AuditClaimInput = {
  claimId: string
  provider?: 'mock' | 'openai' | 'deepseek'
  connection?: AIConnectionInput
}
```

只读取本次快照中的已采纳、来源检查通过且摘录匹配的 Evidence。先创建 `task_type=claim_audit` 的 Run，成功后追加 ClaimAIAudit；不修改 Claim、Evidence、Review 或任何状态。请求级凭据只用于本次调用，不进入哈希、Payload、数据库或日志。

## 6. Claim Commands

### transitionClaim

输入 Claim ID、`expectedStatus` 与 `targetStatus`。服务端检查状态转换白名单；提交待审核时还要求至少一条已采纳 Evidence。并发状态不一致返回冲突。

### addClaimEvidence

输入 Claim ID、可选来源 URL、来源标题、原文摘录、立场和可选备注。URL 留空时保存为空字符串；非空时必须是 HTTP(S) URL。只允许在 `investigating` 状态新增，初始审核状态固定为 `unreviewed`。无链接 Evidence 可以继续编辑、上传图片、执行附件人工核验或排除。

### updateClaimEvidence

输入 Evidence ID、`expectedVersion` 以及完整的来源字段。仅允许编辑调查中且未审核的 Evidence；事务先保存旧版本，再递增版本并清除当前来源检查投影。版本冲突返回稳定冲突错误，历史 SourceCheck 不删除。

### uploadEvidenceImage

通过 `FormData` 输入 Evidence ID 与图片。仅允许调查中且未审核的 Evidence；支持 JPEG、PNG、WebP、GIF，校验声明 MIME 与文件头，单张最多 10 MB、每条 Evidence 最多 5 张。文件落在项目上传目录，数据库保存相对路径和 SHA-256；成功后通过 `/api/evidence-images/:id` 在线读取。上传成功不代表人工核验通过，不改变 Evidence 审核状态；如果当前核验方式是 `manual_attachment`，新增图片会重置核验投影。

### reviewClaimEvidence

输入 Evidence ID 与 `accepted/rejected` 决定。只允许在所属 Claim 调查中处理未审核 Evidence，决定不可覆盖。`accepted` 还要求当前网页检查或附件人工核验成功、摘录匹配且检查快照未被并发替换；`rejected` 不要求核验。

### checkClaimEvidenceSource

输入 Evidence ID 与可选 `manualConfirmation`。只允许核验调查中且未审核的 Evidence。有 URL 时，服务端安全抓取 HTTP(S) 页面、逐跳检查重定向并匹配摘录；无 URL 时要求 `manualConfirmation=true` 且至少存在一张图片，事务内冻结附件元数据、组合哈希和确认说明。两种路径都追加不可变 EvidenceSourceCheck 并更新当前检查投影；网页检查失败保存稳定错误码，便于审计和重试。

### concludeClaim

输入 Claim ID、`supported/refuted/inconclusive`、至少 10 字的依据和可选限制。只允许从 `ready_for_review` 形成结论；服务端冻结所有当前已采纳且来源确认的 Evidence。`supported` 至少需要支持证据，`refuted` 至少需要反驳证据。重新调查后再次结论会增加 `review_number`，不覆盖历史。

## 7. Queries

Application Service 提供：

```text
listRecentCaptures(cursor, limit, status)
getCaptureDetail(id)
listCaptureRevisions(id, cursor, limit)
listCategories(status)
listCapturesByCategory(categoryId, cursor, limit)
listCaptureAIRuns(captureId)
getSuggestion(suggestionId)
listClaimsByCapture(captureId)
```

查询返回领域 DTO，不把 Drizzle 查询结果对象直接传入 Client Component。

## 8. Route Handlers

健康检查：

```text
GET /api/health/live
GET /api/health/ready
```

当前版本化 API：

```text
POST               /api/v1/auth/login
POST               /api/v1/auth/refresh
POST               /api/v1/auth/logout
GET                /api/v1/auth/session

GET, POST, DELETE  /api/v1/workspaces
POST               /api/v1/workspaces/current

GET, POST          /api/v1/captures
GET, PATCH, DELETE /api/v1/captures/:id
GET                /api/v1/categories
GET                /api/v1/subjects
GET                /api/v1/subjects/:subject
GET                /api/v1/claims
GET                /api/v1/knowledge-releases

GET, POST          /api/v1/ai-runs
GET                /api/v1/ai-runs/:runId
```

这些 Route Handler 复用同一 Application Service，不重新实现业务规则。统一响应、分页、幂等键、`If-Match` 删除前置条件、认证与客户端头、Workspace 上下文和示例见 [移动端 API](12-mobile-api.md)。证据审核、独立复核和发布写操作仍只在 Web 中完成，避免在权限边界之外扩大高影响接口；AI 整理目前开放的是同步触发与运行读取。

所有业务端点都从 go-user-system 会话解析数据范围：`admin` 可访问全部创建者的资源，普通成员仅可访问 `created_by_id` 与本人匹配的资源。跨成员详情与写操作按不存在处理，列表、搜索、统计、导出和图片读取必须应用同一过滤条件。

## 9. 主要错误码

```text
CAPTURE_NOT_FOUND
CAPTURE_CONTENT_REQUIRED
CAPTURE_CONTENT_TOO_LONG
CAPTURE_VERSION_CONFLICT
CAPTURE_IDEMPOTENCY_CONFLICT
CATEGORY_NOT_FOUND
CATEGORY_NAME_CONFLICT
CATEGORY_ARCHIVED
CATEGORY_LIMIT_EXCEEDED
AI_PROVIDER_NOT_CONFIGURED
AI_PROVIDER_UNAVAILABLE
AI_PROVIDER_TIMEOUT
AI_RESPONSE_INVALID
AI_SUGGESTION_NOT_FOUND
AI_SUGGESTION_ALREADY_DECIDED
AI_SUGGESTION_STALE
CLAIM_NOT_FOUND
CLAIM_STATUS_CONFLICT
CLAIM_TRANSITION_INVALID
CLAIM_ACCEPTED_EVIDENCE_REQUIRED
CLAIM_EVIDENCE_NOT_FOUND
CLAIM_EVIDENCE_ALREADY_REVIEWED
CLAIM_EVIDENCE_STATE_INVALID
CLAIM_EVIDENCE_SOURCE_CHECK_STATE_INVALID
CLAIM_EVIDENCE_SOURCE_NOT_CONFIRMED
CLAIM_SUPPORTING_EVIDENCE_REQUIRED
CLAIM_CONTRADICTING_EVIDENCE_REQUIRED
CLAIM_EVIDENCE_SNAPSHOT_INVALID
CLAIM_AI_AUDIT_STATE_INVALID
CLAIM_AI_AUDIT_FAILED
EVIDENCE_SOURCE_PRIVATE_ADDRESS
EVIDENCE_SOURCE_TIMEOUT
EVIDENCE_SOURCE_TOO_LARGE
EVIDENCE_SOURCE_CONTENT_TYPE_BLOCKED
INTERNAL_ERROR
```

## 10. 并发与重复提交

- Capture 创建：Idempotency Key。
- Capture 编辑：Expected Version 乐观锁。
- Category 关联：联合唯一约束和集合式更新。
- Suggestion 决策：条件更新 `WHERE status = 'pending'`。
- Claim 状态：条件更新 `WHERE id = ? AND status = expectedStatus`。
- Evidence 审核：只允许 `unreviewed` 一次性转换为最终决定。
- AI Run：每次主动点击产生新 Run；前端在请求进行时禁用重复按钮，但服务端仍要安全处理并发。
