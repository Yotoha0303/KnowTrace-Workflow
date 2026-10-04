# AI 处理规范

> 最后核对：**2026-08-23**，依据 `035753e`。
> 本行**只在内容变更时**更新，不随改名/格式化变动——约定见 [CONTRIBUTING.md](../CONTRIBUTING.md)「目录与命名约定」。

## 1. 当前职责

P0 的 AI 只辅助整理已经保存的 Capture：

- 判断 Content Type。
- 建议标题和摘要。
- 匹配已有 Category。
- 建议新的 Category 名称。
- 拆分候选语义单元。
- 提供可逐条选择的局部原文修改建议。
- 提取最多 3 个可证伪主张候选。
- 识别待补充问题和明显质量风险。

P0 不负责：

- 自动联网搜索事实。
- 宣布内容真实或可靠。
- 自动发布知识。
- 未经用户逐条确认就修改原始正文。
- 调用任意外部工具。

## 2. Provider 接口

```ts
type OrganizeRequest = {
  captureId: string
  captureVersion: number
  content: string
  currentTitle: string | null
  currentContentType: ContentType
  availableCategories: Array<{ id: string; name: string }>
  promptVersion: string
  schemaVersion: string
}

interface AIProvider {
  organize(
    request: OrganizeRequest,
    options: { signal: AbortSignal },
  ): Promise<ProviderResult>
}
```

OpenAI 和 DeepSeek 分别实现 Adapter。不能假设两者在超时、错误、结构化输出和用量字段上完全一致。

连接配置支持以下模式：

- `server`：使用服务端环境变量中的 Key 和默认模型。
- `api_key`：使用 AI 整理台为本次请求提供的 Key，可选覆盖模型 ID。
- `ccswitch_auto`：通过受限的本机 `/v1/messages` 路由跟随 CC-Switch 当前供应商；模型只输出 JSON 文本，KnowTrace-Workflow 负责严格 Schema 校验，不依赖供应商工具调用。
- `ccswitch`、`ccswitch_codex_oauth`：只保留服务端兼容；前者曾调用 `/v1/responses`，新 UI 会把两种旧浏览器会话迁移到 `ccswitch_auto`，避免供应商切换后误走固定协议。

请求级 Key 只存在于 Server Action 入参和 Provider 调用内存中，不进入 `input_hash`、AI Run、Suggestion 或日志。跟随当前供应商的运行记录使用 `ccswitch-current-provider`，Responses 路由使用 `openai-ccswitch`，以便审计时与官方直连区分。

## 3. 输出 Schema

示例：

```json
{
  "suggested_title": "AI 个人知识库设想",
  "summary": "记录零散内容，并通过 AI 辅助完成分类和后续整理。",
  "content_type": "thought_fragment",
  "existing_category_candidates": [
    {
      "category_id": "uuid",
      "reason": "内容讨论知识库项目",
      "confidence": 0.88
    }
  ],
  "new_category_candidates": [
    {
      "name": "AI 知识管理",
      "reason": "主要主题是 AI 辅助管理知识",
      "confidence": 0.84
    }
  ],
  "content_suggestions": [
    {
      "type": "rewrite",
      "source_excerpt": "输入不确定性，输出结构化和系统化的内容",
      "suggested_text": "将不确定输入整理为结构化、系统化内容",
      "reason": "补足动作关系，让目标更直接",
      "confidence": 0.86
    }
  ],
  "claim_candidates": [
    {
      "statement": "持续复盘能够提高问题处理效率",
      "source_excerpt": "持续复盘能够提高问题处理效率",
      "falsification_criteria": "同等条件下复盘组的处理效率没有提高，或低于对照组",
      "reason": "这是可以通过对照数据支持或反驳的效果陈述",
      "confidence": 0.78
    }
  ],
  "semantic_units": [
    {
      "type": "goal",
      "content": "将不一致输入整理为结构化内容",
      "source_excerpt": "输入不确定性，输出结构化和系统化的内容",
      "confidence": 0.9
    }
  ],
  "open_questions": [
    "哪些分类需要人工维护？"
  ],
  "quality_flags": [
    {
      "code": "UNSUPPORTED_EXPECTATION",
      "message": "提高处理效率是目标，当前内容没有提供验证数据"
    }
  ]
}
```

允许的语义类型：

```text
topic
concept
goal
requirement
constraint
question
scenario
observation
experience
claim
lesson
action
resource
unknown
```

## 4. 确定性校验

模型响应必须经过 Zod Schema：

- 拒绝未知枚举。
- 限制数组数量和文本长度。
- `source_excerpt` 必须能在 Capture 正文中定位。
- 已有 Category ID 必须真实存在且处于 active。
- 新 Category 名称经过与手动创建相同的规范化校验。
- 已有分类与新分类候选合计最多保留 3 个，新分类最多 1 个，并优先复用已有分类。
- 局部修改的 `source_excerpt` 必须逐字存在、不得覆盖整篇原文、不得与另一条建议重叠，最多保留 5 条。
- Content Type 必须属于固定枚举。
- Confidence 只允许 0～1，但仅作为建议排序，不代表真实性。
- 主张候选必须有逐字来源片段和明确证伪条件，置信度至少 0.6，去重后最多保留 3 个。
- 目标、愿望、偏好、感受和定义不应生成 Claim 候选。
- 任何无法从原文定位的新事实标记为 unsupported，不得进入可直接接受的语义单元。

## 5. Prompt 注入边界

Capture 内容是不可信输入，可能包含“忽略之前规则”之类文本。

P0 处理规则：

- Prompt 明确将 Capture 放入数据区而不是指令区。
- 不向模型提供网络搜索、数据库写入或函数调用工具。
- 不允许模型选择 Provider、Base URL 或系统配置。
- 仅接受符合本地 Schema 的最终结果。
- 模型输出不能直接触发第二个外部动作。

## 6. Run 记录

每次调用在开始前记录：

```text
capture_id
capture_version
input_hash
provider
model
prompt_version
schema_version
request_id
started_at
```

完成后补充：

```text
status
latency_ms
input_tokens
output_tokens
error_code
completed_at
```

不保存模型隐藏推理过程。只有产品需要的结构化结果进入 Suggestion。

## 7. 错误分类

```text
AI_PROVIDER_NOT_CONFIGURED
AI_AUTHENTICATION_FAILED
AI_RATE_LIMITED
AI_PROVIDER_TIMEOUT
AI_PROVIDER_UNAVAILABLE
AI_CONTENT_REJECTED
AI_RESPONSE_INVALID
AI_RUN_INTERRUPTED
AI_INTERNAL_ERROR
```

供应商错误需要映射并脱敏，不能把原始错误体直接返回浏览器。

## 8. 超时与重试

P0 请求内调用：

- 使用 AbortSignal 设置总超时。
- 默认不在同一次请求中多次自动重试，避免用户重复等待和费用失控。
- 只允许对限流或临时不可用做最多一次短重试，具体值配置化。
- 用户手动重试创建新 Run。
- 进程中断留下的 running Run 由维护任务标记为 failed。

## 9. 建议决策

用户可以分别选择要接受的字段，而不是只有“全部接受”。

接受规则：

- 标题和 Content Type 通过版本化修订更新 Capture，并增加版本。
- 已有 Category 建立关联。
- 新 Category 先按普通业务规则创建，再建立关联。
- 摘要、语义单元和待补充问题保留在 Suggestion。
- 只有明确勾选的主张候选会创建 `candidate` Claim，默认一个也不创建。
- 正文只应用用户逐条勾选的局部建议，并保留 Revision；未选择部分保持不变。
- UI 使用同一确定性替换函数实时计算整篇“修改前/修改后”文本，预览与服务端写回语义一致。
- 接受时把采纳前核心字段、AI 分类、应用后的 Capture 版本和本次新建 Claim ID 写入 accepted payload，供受保护的整体回退使用。
- 只允许回退最近一次已采纳整理；后续正文/类型/标题修改、AI 分类变化或候选主张推进都会阻止回退。成功回退生成新 Revision 并保留完整处理历史。

## 10. 主张可靠性审查

Claim 可以使用同一 Provider 配置运行 `claim_audit`。输入仅包含主张、证伪条件、最新人工结论，以及已采纳且来源检查通过、摘录匹配的 Evidence 快照。

输出包括：

- 证据覆盖度 `limited / moderate / broad`。
- 证据平衡 `insufficient / one_sided / mixed`。
- 来源质量、覆盖缺口、矛盾、可证伪性、范围和时效问题。
- 最多 5 个待补检查。
- `supported / refuted / inconclusive / needs_more_evidence` 建议。

覆盖度与证据平衡由服务端根据证据数量、独立来源数和立场重新计算；模型引用的 Evidence ID 必须来自输入，否则移除。固定边界提示由服务端覆盖，模型不能把建议升级为事实裁决。每次审查保存 Run、输入证据快照和指纹；输入变化后旧结果显示过期。

## 11. 后续可靠性演进

当前已建立 Candidate Claim、Evidence、人工结论与 AI 可靠性审查。自动联网检索、来源权威性判断、独立审核角色、Claim 版本与最终发布仍在后续；不得在当前 Suggestion、Capture 或 Claim 上增加一个简单的 `verified` 布尔值。
