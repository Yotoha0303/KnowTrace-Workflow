# 数据库设计

> 最后核对：**2026-10-04**（本轮修订）。
> 本行**只在内容变更时**更新，不随改名/格式化变动——约定见 [CONTRIBUTING.md](../CONTRIBUTING.md)「目录与命名约定」。

## 1. 设计原则

- PostgreSQL 是唯一事实来源。
- 主键使用 UUID，生成方式在项目初始化时统一。
- 时间字段使用 `timestamptz` 并保存 UTC。
- 业务枚举使用数据库约束或受控文本值，避免任意字符串。
- 核心关系使用关系表；AI 可演进输出使用带版本的 JSONB。
- 不复制用户、会话、Workspace、成员和 Refresh Token 表；业务表只保存 go-user-system 用户的稳定创建者标识和当时显示名。

## 2. 表结构

### captures

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| title | varchar(200) | 可空 |
| content | text | 当前原始内容 |
| content_type | varchar(30) | 默认 unknown |
| status | varchar(20) | active/archived |
| version | integer | 初始为 1 |
| idempotency_key | varchar(128) | 创建幂等键 |
| created_by_id | varchar(100) | `go-user:<id>`；历史数据为 `legacy-local` |
| created_by_name | varchar(255) | 创建时显示名快照 |
| archived_at | timestamptz | 可空 |
| created_at | timestamptz | 创建时间 |
| updated_at | timestamptz | 更新时间 |

约束与索引：

- `unique(created_by_id, idempotency_key)`
- `(created_by_id, status, created_at desc, id desc)`
- `(status, created_at desc, id desc)`
- `char_length(content) between 1 and 20000`
- `version > 0`

### capture_revisions

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| capture_id | uuid | 外键 |
| version | integer | 历史版本 |
| title | varchar(200) | 当时标题 |
| content | text | 当时正文 |
| content_type | varchar(30) | 当时类型 |
| created_at | timestamptz | 快照时间 |

约束：

- `unique(capture_id, version)`
- Revision 只允许 INSERT 和 SELECT。

### categories

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| name | varchar(60) | 展示名称 |
| normalized_name | varchar(80) | 唯一比较值 |
| description | varchar(500) | 可空 |
| status | varchar(20) | active/archived |
| created_by_id | varchar(100) | Category 创建者 |
| created_by_name | varchar(255) | 创建时显示名快照 |
| created_at | timestamptz | 创建时间 |
| updated_at | timestamptz | 更新时间 |

约束：

- `unique(created_by_id, normalized_name)`
- 规范化至少包含 Unicode 空白整理和大小写处理；具体算法必须有测试。

### capture_categories

| 字段 | 类型 | 说明 |
|---|---|---|
| capture_id | uuid | 联合主键、外键 |
| category_id | uuid | 联合主键、外键 |
| assigned_by | varchar(20) | manual/ai_accepted |
| created_at | timestamptz | 创建时间 |

主键：`(capture_id, category_id)`。

### ai_processing_runs

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| capture_id | uuid | 输入 Capture |
| capture_version | integer | 输入版本 |
| input_hash | varchar(64) | 输入摘要，用于审计 |
| task_type | varchar(40) | organize/claim_audit |
| provider | varchar(40) | Provider 标识 |
| model | varchar(80) | 模型标识 |
| prompt_version | varchar(40) | Prompt 版本 |
| schema_version | varchar(40) | 输出 Schema 版本 |
| status | varchar(20) | running/succeeded/failed/cancelled |
| input_tokens | integer | 可空 |
| output_tokens | integer | 可空 |
| latency_ms | integer | 可空 |
| error_code | varchar(80) | 可空、脱敏 |
| request_id | varchar(80) | 调用关联标识 |
| started_at | timestamptz | 开始时间 |
| completed_at | timestamptz | 可空 |
| created_at | timestamptz | 创建时间 |

索引：

- `(capture_id, created_at desc)`
- `(status, started_at)` 用于清理超时 running 状态。

### ai_suggestions

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| processing_run_id | uuid | 唯一外键 |
| capture_id | uuid | 来源 Capture |
| source_capture_version | integer | 来源版本 |
| schema_version | varchar(40) | Payload Schema |
| payload | jsonb | 通过校验的结构化建议 |
| status | varchar(20) | pending/accepted/modified/rejected/stale/rolled_back |
| accepted_payload | jsonb | 保存用户确认结果、采纳前回退快照和可选回退结果 |
| decided_at | timestamptz | 可空 |
| created_at | timestamptz | 创建时间 |

约束：

- `unique(processing_run_id)`
- 决策状态与 `decided_at` 保持一致。

### claims

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| capture_id | uuid | 来源 Capture，删除时级联 |
| source_suggestion_id | uuid | 来源 Suggestion，可空 |
| source_capture_version | integer | 候选产生时的版本 |
| statement | varchar(1000) | 可证伪陈述 |
| statement_hash | varchar(64) | 来源与规范化陈述的去重摘要 |
| source_excerpt | varchar(1000) | 原文逐字片段 |
| falsification_criteria | varchar(1000) | 可削弱或反驳该主张的条件 |
| status | varchar(30) | candidate/investigating/ready_for_review/withdrawn |
| created_at / updated_at | timestamptz | 时间 |

约束：`unique(statement_hash)`，来源版本大于 0。状态转换由 Application Service 白名单控制。

### claim_evidence

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| claim_id | uuid | 所属 Claim，删除时级联 |
| source_url | varchar(2000) | 可选 HTTP(S) 来源，空字符串表示无链接 |
| source_title | varchar(300) | 来源标题 |
| excerpt | varchar(2000) | 证据摘录 |
| stance | varchar(20) | supports/contradicts/context |
| note | varchar(1000) | 可空 |
| version | integer | 乐观锁与修订版本，从 1 开始 |
| review_status | varchar(20) | unreviewed/accepted/rejected |
| reviewed_at | timestamptz | 可空 |
| source_check_status | varchar(20) | unchecked/passed/failed |
| source_excerpt_match | boolean | 当前检查是否匹配摘录 |
| source_checked_at | timestamptz | 当前检查时间 |
| latest_source_check_id | uuid | 当前检查快照 ID |
| created_at / updated_at | timestamptz | 创建与最近编辑时间 |

### claim_evidence_revisions

保存 Evidence 编辑前的不可变完整字段快照、旧版本号与当时的 `latest_source_check_id`。`(evidence_id, version)` 唯一；编辑事务写入 Revision 后递增当前版本，并将来源检查投影重置为 unchecked。

### evidence_attachments

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键，也是读取图片时的公开标识 |
| evidence_id | uuid | 所属 Evidence，删除时级联 |
| original_name | varchar(255) | 清理控制字符后的原文件名 |
| storage_path | varchar(255) | 项目上传目录内的不可推测相对文件名，唯一 |
| mime_type | varchar(40) | 从文件头确认的受控图片类型 |
| byte_size | integer | 1 到 10 MB |
| sha256 | varchar(64) | 文件内容哈希 |
| created_at | timestamptz | 上传时间 |

图片二进制不写入 PostgreSQL。数据库级联删除后，服务层删除对应项目文件；文件清理失败最多留下无数据库引用的孤儿文件，不允许造成数据库回滚或记录丢失。

### evidence_source_checks

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| evidence_id | uuid | 所属 Evidence，删除时级联 |
| verification_method | enum | web/manual_attachment |
| requested_url / final_url | varchar(2000) | 请求与重定向后的最终地址 |
| status | varchar(20) | passed/failed |
| http_status | integer | 可空 |
| content_type | varchar(120) | 可空 |
| content_hash | varchar(64) | 成功时的 SHA-256 |
| fetched_title | varchar(300) | 抓取页面标题，可空 |
| excerpt_match | boolean | 成功时是否匹配摘录 |
| response_bytes | integer | 响应体字节数 |
| error_code | varchar(80) | 失败时的稳定错误码 |
| attachment_snapshot | jsonb | 附件人工核验冻结的 ID、文件名、MIME、大小与 SHA-256 |
| verification_note | varchar(1000) | 附件人工核验的固定确认说明 |
| checked_at | timestamptz | 检查时间 |

SourceCheck 只允许 INSERT/SELECT。`web` 遵守 HTTP 抓取结果约束；`manual_attachment` 必须成功、摘录确认匹配、至少冻结一张附件并保存确认说明。`claim_evidence.latest_source_check_id` 是事务内维护的当前投影标识；历史检查不会被覆盖，Evidence 编辑或新增附件只清除当前投影。

### claim_reviews

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| claim_id | uuid | 所属 Claim，删除时级联 |
| review_number | integer | Claim 内递增版本 |
| assessment | varchar(20) | supported/refuted/inconclusive |
| rationale | varchar(2000) | 人工结论依据 |
| limitations | varchar(2000) | 限制与未知，可空 |
| created_at | timestamptz | 结论时间 |

约束：`unique(claim_id, review_number)`；Review 只追加。

### claim_review_evidence

联合主键为 `(review_id, evidence_id)`。除 Evidence 和 SourceCheck ID 外，还复制该次结论使用的来源 URL、标题、摘录、立场、最终 URL、内容 SHA-256 与检查时间，保证历史结论可以独立解释。

### claim_ai_audits

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| processing_run_id | uuid | 唯一关联 AI Run |
| claim_id | uuid | 所属 Claim，删除时级联 |
| source_claim_updated_at | timestamptz | 审查使用的 Claim 时点 |
| source_evidence_fingerprint | varchar(64) | 已确认采纳证据集合摘要 |
| schema_version | varchar(40) | 输出 Schema 版本 |
| evidence_snapshot | jsonb | 本次输入的证据与来源检查快照 |
| payload | jsonb | 校验后的覆盖、平衡、问题与建议 |
| created_at | timestamptz | 审查时间 |

Audit 只追加。当前 Claim 时间或证据指纹与快照不一致时，查询 DTO 把它标记为 stale，不覆盖旧记录。

## 3. 核心事务

### 创建 Capture

1. 校验正文。
2. 用 idempotency_key 查询已有请求。
3. 不存在则创建 Capture。
4. 事务提交后返回成功。

相同幂等键但不同请求体必须返回冲突，而不是复用旧结果。

### 修订 Capture

同一事务中：

1. 查询当前 Capture。
2. 检查 `version = expected_version`。
3. 把当前值写入 Revision。
4. 条件更新 Capture 并增加版本号。

```sql
UPDATE captures
SET title = $1,
    content = $2,
    content_type = $3,
    version = version + 1,
    updated_at = now()
WHERE id = $4
  AND version = $5;
```

### 接受或回退 AI 整理

同一事务中：

1. 锁定 pending Suggestion。
2. 检查来源版本与当前 Capture 版本。
3. 创建或查找被接受的 Category。
4. 幂等写入 capture_categories。
5. 如果标题或 Content Type 改变，按 Capture 修订规则写入 Revision 并增加版本。
6. 在 accepted payload 保存采纳前核心字段、AI 分类、应用版本和本次新建 Claim ID，再更新 Suggestion 决策状态。

正文只允许应用用户明确勾选且原片段仍唯一匹配的局部建议，并遵循 Capture 修订规则。

整体回退锁定已采纳 Suggestion 和 Capture，要求它仍是最近一次已采纳整理、Capture 版本与应用后版本一致、AI 分类未变化且本次 Claim 仍为 candidate。事务恢复采纳前核心字段与 AI 分类、删除这些 candidate Claim、写入新 Revision，并把 Suggestion 设为 rolled_back；任一检查失败都不得局部回退。

### 接纳候选主张与提交审核

- 只有用户明确勾选的 `claimCandidateIndexes` 才创建 Claim，单次最多 3 个。
- `statement_hash` 防止同一来源版本的同一陈述被重复创建。
- Evidence 只能在 Claim 为 `investigating` 时新增、编辑、上传图片、检查来源或审核；编辑与上传还要求 Evidence 为 `unreviewed`。
- 采纳 Evidence 时同时检查最新来源状态为 passed、摘录匹配且快照 ID 未被并发替换。
- 形成结论时先条件更新 `ready_for_review → concluded`，再在同一事务写入 Review 和 Evidence 快照；任一步失败全部回滚。
- `investigating → ready_for_review` 在事务中统计已采纳证据；数量为 0 时拒绝。
- 状态更新同时匹配 `id + expectedStatus`，避免并发静默覆盖。

## 4. AI 调用崩溃恢复

首版是请求内同步调用，但 Run 会在调用前写入 running。如果进程崩溃，Run 可能停留在 running。

容器启动时在 Migration 之后执行维护脚本，把超过 `AI_RUNNING_STALE_AFTER_MS`（默认 5 分钟）的 running AI Run 与主题综合任务标记为 failed，并使用 `AI_RUN_INTERRUPTED` 错误码。该脚本也可以通过 `pnpm db:maintenance` 手动执行。

## 5. 迁移要求

- Drizzle Schema 不是唯一文档；必须生成并提交 SQL Migration。
- 已执行 Migration 不修改，只追加。
- CI 在空数据库执行全部 Migration。
- 生产部署前进行备份和恢复演练。

## 6. 统一检索索引

Migration `0005_knowledge_search.sql` 启用 PostgreSQL `pg_trgm`，为 Capture、Claim、Evidence 和 ClaimReview 的组合文本表达式创建 GIN trigram 索引。这样可以支持中文关键词和不完整片段的 `ILIKE '%query%'` 查询，而不依赖 PostgreSQL 内置英文分词。

查询表达式必须与索引表达式保持一致；用户输入参数化并转义 `%`、`_` 和反斜杠。该扩展可能需要数据库管理员权限，受限托管环境应在迁移前预先启用。

## 7. 描述对象与发生时间

Migration `0006_capture_subject_and_occurred_at.sql` 为 Capture 和 Revision 增加 `subject` 与 `occurred_at`。现有 Capture 以自身 `created_at` 回填发生时间；旧 Revision 继承所属 Capture 的回填值，避免迁移时刻伪装成历史事件时间。

Migration `0010_capture_similarity_search.sql` 在 Capture 的标题、描述对象和正文组合表达式上增加 GiST `gist_trgm_ops` 索引，用于有界近邻候选查询。相似分数不持久化；详情读取时再结合共同 Category 和同一描述对象排序。

- `subject varchar(200)` 可空，是公司、人物、项目等自由文本，不建立强制实体表。
- `occurred_at timestamptz not null` 保存事件时点，默认 `now()` 只作为新建请求的数据库后备。
- `captures_occurred_idx` 支持日期范围筛选。
- `captures_subject_trgm_idx` 支持描述对象部分匹配；组合全文索引同时包含标题、描述对象和正文。

## 8. AI 主题综合快照

Migration `0011_topic_syntheses.sql` 增加 `topic_syntheses`。每次生成先插入 `running` 行，再调用 Provider；成功保存结构化 payload，失败只记录错误和耗时，不覆盖旧档案。

- `source_snapshot jsonb` 冻结当时最多 100 条活跃 Capture、相关 Claim、最新人工 Review 与有效证据数量。
- `source_hash` 对稳定序列化后的快照计算 SHA-256，用于读取时判断过期。
- `status` 表示执行状态，`decision` 独立表示人工接受或驳回；只有 `succeeded + pending + 未过期` 可以决策。
- `provider/model/prompt_version/schema_version/request_id/token/latency` 保留运行审计。
- Category 删除时级联删除综合历史；Capture、Claim 或 Review 变化不会修改旧快照，只会使其过期。

## 9. 来源权威性、独立复核与发布版本

Migration `0012_reliable_knowledge_release.sql` 增加三类追加式实体，并为 `claim_reviews` 增加结论作者身份：

- `source_authority_assessments` 绑定 `evidence_id + evidence_version`，记录层级、发布主体、依据和评估者；读取时只使用当前 Evidence 版本的最新评估。
- `independent_claim_reviews` 绑定 ClaimReview 与服务端 reviewer ID，并保存所复核结论、证据哈希及来源权威性评估的输入快照和 SHA-256；唯一索引阻止同一身份覆盖同一结论版本。
- `knowledge_releases` 以 `claim_id + release_number` 递增，保存完整 JSONB 快照、快照 SHA-256 和发布者身份。

发布服务重新读取当前结论及其冻结 Evidence，确定性检查证据数量、来源检查 ID、来源权威性、独立来源身份、强来源与职责分离。Migration `0013_release_deletion_policy.sql` 将 Release 到 Claim/ClaimReview 的外键改为级联删除：版本在来源存在期间不可变，但用户显式永久删除 Capture 时不会遗留内容副本。

Migration `0014_independent_review_input_snapshot.sql` 为独立复核增加输入快照与哈希。当前结论、证据版本/哈希、快照有效性或来源权威性评估变化后，旧复核读取时标记 stale，不再满足发布门槛。

## 10. 数据导入（Migration `0015`–`0019`）

导入是「把另一套 KnowTrace 实例的导出文件并进来」的通道。设计上把「运行记录」「对象溯源」
「内容归属」三件事分别落表，而不是把状态塞进 JSONB —— 因为它们各自有独立的唯一性约束与查询需求。

### data_import_runs（`0015_data_import_runs.sql`）

一次导入尝试一行，状态机为 `previewed → importing → completed | failed`。

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| actor_id / actor_name | varchar(100) / varchar(255) | 发起导入的身份与显示名快照 |
| file_name | varchar(255) | 上传文件名 |
| file_sha256 | varchar(64) | 文件内容摘要，CHECK 长度必须为 64 |
| format_version | varchar(20) | 导出格式版本 |
| status | data_import_status | 见上状态机 |
| staged_payload | jsonb | 预演阶段暂存的完整负载 |
| preview_summary | jsonb | 预演结论（将新增/冲突/跳过的条数） |
| result_summary | jsonb | 可空，完成后的实际结果 |
| error_code / error_message | varchar(80) / varchar(1000) | 可空，失败时的脱敏错误 |
| created_at / started_at / completed_at | timestamptz | 时间线 |

索引：`(actor_id, created_at)`、`(status, created_at)`。
`0015` 时的唯一键是「文件内容」，但去重语义后来被认为应该按「人 + 对象 + 版本」判，
于是 `0018`/`0019` 把溯源搬到独立的 `data_import_objects` 表（见下）。

### data_import_objects（`0018` 建立，`0019` 修唯一键）

每个被导入的实体一行，记录「这次导入的哪个源对象，对应到本地哪个 ID」。

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| actor_id | varchar(100) | 发起者 |
| format_version | varchar(20) | 导出格式版本 |
| object_type | varchar(40) | CHECK 限定为 capture/category/claim/evidence/attachment/source_check/review 七类 |
| source_key | varchar(100) | 源实例里的稳定标识 |
| local_id | uuid | 落到本地后的主键 |
| content_hash | varchar(64) | 内容摘要，CHECK 长度 64 |
| import_run_id | uuid | 外键 → `data_import_runs(id)`，**`ON DELETE RESTRICT`**（有溯源就不许删运行记录） |
| created_at | timestamptz | 创建时间 |

唯一键演进是这张表的重点：

- `0018`：`unique(actor_id, object_type, source_key)`
- `0019`：改为 `unique(actor_id, format_version, object_type, source_key)`

**为什么要加 `format_version`**：同一个源对象在格式升级后可能被重新导入一次，
而两次的语义不同。不含版本号的唯一键会把第二次导入判成重复而静默丢弃 —— 这是
「幂等」与「重放」的边界，必须显式建模。

### 内容归属（`0016_content_ownership.sql`）

在 `captures` 与 `categories` 上增加 `created_by_id`（varchar(100)，默认 `legacy-local`）
与 `created_by_name`（varchar(255)，默认「本地历史数据」），并把唯一键从全局改为**按创建者**：

- `captures`：`unique(idempotency_key)` → `unique(created_by_id, idempotency_key)`
- `categories`：`unique(normalized_name)` → `unique(created_by_id, normalized_name)`

**这是本项目第一次把「谁的」写进唯一约束。** `0017`–`0021` 都在这条线上继续加维度
（先加 visibility，再加 workspace），见第 11 节。

### 共享与导入指纹（`0017_shared_admin_content_and_import_fingerprint.sql`）

- 新增枚举 `capture_visibility`（`private` / `shared`），`captures.visibility` 默认 `private`。
- 数据回填：`created_by_id IN ('local-owner','go-user:1')` 的历史记录置为 `shared`
  —— 这两个身份是「管理员」，其内容对全站可见；其余保持 `private`。
- `captures.import_fingerprint varchar(64)` 可空，配部分唯一索引
  `unique(created_by_id, import_fingerprint) WHERE import_fingerprint IS NOT NULL`
  —— 让重复导入可被识别，同时不惩罚「本来就没有指纹」的本地创建记录。

**注意这张表在 `0020` 里被再次改键**：`created_by_id` 维度的唯一索引全部加上 `workspace_id`
前缀。所以 `0016`/`0017` 建立的约束**在生产库里已被 `0020` 取代**，此处记录的是演进过程。

## 11. Workspace 隔离（Migration `0020`–`0021`）

Workspace 是当前最大的一次数据边界变更：**所有可归属的业务行都从「全局」收敛到「某个 Workspace 内」。**
决策记录见 [ADR-0017](adr/0017-workspace-isolation-model.md)，
架构侧影响见 [`06-architecture.md`](06-architecture.md) 第 5 节。

### workspaces（`0020_workspace_foundation.sql`）

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| name | varchar(100) | 展示名 |
| slug | varchar(80) | CHECK `^[a-z0-9]+(?:-[a-z0-9]+)*$`；唯一 |
| created_by_id / created_by_name | varchar(100) / varchar(255) | 创建者 |
| created_at / updated_at | timestamptz | 时间 |

索引：`unique(slug)`、`(created_by_id, created_at)`。

### workspace_memberships

主键 `(workspace_id, actor_id)`；`role` 为枚举 `workspace_member_role`（`owner` / `member`）。
`workspace_id` 外键 `ON DELETE cascade`。另有 `(actor_id, workspace_id)` 索引用于「我属于哪些空间」。

### 迁移的兼容策略（这段是 `0020` 最值得读的部分）

`workspace_id` 是 `NOT NULL + DEFAULT 默认空间` 加的，先把历史数据整体归入一个默认空间，
再靠回填把「已知的活动者」补成成员：

1. 建一个固定 UUID 的默认空间：`00000000-0000-4000-8000-000000000001`（slug `legacy-default`）。
2. 插入两条 owner 成员：`local-owner`、`go-user:1`。
3. 用一条 `WITH known_actors AS (… UNION ALL …)` 从 `captures` / `categories` /
   `claim_reviews` / `source_authority_assessments` / `independent_claim_reviews` /
   `knowledge_releases` / `data_import_runs` **七张表**里收集全部出现过的 `actor_id`，
   去重后按「是否管理员」定角色，`ON CONFLICT DO UPDATE` 补进成员表。
4. 给 `captures` / `categories` / `data_import_runs` / `data_import_objects` 四张表
   加 `workspace_id`（默认空间，外键 `ON DELETE restrict`）。
5. 把 4 组唯一/普通索引**逐一 DROP 后按带 `workspace_id` 的新形态重建**（等价于「改键」）。

**为什么用固定 UUID 而不是 `gen_random_uuid()`**：迁移是幂等的幂等关键 —— 这个 ID 会被
单元测试与恢复演练引用，必须是可预期的常量。**为什么外键用 `restrict` 不用 `cascade`**：
删空间不能顺手删掉里面的内容，那是最不该发生的一类误删。

### 审计身份与执行者（`0021_workspace_audit_identity.sql`）

`0020` 覆盖了「内容行」，`0021` 覆盖「审计行」—— AI 运行与主题综合也是可归属的对象。
这里刻意**先带 DEFAULT 回填、再 `DROP DEFAULT`**：

1. `ai_processing_runs` 加 `workspace_id`（默认空间）+ `actor_id` / `actor_name`
   （默认 `legacy-unknown` / 「历史执行者未知」）。
2. 回填 workspace：`UPDATE … SET workspace_id = capture.workspace_id FROM captures`
   —— **不是全塞默认空间，而是跟随所属 Capture**，所以历史 AI 运行会落到它那条 Capture 所在的（默认）空间。
3. 三列全部 `DROP DEFAULT` —— 此后新写入必须显式给出归属，不允许再落进「默认」。
4. 加索引 `(workspace_id, actor_id, created_at)`。
5. `topic_syntheses` 同样处理，但回填跟随的是 `categories.workspace_id`（综合挂在 Category 上）。

**`DROP DEFAULT` 是这一步的真正目的**：加列时给默认值是为了让迁移能跑，
跑完必须撤掉，否则「漏写归属」会静默落到默认空间而不是报错 —— 那正是隔离模型最怕的失败模式。
