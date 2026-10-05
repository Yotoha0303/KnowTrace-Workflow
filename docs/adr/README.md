# 架构决策记录

ADR 用于记录重要技术决策及其背景，避免以后只知道“用了什么”却不知道“为什么”。

决策索引：

- [ADR-0001：使用 Go 模块化单体（已替代）](0001-modular-monolith.md)
- [ADR-0002：原始记录与 AI 建议分离](0002-preserve-raw-capture.md)
- [ADR-0003：原 P0 记录优先方案（已替代）](0003-record-first.md)
- [ADR-0004：采用 Next.js 全栈单体](0004-nextjs-fullstack.md)
- [ADR-0005：分类与 AI 整理进入 P0](0005-ai-classification-in-p0.md)
- [ADR-0006：移除应用内身份与授权（已替代）](0006-no-application-auth.md)
- [ADR-0007：以候选主张和证据门槛扩展可靠性流程](0007-candidate-claim-workflow.md)
- [ADR-0008：证据采纳前进行可审计的来源完整性检查](0008-auditable-evidence-source-checks.md)
- [ADR-0009：用证据边界结论替代 verified 布尔值](0009-evidence-bounded-claim-conclusions.md)
- [ADR-0010：AI 可靠性审查只生成有输入快照的非裁决建议](0010-bounded-ai-reliability-audits.md)
- [ADR-0011：先建立可追溯的统一检索读模型](0011-unified-knowledge-retrieval.md)
- [ADR-0012：先用可解释的本地信号发现相似记录](0012-explainable-similar-captures.md)
- [ADR-0013：通过 go-user-system 提供可选身份认证](0013-go-user-system-authentication.md)
- [ADR-0014：内置 go-user-system 源码并统一编排](0014-embedded-go-user-system.md)
- [ADR-0015：按创建者隔离业务数据](0015-creator-scoped-data-access.md)
- [ADR-0016：多平台客户端与原生令牌认证](0016-native-client-auth.md)
- [ADR-0017：以 Workspace 为数据边界的应用层隔离模型](0017-workspace-isolation-model.md)
- [ADR-0018：桌面端外壳的前提与形态选择（proposed）](0018-desktop-shell-prerequisites.md)

状态说明：

```text
proposed
accepted
superseded
rejected
```

已接受 ADR 不直接改写结论；如需改变，应新增 ADR 并将旧决策标记为 superseded。
