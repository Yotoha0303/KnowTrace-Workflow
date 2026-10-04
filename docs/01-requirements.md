# 业务需求

> 最后核对：**2026-08-30**，依据 `9f408a6`。
> 本行**只在内容变更时**更新，不随改名/格式化变动——约定见 [CONTRIBUTING.md](../CONTRIBUTING.md)「目录与命名约定」。

## 1. 术语

- **Capture**：用户原始记录及其当前版本。
- **Revision**：Capture 编辑前保存的不可变历史快照。
- **Content Type**：记录的主要内容形态，单选。
- **Category**：用户维护的主题分类，多选。
- **AI Run**：一次 AI 处理执行记录。
- **AI Suggestion**：AI Run 产生的候选整理结果。

## 2. 内容类型

首版固定枚举：

```text
keyword_set       关键词集合
thought_fragment  想法片段
experience        经历记录
observation       观察记录
question          问题
source_note       资料摘录
mixed             混合内容
unknown           尚未判断
```

Content Type 只描述形态，不表示真假。例如 `observation` 表示用户记录了一项观察，不代表该观察已被外部验证。

## 3. 用户故事

### 身份与数据范围

- 管理员可以查看和管理所有用户创建的 Capture、Category 及其派生内容。
- 普通成员只能管理本人创建的内容，同时可只读查看管理员共享内容；成员之间默认不共享，也不能通过搜索、导出、图片地址或猜测资源 ID 发现彼此私有内容。
- 创建者身份只接受 go-user-system 验证结果，不接受客户端提交的用户 ID 或角色。
- 历史无创建者数据标记为 `legacy-local`，只对管理员可见。

### US-01 快速保存

作为使用者，我希望只输入一段内容就能保存，以免整理过程打断想法。

验收标准：

- 正文至少有一个非空白字符。
- 标题、Content Type 和 Category 都可以为空。
- 描述对象可以为空；发生时间默认浏览器当前时间并允许通过日期时间选择器调整。
- 发生时间描述内容中的事件时间，不使用创建时间替代用户明确选择的时间。
- 服务端不自动重写标点、换行和词序。
- 数据库提交成功后才能显示保存成功。
- AI 调用不出现在保存事务中。

### US-02 手动分类

作为使用者，我希望给记录指定内容类型和多个主题分类。

验收标准：

- 一条 Capture 最多一个 Content Type。
- 一条 Capture 可以关联零个或多个 Category。
- 重复关联同一 Category 保持幂等。
- 已归档 Category 不能新增关联，但原有关系保留。
- 修改分类不创建正文 Revision，但需要更新时间。

### US-03 管理分类

作为使用者，我希望创建和维护自己的主题分类。

验收标准：

- Category 名称必填并进行规范化后唯一判断。
- 没有关联任何 Capture 的 Category 可以在二次确认后永久删除；有关联记录时必须拒绝，记录是否归档不影响该限制。
- 支持重命名和归档。
- MVP 不做无限层级目录；Category 为扁平结构。
- Category 归档不影响 Capture 本身。

### US-04 修订内容

作为使用者，我希望修改内容但保留旧版本。

验收标准：

- 更新时提交 `expected_version`。
- 更新前正文、标题、类型和版本写入 Revision。
- 版本冲突返回明确错误，不覆盖较新的版本。
- Revision 只读。

### US-05 AI 整理

作为使用者，我希望主动让 AI 整理某个版本的记录。

验收标准：

- 先保存 Capture，再触发 AI。
- 编辑器存在未保存修改时阻止调用，明确提示先保存并把焦点移到保存按钮；调用入口显示将要分析的版本号。
- 创建 AI Run 后立即记录 `provider/model/prompt_version/capture_version`。
- Run 最终进入 succeeded、failed 或 cancelled。
- AI 返回值必须通过结构校验后才能生成 Suggestion。
- AI 错误不能改变 Capture 或分类。

### US-06 处理 AI 建议

作为使用者，我希望检查建议后选择接受、修改或拒绝。

验收标准：

- Suggestion 显示来源 Capture 版本。
- Capture 已更新时明确标记建议过期。
- 接受标题、Content Type 或 Category 必须是显式操作。
- 接受标题或 Content Type 时复用 Capture 修订规则并增加版本；只接受 Category 时不增加正文版本。
- 摘要和语义单元保留在 Suggestion 中，不替换原文。
- 勾选局部原文建议时，实时显示基于已保存版本的整篇修改前/修改后对比，确认前不写回。
- 最近一次 accepted/modified Suggestion 保存采纳前快照；没有后续 Capture 修改、AI 分类变化或候选主张推进时，允许整体回退并生成新的 Revision。
- 整体回退恢复标题、正文、Content Type 和 AI 分类，删除本次新建且仍为 candidate 的主张；保留手动分类、Suggestion 和版本历史。
- 每个 Suggestion 只允许完成一次最终决策。

### US-07 回看最近记录

作为使用者，我希望按时间查看最近内容，并能进入某个分类。

验收标准：

- 默认按创建时间和 ID 倒序。
- 支持稳定游标分页。
- 可以查看某一个 Category 下的记录。
- 暂不支持多个条件组合筛选。

### US-08 AI 可靠性审查

作为使用者，我希望 AI 帮我检查主张的证据是否单一、不完整或缺少反例，但不能替我决定真假。

验收标准：

- 只使用已采纳、来源通过且摘录匹配的 Evidence。
- 运行时显示处理状态和等待时间。
- 结果包含证据覆盖、正反平衡、问题与待补检查，并固定显示非事实裁决边界。
- 审查保存输入快照、指纹、Provider、模型、耗时和状态。
- 审查不修改 Claim、Evidence、人工 Review 或状态；输入变化后旧结果标记过期。

### US-09 统一检索与主题档案

作为使用者，我希望凭一段不完整线索同时找到相关原文、主张、证据和结论，并能按主题回看知识进展。

验收标准：

- 检索词最多 100 个字符，按对象类型和 Category 组合限制结果。
- 描述对象自由填写、最多 200 字，并同时支持全文命中和独立部分匹配筛选。
- 发生时间支持开始/结束日期筛选，首次进入检索页时两者默认当前日期，结束日期包含当天全部时间；用户可以清空日期查询全部时间。
- 每类结果有界返回，显示对象状态、Category 和来源 Capture 回链。
- Capture、Claim、Evidence 和人工 Review 必须分组展示，不混成无来源摘要。
- Category 页面显示活跃/归档记录、Claim 状态、Evidence 数量、有效采纳证据与最新人工结论。
- 检索与主题档案只读，不改变任何业务状态。

### US-10 无链接证据人工核验

作为使用者，我希望微信截图、聊天记录、现场照片或线下材料即使没有公共网页链接，也能经过明确、可追溯的人工核验后进入证据采纳流程。

验收标准：

- 来源 URL 可以留空；无链接 Evidence 至少上传一张图片后才能进行人工核验。
- 每张图片可以在网页中预览并打开原图；文件仍保存在项目上传目录。
- 人工核验前必须显式确认已查看全部图片，且保存的摘录与附件内容一致。
- 核验记录区分 `web` 与 `manual_attachment`，并保存固定确认说明、时间和所使用的附件。
- 核验记录必须绑定 Evidence 版本与附件 SHA-256；Evidence 或附件变化后旧核验不得继续生效。
- “已保存”“已核验”“已采纳”必须是不同状态，上传图片不能自动推进状态。
- 人工核验通过后仍需单独点击采纳；至少一条已采纳证据后才能提交待审核。
- 当前只记录本地使用者的显式确认；小群体审核者身份、权限和职责分离仍需后续实现。

### US-11 相似记录发现

作为使用者，我希望打开一条记录时看到过去相似的对象、主题或场景，从而复用以前的经验。

验收标准：

- 最多返回 5 条其他 Capture，不返回当前记录，每条都能回到完整原文。
- 命中原因必须显示同一描述对象、共同分类或文字相似度，不提供无解释推荐。
- 只有共同分类但几乎没有文字重合时不能入选，避免大分类产生大量噪声。
- 活跃和归档记录均可作为历史线索，并明确显示状态和发生日期。
- 相似结果只读且实时计算，不创建关系边，不改变任何知识可靠性状态。
- 页面明确声明相似不代表观点一致、内容真实或已经验证。

### US-12 描述对象时间线

作为使用者，我希望按公司、人物或项目回看相关事件，避免把记录时间误当成事件发生时间。

验收标准：

- 对象索引只统计活跃 Capture，并按标准化后的非空描述对象聚合。
- 时间线按 `occurred_at` 升序展示记录、分类、主张和最新人工审核。
- 页面明确区分事件发生时间、记录写入时间与人工审核时间。
- 对象名称可以回到全文检索继续组合筛选。

### US-13 AI 主题综合档案

作为使用者，我希望 AI 把一个 Category 中的散碎材料归纳为系统化档案，同时能检查每个要点来自哪里。

验收标准：

- 调用 AI 前冻结最多 100 条活跃 Capture、相关 Claim、最新人工 Review 和有效证据数量，并保存输入哈希。
- AI 输出通过结构化 Schema；引用的 Capture/Claim ID、依据层级、时间点和边界提示由服务端确定性校验。
- 综合结果区分人工审核依据、候选主张依据和原始记录依据，不把三者混成已证实事实。
- 每次运行保存 Provider、模型、状态、耗时、Token、错误和输入快照；失败不覆盖既有成功档案。
- 成功结果需要人工接受或驳回；当前输入变化后旧结果标记过期且禁止接受。
- OpenAI、DeepSeek、CC-Switch 和本地规则共用现有连接配置；UI 凭据不持久化到数据库。

### US-14 身份化独立复核与可靠发布

作为小群体使用者，我希望把证据边界清楚的人工结论冻结为可追溯版本，但不能由同一个人既下结论又自我批准。

验收标准：

- 结论保存 go-user-system 服务端身份；认证关闭时使用明确的本地占位身份，但不满足独立复核门槛。
- 结论中的每条 Evidence 必须评估当前版本的来源层级、发布主体和至少 10 字依据；Evidence 版本变化后旧评估失效。
- 发布至少需要 2 条仍然有效的冻结证据、2 个独立站点或线下发布主体，并至少包含一条第一手、官方或专业来源。
- 独立复核者必须是不同于结论作者的已登录账号；同一账号对同一结论版本只能提交一次决定。
- 独立复核冻结当时的结论、证据哈希与来源权威性评估；任一输入变化后旧复核标记过期，不得用于新发布。
- 任一独立复核提出修改要求时，当前结论版本不能发布，应退回调查并形成新结论。
- 发布前服务端重新计算所有门槛；成功后冻结主张、结论、证据哈希、权威性评估、独立复核、发布者和 SHA-256。
- 发布版本只追加、不静默覆盖；显式永久删除来源 Capture 时级联删除发布版本，保持用户删除语义一致。

### US-15 CC-Switch 当前供应商自动识别（已实现）

作为使用 CC-Switch 的用户，我希望在处理引擎中选择 CC-Switch 后，KnowTrace-Workflow 能自动识别并显示当前实际供应商，例如 Codex、DeepSeek 或其他兼容大模型，而不是只显示通用的“当前供应商”。

当前缺口：现有实现能够检查 CC-Switch 代理是否可达，并用小型结构化请求验证当前路由能否完成 AI 整理；但不能可靠识别供应商身份，也不能在 CC-Switch 切换到 DeepSeek 等供应商后自动更新显示。模型路由名和返回模型名均可能被 CC-Switch 映射，不能单独作为供应商身份依据。

下一迭代验收标准：

- 选择 CC-Switch 后自动检测代理状态、实际供应商和实际模型，分别展示“代理可达”“供应商已识别”“模型能力测试通过”三种状态。
- 至少覆盖 Codex、DeepSeek 和一个其他兼容供应商；未知供应商必须显示为“未识别”，不能猜测。
- 用户在 CC-Switch 中切换供应商后，KnowTrace-Workflow 能重新检测并更新名称，不要求清理浏览器缓存或手动修改模型路由名。
- AI Run 保存当次检测到的供应商标识、显示名称、实际模型和检测时间，供后续追溯；不得保存 API Key、OAuth token 或 CC-Switch 敏感配置。
- 供应商无法识别、代理未启动和模型能力不兼容必须给出不同提示；不能只显示持续加载动画。

状态：已实现。KnowTrace-Workflow 读取 CC-Switch 状态与模型目录，区分代理可达、供应商身份和可用路由；可用路由检测成功后不再强制每次手工测试。未知供应商保持“未识别”，不会猜测名称。

### US-16 Excel/ZIP 导出与导入主张、证据及附件（已完成）

作为使用者，我希望 Excel 数据迁移不仅保存原始记录和分类，还能保存其主张、证伪条件、证据摘录、来源信息、核验状态、人工结论和证据图片，从而在另一个 KnowTrace-Workflow 实例中继续原有知识调查，而不是只得到失去证据链的原文。

验收标准：

- 新增版本化的 `v2` 交换格式，使用独立工作表和稳定 ID 表达 Capture、Claim、Evidence、来源/附件检查、ClaimReview 及其关系。
- 证据图片通过 ZIP 附件与 SHA-256 manifest 携带，导入后可以在线查看；不得在 Excel 中保存机器绝对路径。
- 导入必须先预检再确认，完整验证引用、版本、权限、状态依赖和附件哈希，并以事务避免部分写入。
- 重复导入按当前用户与稳定对象身份幂等处理，冲突必须显式报告，不静默覆盖。
- 明确可编辑交换包能否恢复已采纳/已审核状态；没有受信任完整性机制时必须安全降级为待核验。
- 继续兼容当前 `v1` Excel 导入；Excel 交换包仍不能替代 PostgreSQL、认证数据库和上传目录的完整备份。

状态：已完成。`v2` 已实现主张、证据、来源/附件检查、人工结论、结论证据关系和图片 manifest 的 Excel 生成/解析，以及 `manifest.json + knowtrace.xlsx + attachments/` ZIP 包；导入会校验工作簿与附件 SHA-256、大小、MIME、路径和引用完整性，并拒绝目录穿越、额外文件和超限附件。Capture/Category 复用 `v1` 预检与事务语义，Claim/Evidence/Attachment 使用按 actor、格式版本和稳定对象身份隔离的 provenance，实现 `create / skip / repair / conflict`。确认导入会重新校验服务端暂存 ZIP、文件哈希和数据库预检快照，并在单个数据库事务中写入基础对象与知识链；附件文件失败时执行补偿清理。当前数据迁移页同时支持 `.xlsx v1` 与 `.zip v2`，可信状态按非受信任交换包策略安全降级。隔离恢复验收已使用两套独立 KnowTrace-Workflow App + PostgreSQL 实例完成真实 HTTP 导出/预检/确认链路，验证空白实例恢复、图片在线读取与 SHA-256 一致、同一 actor 第二次导入全量幂等；同一真实目标 PostgreSQL 上还验证了第二 actor 使用独立 provenance 重新创建，不跨 actor 错误去重。详细范围与测试矩阵见 `KT-DEFER-005`。

### US-17 Workspace 数据隔离（已完成并部署）

作为多个用户和后续组织协作场景的使用者，我希望 KnowTrace-Workflow 以 Workspace 作为数据边界，而不是仅依赖单个 actor/管理员可见性规则，从而让同一账号可以进入不同空间，并保证记录、知识链、搜索、导入导出和附件不会跨 Workspace 泄露。

阶段目标：先完成**数据隔离和 Workspace 上下文**，不在本阶段同时展开复杂 RBAC、计费、Agent 权限或组织管理。

验收标准：

- 新增稳定 Workspace 实体与成员关系；每个需要业务隔离的对象必须能够确定唯一 Workspace 归属。
- 当前 Workspace 必须由服务端会话/成员关系解析，客户端不能通过伪造 `workspace_id` 越权访问其他空间。
- Capture、Category、Claim、Evidence、Review、AI Run、Topic、可靠发布、附件、搜索和数据迁移都必须使用一致的 Workspace 过滤边界。
- 直接猜测对象 ID、图片 ID、导入 run ID 或 API 路径时，跨 Workspace 资源必须表现为不可访问，不能通过 403/404 差异泄露存在性。
- 同一用户可以属于多个 Workspace，并能显式切换当前 Workspace；切换后列表、搜索、分类、主题、导入导出和 AI 上下文全部同步切换。
- 现有数据需要迁移到明确的默认 Workspace；迁移必须可重复验证，不允许产生无 Workspace 的悬空业务数据。
- v1/v2 导入导出的幂等和 provenance 身份必须纳入 Workspace 边界；相同 actor 在不同 Workspace 导入同一包时不能错误去重。
- 审计记录至少保留 actor 与 Workspace 身份，后续细粒度角色授权可在此基础上扩展。
- 自动化测试至少覆盖：同用户跨 Workspace 隔离、不同用户同 Workspace 合法访问、跨 Workspace ID 猜测、搜索/附件/导出隔离、迁移兼容和 provenance 隔离。

完成标准：在两个真实 Workspace 中构造相同内容与知识链，任何查询、搜索、图片、导入导出和直接资源访问都只能看到当前 Workspace 数据；切换 Workspace 后上下文完整切换且不存在跨空间缓存污染。

状态：已完成并部署。`0020_workspace_foundation.sql` 已建立 Workspace、Membership、默认 Workspace 迁移以及 Workspace-aware 的 Capture/Category/import run/provenance/idempotency 边界；`0021_workspace_audit_identity.sql` 为 AI Run 与 Topic Synthesis 补充显式 Workspace 与 actor 审计身份。当前 Workspace 由服务端 Cookie + Membership 校验解析，桌面 Sidebar 与移动导航均可显式切换。Workspace 所有者还可删除空的非默认 Workspace：默认空间永久保护、成员无删除权、删除前必须输入完整空间名称确认、有任一业务数据时返回 `WORKSPACE_NOT_EMPTY`，删除当前空间后服务端自动切回默认 Workspace。真实双实例/双 Workspace HTTP 验收已覆盖列表、详情、分类、搜索、主张、对象聚合、图片、v2 导出、import run ID、幂等、provenance 以及 Workspace 删除权限/空状态保护；跨 Workspace 资源与不存在资源保持同类 404，不通过状态差异泄露存在性。生产实例已依次应用 `0020` 与 `0021` 并恢复健康。

### US-18 移动 App（第二阶段）

在 Workspace 数据隔离稳定后，作为移动端使用者，我希望通过真正的移动 App 快速记录、查看和继续处理 KnowTrace-Workflow 内容，而不是依赖桌面网页缩放版。

阶段顺序：**US-17 Workspace 数据隔离完成并验收后再启动 US-18**，两者不并行开发。

首期范围：

- 复用现有服务端认证与 `/api/v1` 能力，不在移动端复制业务规则或可信状态判断。
- 支持登录、当前 Workspace 选择、快速 Capture、新建/查看记录、最近记录、基础搜索和记录详情。
- 支持移动端图片选择/拍摄并上传为 Evidence 附件，继续复用服务端 MIME、大小、SHA-256 和权限校验。
- 网络不稳定时至少保证重复提交不会产生重复 Capture；是否实现完整离线队列在移动阶段设计时单独决定。
- Token/会话必须使用移动平台安全存储方案，不能把长期凭据写入普通本地存储或日志。
- App 只消费公开稳定 API，不直接连接 PostgreSQL、MySQL、Redis 或本地文件目录。
- Workspace、用户、Capture、Claim、Evidence 与附件权限必须与 Web 端保持同一服务端授权结果。
- 技术方案在启动本阶段时再在 React Native/Expo、Flutter 等方案中评估；不预先把“WebView 包装网页”视为完成标准。

完成标准：至少在一台真实移动设备上完成登录 → 选择 Workspace → 新建 Capture → 查看同步结果 → 上传图片证据 → 再次读取的闭环，并验证弱网重试、权限隔离和凭据存储边界。

## 4. 状态

Capture：

```text
active
archived
```

Category：

```text
active
archived
```

AI Run：

```text
running
succeeded
failed
cancelled
```

AI Suggestion：

```text
pending
accepted
modified
rejected
stale
```

Claim：

```text
candidate
investigating
ready_for_review
concluded
withdrawn
```

Evidence Review：`unreviewed / accepted / rejected`。Evidence Source Check：`unchecked / passed / failed`。`passed` 仅表示安全抓取成功；Evidence 仍需摘录匹配和人工采纳。

Claim Assessment：`supported / refuted / inconclusive`。Assessment 描述“基于冻结证据的当前判断”，不是脱离时间与上下文的真实性布尔值。

AI Audit Recommendation：`supported / refuted / inconclusive / needs_more_evidence`。它只能作为人工判断建议，不是 Claim 状态或结论。

## 5. 数据限制

- Capture 正文：1～20,000 个 Unicode 字符，可配置。
- Capture 标题：最多 200 个字符。
- Capture 描述对象：最多 200 个字符，可空。
- Capture 发生时间：必填 ISO 时间；新建时由浏览器当前时间初始化。
- Category 名称：1～60 个字符。
- 每条 Capture 最多关联 20 个 Category。
- 每次 AI 最终展示最多 12 个语义单元、3 个候选分类（其中新分类最多 1 个）、5 条局部原文建议和 10 个待补充问题。
- 所有时间保存为 UTC。

## 6. 非功能需求

### 可靠性

- 创建和修订使用数据库事务。
- 创建支持幂等键，网络重试不产生重复记录。
- AI Run 先落库再调用供应商，调用完成后保存结果。
- 供应商超时后 Run 必须结束为 failed，不能长期停留 running。

### 性能

- 不调用 AI 时，单实例本地环境创建 Capture 的 P95 目标小于 500ms。
- 最近列表默认 20 条，最大 100 条。
- 首版按单实例、20 个同时访问者设计。
- 中文片段检索使用 `pg_trgm` 索引；统一检索每类最多返回 50 条，页面默认 20 条。

### 安全

- 身份由 go-user-system 提供，KnowTrace-Workflow 只接受服务端验证后的用户与角色上下文；业务数据还必须经过当前 Workspace Membership 和资源级访问策略校验，客户端提交的用户、角色或 Workspace 标识不能直接成为授权依据。
- AI API Key 可以来自服务端环境变量，也可以由用户在 AI 整理台为单次请求提供；UI Key 不写入数据库、AI Run 或服务端日志。
- UI Key 只有在用户明确勾选时才保存到当前标签页的 `sessionStorage`，关闭标签页后失效。
- 日志不记录完整正文、Prompt、API Key 或供应商原始敏感错误。
- OpenAI 的 CC-Switch 地址只允许本机白名单地址和 `/v1` 路径，不允许客户端指定任意远程 Provider Base URL。
- Evidence 来源检查只允许标准端口 HTTP(S) 公网地址；DNS 和每次重定向都必须经过 SSRF 地址策略，响应体限制为 1 MB。

### 可观测性

- 每个写操作和 AI Run 有可关联的 request_id。
- 记录路由、耗时、状态、错误码。
- AI 日志记录 provider、model、task、latency、token usage，不记录全文。

## 7. 统一错误格式

```json
{
  "error": {
    "code": "CAPTURE_VERSION_CONFLICT",
    "message": "记录已经更新，请刷新后重试",
    "request_id": "req_01...",
    "details": {}
  }
}
```
