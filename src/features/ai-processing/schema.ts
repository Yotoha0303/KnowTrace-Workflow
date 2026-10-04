import { z } from "zod";

import { CONTENT_TYPES } from "@/features/capture/schema";

export const SEMANTIC_UNIT_TYPES = [
  "topic",
  "concept",
  "goal",
  "requirement",
  "constraint",
  "question",
  "scenario",
  "observation",
  "experience",
  "claim",
  "lesson",
  "action",
  "resource",
  "unknown",
] as const;

export const CONTENT_SUGGESTION_TYPES = [
  "clarify",
  "split",
  "rewrite",
  "supplement",
  "remove_redundancy",
] as const;

export const MAX_AI_CATEGORY_CANDIDATES = 3;
export const MAX_AI_NEW_CATEGORY_CANDIDATES = 1;
export const MAX_CAPTURE_CATEGORIES_AFTER_AI = 5;
export const MAX_CONTENT_SUGGESTIONS = 5;
export const MAX_CLAIM_CANDIDATES = 3;

export const CLAIM_AUDIT_FINDING_CATEGORIES = [
  "source_quality",
  "coverage_gap",
  "contradiction",
  "falsifiability",
  "scope",
  "freshness",
] as const;

export const AI_AUDIT_BOUNDARY_NOTICE =
  "AI 只分析已提供且来源已确认的证据，不会联网补证，也不能替代人工判断或宣告事实为真。";

const aiModelSchema = z
  .string()
  .trim()
  .min(1)
  .max(120)
  .regex(/^[A-Za-z0-9._:/-]+$/, "模型 ID 格式无效。");

export const aiConnectionSchema = z.discriminatedUnion("mode", [
  z.object({
    mode: z.literal("server"),
    model: aiModelSchema.optional(),
  }),
  z.object({
    mode: z.literal("api_key"),
    apiKey: z.string().trim().min(8, "API Key 长度不足。").max(1_000),
    model: aiModelSchema.optional(),
  }),
  z.object({
    mode: z.literal("ccswitch"),
    baseURL: z.string().trim().min(1).max(500),
    apiKey: z.string().trim().max(1_000).optional(),
    model: aiModelSchema.optional(),
  }),
  z.object({
    mode: z.literal("ccswitch_auto"),
    baseURL: z.string().trim().min(1).max(500),
    apiKey: z.string().trim().max(1_000).optional(),
    model: aiModelSchema.optional(),
  }),
  // CC-Switch 的 Codex OAuth 路由：入站说 Anthropic Messages 协议，所以模型名必须是
  // claude- 开头的**别名**；出站由 CC-Switch 转发（通常是 Codex / ChatGPT）。
  // 这个前缀不代表本项目使用 Claude 模型——见 AGENTS.md。
  z.object({
    mode: z.literal("ccswitch_codex_oauth"),
    baseURL: z.string().trim().min(1).max(500),
    apiKey: z.string().trim().max(1_000).optional(),
    model: aiModelSchema
      .refine(
        (value) => value.startsWith("claude-"),
        "Codex OAuth 转换路由需要使用 claude- 开头的模型别名。",
      )
      .optional(),
  }),
]);

export type AIConnectionInput = z.infer<typeof aiConnectionSchema>;

const ccSwitchConnectionBaseSchema = z.object({
  baseURL: z.string().trim().min(1).max(500),
  apiKey: z.string().trim().max(1_000).optional(),
});

export const detectCCSwitchSchema = ccSwitchConnectionBaseSchema;

export const testCCSwitchCurrentProviderSchema = ccSwitchConnectionBaseSchema.extend({
  model: aiModelSchema,
});

export const testCCSwitchCodexOAuthSchema = ccSwitchConnectionBaseSchema.extend({
  model: aiModelSchema.refine(
    (value) => value.startsWith("claude-"),
    "测试 Codex OAuth 路由时需要使用 claude- 开头的模型别名。",
  ),
});

const confidenceSchema = z.number().min(0).max(1);

export const aiSuggestionPayloadSchema = z.object({
  suggested_title: z.string().min(1).max(200),
  summary: z.string().min(1).max(800),
  content_type: z.enum(CONTENT_TYPES),
  existing_category_candidates: z
    .array(
      z.object({
        category_id: z.uuid(),
        reason: z.string().min(1).max(300),
        confidence: confidenceSchema,
      }),
    )
    .max(10)
    .describe("优先复用的已有分类候选；服务端最终最多保留 3 个分类候选"),
  new_category_candidates: z
    .array(
      z.object({
        name: z.string().min(1).max(60),
        reason: z.string().min(1).max(300),
        confidence: confidenceSchema,
      }),
    )
    .max(10)
    .describe("仅在现有分类都不合适时提出；服务端最终最多保留 1 个新分类"),
  content_suggestions: z
    .array(
      z.object({
        type: z.enum(CONTENT_SUGGESTION_TYPES),
        source_excerpt: z
          .string()
          .min(1)
          .max(1_000)
          .describe("需要局部调整的原文，必须逐字存在于原文中"),
        suggested_text: z
          .string()
          .max(2_000)
          .describe("局部替换文字；删除冗余时可以为空字符串"),
        reason: z.string().min(1).max(300),
        confidence: confidenceSchema,
      }),
    )
    .max(10)
    .default([])
    .describe("局部原文修改建议，不得返回整篇改写；服务端最终最多保留 5 条"),
  claim_candidates: z
    .array(
      z.object({
        statement: z.string().min(1).max(1_000),
        source_excerpt: z
          .string()
          .min(1)
          .max(1_000)
          .describe("支持提出该候选主张的原文，必须逐字存在"),
        falsification_criteria: z
          .string()
          .min(1)
          .max(1_000)
          .describe("哪些可观察结果会推翻或削弱该主张"),
        reason: z.string().min(1).max(300),
        confidence: confidenceSchema,
      }),
    )
    .max(10)
    .default([])
    .describe("仅提取可被外部证据支持或反驳的主张；服务端最终最多保留 3 条"),
  semantic_units: z
    .array(
      z.object({
        type: z.enum(SEMANTIC_UNIT_TYPES),
        content: z.string().min(1).max(1_000),
        source_excerpt: z.string().min(1).max(1_000),
        confidence: confidenceSchema,
      }),
    )
    .max(30),
  open_questions: z.array(z.string().min(1).max(300)).max(10),
  quality_flags: z
    .array(
      z.object({
        code: z.string().min(1).max(80),
        message: z.string().min(1).max(500),
      }),
    )
    .max(10),
});

export type AISuggestionPayload = z.infer<typeof aiSuggestionPayloadSchema>;

export const claimAIAuditPayloadSchema = z.object({
  summary: z.string().min(1).max(1_000),
  evidence_coverage: z.enum(["limited", "moderate", "broad"]),
  evidence_balance: z.enum(["insufficient", "one_sided", "mixed"]),
  findings: z
    .array(
      z.object({
        category: z.enum(CLAIM_AUDIT_FINDING_CATEGORIES),
        severity: z.enum(["low", "medium", "high"]),
        message: z.string().min(1).max(500),
        evidence_ids: z.array(z.uuid()).max(5),
      }),
    )
    .max(8),
  missing_checks: z.array(z.string().min(1).max(300)).max(5),
  recommended_assessment: z.enum([
    "supported",
    "refuted",
    "inconclusive",
    "needs_more_evidence",
  ]),
  boundary_notice: z.string().min(1).max(500),
});

export type ClaimAIAuditPayload = z.infer<typeof claimAIAuditPayloadSchema>;

export const claimAIAuditEvidenceSnapshotSchema = z
  .array(
    z.object({
      id: z.uuid(),
      stance: z.enum(["supports", "contradicts", "context"]),
      sourceUrl: z.union([z.literal(""), z.url().max(2_000)]),
      sourceTitle: z.string().min(1).max(300),
      excerpt: z.string().min(1).max(2_000),
      note: z.string().max(1_000).nullable(),
      sourceCheckId: z.uuid(),
      verificationMethod: z
        .enum(["web", "manual_attachment"])
        .default("web"),
      finalUrl: z.string().min(1).max(2_000),
      contentHash: z.string().length(64),
      sourceCheckedAt: z.iso.datetime(),
    }),
  )
  .max(100);

export type ClaimAIAuditEvidenceSnapshotItem = z.infer<
  typeof claimAIAuditEvidenceSnapshotSchema
>[number];

export const organizeCaptureSchema = z
  .object({
    captureId: z.uuid(),
    expectedCaptureVersion: z.number().int().positive(),
    provider: z.enum(["mock", "openai", "deepseek"]).optional(),
    connection: aiConnectionSchema.optional(),
  })
  .superRefine((input, context) => {
    if (
      (input.connection?.mode === "ccswitch" ||
        input.connection?.mode === "ccswitch_auto" ||
        input.connection?.mode === "ccswitch_codex_oauth") &&
      input.provider !== "openai"
    ) {
      context.addIssue({
        code: "custom",
        message: "CC-Switch 当前仅用于 OpenAI/Codex 连接。",
        path: ["connection"],
      });
    }
    if (
      input.provider === "mock" &&
      input.connection &&
      input.connection.mode !== "server"
    ) {
      context.addIssue({
        code: "custom",
        message: "本地规则不需要 API 凭据。",
        path: ["connection"],
      });
    }
  });

export const auditClaimSchema = z
  .object({
    claimId: z.uuid(),
    provider: z.enum(["mock", "openai", "deepseek"]).optional(),
    connection: aiConnectionSchema.optional(),
  })
  .superRefine((input, context) => {
    if (
      (input.connection?.mode === "ccswitch" ||
        input.connection?.mode === "ccswitch_auto" ||
        input.connection?.mode === "ccswitch_codex_oauth") &&
      input.provider !== "openai"
    ) {
      context.addIssue({
        code: "custom",
        message: "CC-Switch 当前仅用于 OpenAI/Codex 连接。",
        path: ["connection"],
      });
    }
    if (
      input.provider === "mock" &&
      input.connection &&
      input.connection.mode !== "server"
    ) {
      context.addIssue({
        code: "custom",
        message: "本地规则不需要 API 凭据。",
        path: ["connection"],
      });
    }
  });

export const decideSuggestionSchema = z.object({
  suggestionId: z.uuid(),
  decision: z.enum(["accepted", "modified", "rejected"]),
  acceptedFields: z
    .object({
      title: z.string().max(200).nullable().optional(),
      contentType: z.enum(CONTENT_TYPES).optional(),
      existingCategoryIds: z.array(z.uuid()).max(3).optional(),
      newCategoryNames: z.array(z.string().min(1).max(60)).max(1).optional(),
      contentSuggestionIndexes: z.array(z.number().int().min(0)).max(5).optional(),
      claimCandidateIndexes: z.array(z.number().int().min(0)).max(3).optional(),
    })
    .optional(),
});

export const acceptedSuggestionPayloadSchema = z.object({
  title: z.string().max(200).nullable(),
  contentType: z.enum(CONTENT_TYPES),
  existingCategoryIds: z.array(z.uuid()).max(3),
  newCategoryNames: z.array(z.string().min(1).max(60)).max(1),
  contentSuggestionIndexes: z.array(z.number().int().min(0)).max(5),
  claimCandidateIndexes: z.array(z.number().int().min(0)).max(3),
  rollback: z.object({
    beforeTitle: z.string().max(200).nullable(),
    beforeContent: z.string().min(1).max(20_000),
    beforeContentType: z.enum(CONTENT_TYPES),
    beforeAICategoryIds: z.array(z.uuid()).max(5),
    appliedCaptureVersion: z.number().int().positive(),
    appliedAICategoryIds: z.array(z.uuid()).max(5),
    createdClaimIds: z.array(z.uuid()).max(3),
  }),
  rollbackResult: z
    .object({
      rolledBackAt: z.iso.datetime(),
      resultingCaptureVersion: z.number().int().positive(),
    })
    .optional(),
});

export const rollbackSuggestionSchema = z.object({
  suggestionId: z.uuid(),
  expectedCaptureVersion: z.number().int().positive(),
});

export type AcceptedSuggestionPayload = z.infer<
  typeof acceptedSuggestionPayloadSchema
>;
