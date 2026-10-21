import { z } from "zod";

export const CLAIM_STATUSES = [
  "candidate",
  "investigating",
  "ready_for_review",
  "concluded",
  "withdrawn",
] as const;

export const CLAIM_ASSESSMENTS = [
  "supported",
  "refuted",
  "inconclusive",
] as const;

export const EVIDENCE_STANCES = [
  "supports",
  "contradicts",
  "context",
] as const;

export const claimStatusSchema = z.enum(CLAIM_STATUSES);

const optionalEvidenceSourceUrlSchema = z
  .string()
  .trim()
  .max(2_000)
  .superRefine((value, context) => {
    if (!value) return;

    let url: URL;
    try {
      url = new URL(value);
    } catch {
      context.addIssue({
        code: "custom",
        message: "请输入有效的来源 URL。",
      });
      return;
    }

    if (url.protocol !== "http:" && url.protocol !== "https:") {
      context.addIssue({
        code: "custom",
        message: "来源仅支持 HTTP(S) URL。",
      });
    }
  });

export const transitionClaimSchema = z.object({
  claimId: z.uuid(),
  expectedStatus: claimStatusSchema,
  targetStatus: claimStatusSchema,
});

export const createManualClaimSchema = z.object({
  captureId: z.uuid(),
  expectedCaptureVersion: z.number().int().positive(),
  statement: z
    .string()
    .trim()
    .min(5, "主张至少需要 5 个字符。")
    .max(1_000, "主张不能超过 1,000 个字符。"),
  sourceExcerpt: z
    .string()
    .trim()
    .min(1, "请填写能够在原文中定位的来源摘录。")
    .max(1_000, "来源摘录不能超过 1,000 个字符。"),
  falsificationCriteria: z
    .string()
    .trim()
    .min(10, "证伪条件至少需要 10 个字符。")
    .max(1_000, "证伪条件不能超过 1,000 个字符。"),
});

export const addClaimEvidenceSchema = z.object({
  claimId: z.uuid(),
  sourceUrl: optionalEvidenceSourceUrlSchema,
  sourceTitle: z.string().trim().min(1, "来源标题不能为空。").max(300),
  excerpt: z.string().trim().min(1, "证据摘录不能为空。").max(2_000),
  stance: z.enum(EVIDENCE_STANCES),
  note: z.string().trim().max(1_000).optional(),
});

export const updateClaimEvidenceSchema = addClaimEvidenceSchema
  .omit({ claimId: true })
  .extend({
    evidenceId: z.uuid(),
    expectedVersion: z.number().int().positive(),
  });

export const uploadEvidenceImageSchema = z.object({
  evidenceId: z.uuid(),
  file: z
    .file("请选择图片文件。")
    .min(1, "图片不能为空。")
    .max(10 * 1024 * 1024, "单张图片不能超过 10 MB。")
    .mime(
      ["image/jpeg", "image/png", "image/webp", "image/gif"],
      "仅支持 JPEG、PNG、WebP 或 GIF 图片。",
    ),
});

/**
 * 客户端直传（Vercel Blob）后的提交载荷。
 *
 * 这里**只校验形状**：`storagePath` 必须是服务端可识别的 `<uuid>.<ext>`，防止浏览器
 * 提交任意对象 key；字节本身的格式与哈希由服务端回读后重新判定（见
 * `commitClientUploadedEvidenceImage`），不采信客户端声明的 MIME / 大小 / 哈希。
 */
export const commitClientUploadedEvidenceImageSchema = z.object({
  evidenceId: z.uuid(),
  storagePath: z
    .string()
    .max(255)
    .regex(
      /^[0-9a-f-]+\.(?:jpg|png|webp|gif)$/,
      "图片存储路径无效。",
    ),
  originalName: z.string().max(255).optional(),
});

export const reviewClaimEvidenceSchema = z.object({
  evidenceId: z.uuid(),
  decision: z.enum(["accepted", "rejected"]),
});

export const checkClaimEvidenceSourceSchema = z.object({
  evidenceId: z.uuid(),
  manualConfirmation: z.boolean().optional(),
});

export const concludeClaimSchema = z.object({
  claimId: z.uuid(),
  assessment: z.enum(CLAIM_ASSESSMENTS),
  rationale: z.string().trim().min(10, "结论依据至少需要 10 个字符。").max(2_000),
  limitations: z.string().trim().max(2_000).optional(),
});

export type ClaimStatus = z.infer<typeof claimStatusSchema>;
