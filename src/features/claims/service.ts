import { and, count, desc, eq } from "drizzle-orm";
import path from "node:path";

import type { ClaimStatus } from "./schema";
import {
  assessmentHasRequiredStance,
  canTransitionClaim,
  hasConfirmedEvidenceSource,
  hasRequiredEvidenceForReview,
} from "./state";
import {
  captures,
  claimEvidence,
  claimEvidenceRevisions,
  claimReviewEvidence,
  claimReviews,
  claims,
  evidenceAttachments,
  evidenceSourceChecks,
  type EvidenceAttachmentVerificationSnapshot,
} from "@/server/db/schema";
import { db } from "@/server/db/client";
import { AppError } from "@/shared/errors/app-error";
import { sha256, stableStringify } from "@/shared/hash";
import { inspectEvidenceSource } from "./source-inspector";
import {
  readEvidenceImage,
  removeEvidenceImage,
  writeEvidenceImage,
} from "./image-storage";
import {
  MAX_EVIDENCE_IMAGES,
  prepareEvidenceImage,
  verifyStoredEvidenceImageBytes,
} from "./image-validation";
import {
  requireCaptureAccess,
  requireClaimAccess,
  requireEvidenceAccess,
} from "@/features/auth/access";

const MANUAL_ATTACHMENT_CONTENT_TYPE =
  "application/vnd.knowtrace.evidence-attachments+json";
const MANUAL_ATTACHMENT_VERIFICATION_NOTE =
  "本地使用者确认已查看本次冻结的全部图片附件，并确认保存的证据摘录与附件内容一致。";

function assertEvidenceImageState(claimStatus: string, reviewStatus: string) {
  if (claimStatus !== "investigating" || reviewStatus !== "unreviewed") {
    throw new AppError(
      "CLAIM_EVIDENCE_IMAGE_STATE_INVALID",
      "只有调查中且尚未审核的证据可以上传图片。",
    );
  }
}

/**
 * 直传前的**预检**：让浏览器在把字节传到对象存储之前就拿到明确拒绝，
 * 而不是传完才在提交时失败（那会留下一个孤儿 blob）。
 *
 * 真正的权威判据仍在 `storeEvidenceImage` 的事务里（带行锁、与并发一致）；
 * 本函数只是把同一套条件提前跑一遍，两处共用 `assertEvidenceImageState` 与数量上限常量。
 */
export async function assertEvidenceImageUploadAllowed(evidenceId: string): Promise<void> {
  const [row] = await db
    .select({
      id: claimEvidence.id,
      claimStatus: claims.status,
      reviewStatus: claimEvidence.reviewStatus,
    })
    .from(claimEvidence)
    .innerJoin(claims, eq(claimEvidence.claimId, claims.id))
    .where(eq(claimEvidence.id, evidenceId))
    .limit(1);
  if (!row) throw new AppError("CLAIM_EVIDENCE_NOT_FOUND", "证据不存在。");
  assertEvidenceImageState(row.claimStatus, row.reviewStatus);
  const [attachmentCount] = await db
    .select({ count: count() })
    .from(evidenceAttachments)
    .where(eq(evidenceAttachments.evidenceId, row.id));
  if (Number(attachmentCount?.count ?? 0) >= MAX_EVIDENCE_IMAGES) {
    throw new AppError(
      "CLAIM_EVIDENCE_IMAGE_LIMIT",
      `每条证据最多上传 ${MAX_EVIDENCE_IMAGES} 张图片。`,
    );
  }
}

export async function createManualClaim(input: {
  captureId: string;
  expectedCaptureVersion: number;
  statement: string;
  sourceExcerpt: string;
  falsificationCriteria: string;
}) {
  await requireCaptureAccess(input.captureId);
  return db.transaction(async (transaction) => {
    const [capture] = await transaction
      .select({
        id: captures.id,
        version: captures.version,
        content: captures.content,
      })
      .from(captures)
      .where(eq(captures.id, input.captureId))
      .for("update")
      .limit(1);
    if (!capture) throw new AppError("CAPTURE_NOT_FOUND", "记录不存在。");
    if (capture.version !== input.expectedCaptureVersion) {
      throw new AppError(
        "CAPTURE_VERSION_CONFLICT",
        "原始记录已经更新，请刷新后重新选择来源摘录。",
        { currentVersion: capture.version },
      );
    }

    const statement = input.statement.trim();
    const sourceExcerpt = input.sourceExcerpt.trim();
    if (!capture.content.includes(sourceExcerpt)) {
      throw new AppError(
        "CLAIM_SOURCE_EXCERPT_NOT_FOUND",
        "来源摘录必须能够在当前版本原文中完整定位。",
      );
    }
    const statementHash = sha256(
      stableStringify({
        captureId: capture.id,
        sourceCaptureVersion: capture.version,
        statement: statement.toLocaleLowerCase("zh-CN"),
      }),
    );
    const [created] = await transaction
      .insert(claims)
      .values({
        captureId: capture.id,
        sourceSuggestionId: null,
        sourceCaptureVersion: capture.version,
        statement,
        statementHash,
        sourceExcerpt,
        falsificationCriteria: input.falsificationCriteria.trim(),
      })
      .onConflictDoNothing({ target: claims.statementHash })
      .returning({ id: claims.id, captureId: claims.captureId });
    if (!created) {
      throw new AppError(
        "CLAIM_ALREADY_EXISTS",
        "当前记录版本中已经存在相同主张。",
      );
    }
    return created;
  });
}

function buildAttachmentSnapshot(
  rows: EvidenceAttachmentVerificationSnapshot,
): EvidenceAttachmentVerificationSnapshot {
  return [...rows].sort((left, right) => left.id.localeCompare(right.id));
}

export async function transitionClaim(input: {
  claimId: string;
  expectedStatus: ClaimStatus;
  targetStatus: ClaimStatus;
}) {
  await requireClaimAccess(input.claimId);
  if (!canTransitionClaim(input.expectedStatus, input.targetStatus)) {
    throw new AppError(
      "CLAIM_TRANSITION_INVALID",
      "当前主张状态不允许执行这个操作。",
    );
  }

  const [claim] = await db
    .select({ id: claims.id, captureId: claims.captureId, status: claims.status })
    .from(claims)
    .where(eq(claims.id, input.claimId))
    .limit(1);
  if (!claim) throw new AppError("CLAIM_NOT_FOUND", "候选主张不存在。");
  if (claim.status !== input.expectedStatus) {
    throw new AppError(
      "CLAIM_STATUS_CONFLICT",
      "主张状态已经变化，请刷新后重试。",
    );
  }

  if (input.targetStatus === "ready_for_review") {
    const [summary] = await db
      .select({ count: count() })
      .from(claimEvidence)
      .where(
        and(
          eq(claimEvidence.claimId, claim.id),
          eq(claimEvidence.reviewStatus, "accepted"),
          eq(claimEvidence.sourceCheckStatus, "passed"),
          eq(claimEvidence.sourceExcerptMatch, true),
        ),
      );
    if (!hasRequiredEvidenceForReview(Number(summary?.count ?? 0))) {
      throw new AppError(
        "CLAIM_ACCEPTED_EVIDENCE_REQUIRED",
        "至少需要一条已采纳证据，才能提交待审核。",
      );
    }
  }

  const [updated] = await db
    .update(claims)
    .set({ status: input.targetStatus, updatedAt: new Date() })
    .where(
      and(
        eq(claims.id, claim.id),
        eq(claims.status, input.expectedStatus),
      ),
    )
    .returning({ id: claims.id, captureId: claims.captureId, status: claims.status });
  if (!updated) {
    throw new AppError(
      "CLAIM_STATUS_CONFLICT",
      "主张状态已经变化，请刷新后重试。",
    );
  }
  return updated;
}

export async function addClaimEvidence(input: {
  claimId: string;
  sourceUrl: string;
  sourceTitle: string;
  excerpt: string;
  stance: "supports" | "contradicts" | "context";
  note?: string;
}) {
  await requireClaimAccess(input.claimId);
  const [claim] = await db
    .select({ id: claims.id, captureId: claims.captureId, status: claims.status })
    .from(claims)
    .where(eq(claims.id, input.claimId))
    .limit(1);
  if (!claim) throw new AppError("CLAIM_NOT_FOUND", "候选主张不存在。");
  if (claim.status !== "investigating") {
    throw new AppError(
      "CLAIM_EVIDENCE_STATE_INVALID",
      "只有调查中的主张可以添加证据。",
    );
  }

  const [evidence] = await db
    .insert(claimEvidence)
    .values({
      claimId: claim.id,
      sourceUrl: input.sourceUrl,
      sourceTitle: input.sourceTitle,
      excerpt: input.excerpt,
      stance: input.stance,
      note: input.note || null,
    })
    .returning({ id: claimEvidence.id });
  return { ...evidence, captureId: claim.captureId };
}

export async function updateClaimEvidence(input: {
  evidenceId: string;
  expectedVersion: number;
  sourceUrl: string;
  sourceTitle: string;
  excerpt: string;
  stance: "supports" | "contradicts" | "context";
  note?: string;
}) {
  await requireEvidenceAccess(input.evidenceId);
  return db.transaction(async (transaction) => {
    const [current] = await transaction
      .select({
        id: claimEvidence.id,
        claimId: claimEvidence.claimId,
        captureId: claims.captureId,
        claimStatus: claims.status,
        reviewStatus: claimEvidence.reviewStatus,
        version: claimEvidence.version,
        sourceUrl: claimEvidence.sourceUrl,
        sourceTitle: claimEvidence.sourceTitle,
        excerpt: claimEvidence.excerpt,
        stance: claimEvidence.stance,
        note: claimEvidence.note,
        latestSourceCheckId: claimEvidence.latestSourceCheckId,
      })
      .from(claimEvidence)
      .innerJoin(claims, eq(claimEvidence.claimId, claims.id))
      .where(eq(claimEvidence.id, input.evidenceId))
      .limit(1)
      .for("update");
    if (!current) throw new AppError("CLAIM_EVIDENCE_NOT_FOUND", "证据不存在。");
    if (current.claimStatus !== "investigating" || current.reviewStatus !== "unreviewed") {
      throw new AppError(
        "CLAIM_EVIDENCE_EDIT_STATE_INVALID",
        "只有调查中且尚未审核的证据可以编辑。",
      );
    }
    if (current.version !== input.expectedVersion) {
      throw new AppError(
        "CLAIM_EVIDENCE_VERSION_CONFLICT",
        "证据已被其他操作修改，请刷新后重试。",
      );
    }

    await transaction.insert(claimEvidenceRevisions).values({
      evidenceId: current.id,
      version: current.version,
      sourceUrl: current.sourceUrl,
      sourceTitle: current.sourceTitle,
      excerpt: current.excerpt,
      stance: current.stance,
      note: current.note,
      latestSourceCheckId: current.latestSourceCheckId,
    });

    const [updated] = await transaction
      .update(claimEvidence)
      .set({
        sourceUrl: input.sourceUrl,
        sourceTitle: input.sourceTitle,
        excerpt: input.excerpt,
        stance: input.stance,
        note: input.note || null,
        version: current.version + 1,
        sourceCheckStatus: "unchecked",
        sourceExcerptMatch: null,
        sourceCheckedAt: null,
        latestSourceCheckId: null,
        updatedAt: new Date(),
      })
      .where(
        and(
          eq(claimEvidence.id, current.id),
          eq(claimEvidence.version, input.expectedVersion),
          eq(claimEvidence.reviewStatus, "unreviewed"),
        ),
      )
      .returning({ id: claimEvidence.id, version: claimEvidence.version });
    if (!updated) {
      throw new AppError(
        "CLAIM_EVIDENCE_VERSION_CONFLICT",
        "证据已被其他操作修改，请刷新后重试。",
      );
    }
    await transaction
      .update(claims)
      .set({ updatedAt: new Date() })
      .where(eq(claims.id, current.claimId));
    return { ...updated, captureId: current.captureId };
  });
}

export async function uploadEvidenceImage(input: {
  evidenceId: string;
  file: File;
}) {
  await requireEvidenceAccess(input.evidenceId);
  const prepared = await prepareEvidenceImage(input.file);
  return storeEvidenceImage({
    evidenceId: input.evidenceId,
    storagePath: prepared.storagePath,
    originalName: prepared.originalName,
    mimeType: prepared.mimeType,
    byteSize: prepared.byteSize,
    sha256: prepared.sha256,
    persist: () =>
      writeEvidenceImage(prepared.storagePath, prepared.bytes, {
        contentType: prepared.mimeType,
      }),
  });
}

/**
 * 客户端直传（Vercel Blob）后的提交。
 *
 * 字节已经在浏览器 → 对象存储这一跳落盘，本函数**不信浏览器声明的任何元数据**：
 * 从存储把字节读回来，重做魔数/大小校验，并由服务端计算 SHA-256。
 * 校验或落库失败时删除刚上传的 blob，避免留下孤儿。
 */
export async function commitClientUploadedEvidenceImage(input: {
  evidenceId: string;
  storagePath: string;
  originalName?: string;
}) {
  await requireEvidenceAccess(input.evidenceId);
  const storagePath = input.storagePath;
  const bytes = await readEvidenceImage(storagePath).catch(() => null);
  if (!bytes) {
    throw new AppError("EVIDENCE_IMAGE_UPLOAD_NOT_FOUND", "未找到刚上传的图片，请重新上传。");
  }
  const verified = verifyStoredEvidenceImageBytes(bytes, storagePath);
  const originalName =
    path.basename(input.originalName ?? "").replace(/[ -]/g, "").slice(0, 255) ||
    `image${path.extname(storagePath).toLowerCase()}`;
  return storeEvidenceImage({
    evidenceId: input.evidenceId,
    storagePath,
    originalName,
    mimeType: verified.mimeType,
    byteSize: verified.byteSize,
    sha256: verified.sha256,
    persist: async () => undefined,
  });
}

type EvidenceImageMetadata = {
  evidenceId: string;
  storagePath: string;
  originalName: string;
  mimeType: string;
  byteSize: number;
  sha256: string;
};

/**
 * 两种上传入口（FormData / 客户端直传）共用的落库事务：状态与数量门槛只在这里判一次，
 * 避免两条路径各写一套判据、日后只改了一边。
 */
async function storeEvidenceImage(input: EvidenceImageMetadata & { persist: () => Promise<void> }) {
  let stored = false;
  try {
    return await db.transaction(async (transaction) => {
      const [current] = await transaction
        .select({
          id: claimEvidence.id,
          claimId: claimEvidence.claimId,
          captureId: claims.captureId,
          claimStatus: claims.status,
          reviewStatus: claimEvidence.reviewStatus,
          latestSourceCheckId: claimEvidence.latestSourceCheckId,
        })
        .from(claimEvidence)
        .innerJoin(claims, eq(claimEvidence.claimId, claims.id))
        .where(eq(claimEvidence.id, input.evidenceId))
        .limit(1)
        .for("update");
      if (!current) throw new AppError("CLAIM_EVIDENCE_NOT_FOUND", "证据不存在。");
      assertEvidenceImageState(current.claimStatus, current.reviewStatus);
      const [attachmentCount] = await transaction
        .select({ count: count() })
        .from(evidenceAttachments)
        .where(eq(evidenceAttachments.evidenceId, current.id));
      if (Number(attachmentCount?.count ?? 0) >= MAX_EVIDENCE_IMAGES) {
        throw new AppError(
          "CLAIM_EVIDENCE_IMAGE_LIMIT",
          `每条证据最多上传 ${MAX_EVIDENCE_IMAGES} 张图片。`,
        );
      }

      await input.persist();
      stored = true;
      const [attachment] = await transaction
        .insert(evidenceAttachments)
        .values({
          evidenceId: current.id,
          originalName: input.originalName,
          storagePath: input.storagePath,
          mimeType: input.mimeType,
          byteSize: input.byteSize,
          sha256: input.sha256,
        })
        .returning({ id: evidenceAttachments.id });
      if (current.latestSourceCheckId) {
        const [latestCheck] = await transaction
          .select({ verificationMethod: evidenceSourceChecks.verificationMethod })
          .from(evidenceSourceChecks)
          .where(eq(evidenceSourceChecks.id, current.latestSourceCheckId))
          .limit(1);
        if (latestCheck?.verificationMethod === "manual_attachment") {
          await transaction
            .update(claimEvidence)
            .set({
              sourceCheckStatus: "unchecked",
              sourceExcerptMatch: null,
              sourceCheckedAt: null,
              latestSourceCheckId: null,
              updatedAt: new Date(),
            })
            .where(eq(claimEvidence.id, current.id));
        }
      }
      await transaction
        .update(claims)
        .set({ updatedAt: new Date() })
        .where(eq(claims.id, current.claimId));
      return { ...attachment, captureId: current.captureId };
    });
  } catch (error) {
    // 直传通道下字节在上一步就已经在存储里，落库失败必须把它删掉，否则留下孤儿 blob。
    if (stored) await removeEvidenceImage(input.storagePath).catch(() => undefined);
    throw error;
  }
}

export async function checkClaimEvidenceSource(input: {
  evidenceId: string;
  manualConfirmation?: boolean;
}) {
  await requireEvidenceAccess(input.evidenceId);
  const [row] = await db
    .select({
      evidenceId: claimEvidence.id,
      sourceUrl: claimEvidence.sourceUrl,
      excerpt: claimEvidence.excerpt,
      version: claimEvidence.version,
      reviewStatus: claimEvidence.reviewStatus,
      claimStatus: claims.status,
      captureId: claims.captureId,
    })
    .from(claimEvidence)
    .innerJoin(claims, eq(claimEvidence.claimId, claims.id))
    .where(eq(claimEvidence.id, input.evidenceId))
    .limit(1);
  if (!row) throw new AppError("CLAIM_EVIDENCE_NOT_FOUND", "证据不存在。");
  if (row.claimStatus !== "investigating" || row.reviewStatus !== "unreviewed") {
    throw new AppError(
      "CLAIM_EVIDENCE_SOURCE_CHECK_STATE_INVALID",
      "只有调查中且尚未审核的证据可以检查来源。",
    );
  }
  if (!row.sourceUrl.trim()) {
    if (input.manualConfirmation !== true) {
      throw new AppError(
        "CLAIM_EVIDENCE_MANUAL_CONFIRMATION_REQUIRED",
        "请先查看图片附件，并确认摘录与附件内容一致。",
      );
    }

    return db.transaction(async (transaction) => {
      const [current] = await transaction
        .select({
          evidenceId: claimEvidence.id,
          sourceUrl: claimEvidence.sourceUrl,
          excerpt: claimEvidence.excerpt,
          version: claimEvidence.version,
          reviewStatus: claimEvidence.reviewStatus,
          claimStatus: claims.status,
        })
        .from(claimEvidence)
        .innerJoin(claims, eq(claimEvidence.claimId, claims.id))
        .where(eq(claimEvidence.id, row.evidenceId))
        .limit(1)
        .for("update");
      if (
        !current ||
        current.claimStatus !== "investigating" ||
        current.reviewStatus !== "unreviewed" ||
        current.version !== row.version ||
        current.sourceUrl.trim()
      ) {
        throw new AppError(
          "CLAIM_EVIDENCE_SOURCE_CHECK_STATE_INVALID",
          "证据状态或内容已经变化，本次附件核验未写入。",
        );
      }

      const attachmentSnapshot = buildAttachmentSnapshot(
        await transaction
          .select({
            id: evidenceAttachments.id,
            originalName: evidenceAttachments.originalName,
            mimeType: evidenceAttachments.mimeType,
            byteSize: evidenceAttachments.byteSize,
            sha256: evidenceAttachments.sha256,
          })
          .from(evidenceAttachments)
          .where(eq(evidenceAttachments.evidenceId, current.evidenceId)),
      );
      if (!attachmentSnapshot.length) {
        throw new AppError(
          "CLAIM_EVIDENCE_ATTACHMENT_REQUIRED",
          "无来源链接时，至少需要上传一张图片才能进行人工核验。",
        );
      }

      const checkedAt = new Date();
      const contentHash = sha256(
        stableStringify({
          evidenceId: current.evidenceId,
          evidenceVersion: current.version,
          excerpt: current.excerpt,
          attachments: attachmentSnapshot,
        }),
      );
      const [attempt] = await transaction
        .insert(evidenceSourceChecks)
        .values({
          evidenceId: current.evidenceId,
          verificationMethod: "manual_attachment",
          requestedUrl: "",
          finalUrl: `/api/evidence-images/${attachmentSnapshot[0]!.id}`,
          status: "passed",
          httpStatus: null,
          contentType: MANUAL_ATTACHMENT_CONTENT_TYPE,
          contentHash,
          fetchedTitle: null,
          excerptMatch: true,
          responseBytes: attachmentSnapshot.reduce(
            (total, attachment) => total + attachment.byteSize,
            0,
          ),
          errorCode: null,
          attachmentSnapshot,
          verificationNote: MANUAL_ATTACHMENT_VERIFICATION_NOTE,
          checkedAt,
        })
        .returning({ id: evidenceSourceChecks.id });

      const [updated] = await transaction
        .update(claimEvidence)
        .set({
          sourceCheckStatus: "passed",
          sourceExcerptMatch: true,
          sourceCheckedAt: checkedAt,
          latestSourceCheckId: attempt.id,
        })
        .where(
          and(
            eq(claimEvidence.id, current.evidenceId),
            eq(claimEvidence.reviewStatus, "unreviewed"),
            eq(claimEvidence.version, current.version),
          ),
        )
        .returning({ id: claimEvidence.id });
      if (!updated) {
        throw new AppError(
          "CLAIM_EVIDENCE_SOURCE_CHECK_STATE_INVALID",
          "证据状态已经变化，本次附件核验未写入。",
        );
      }

      return {
        id: updated.id,
        captureId: row.captureId,
        status: "passed" as const,
        excerptMatch: true,
        errorCode: null,
        verificationMethod: "manual_attachment" as const,
      };
    });
  }

  const inspection = await inspectEvidenceSource({
    sourceUrl: row.sourceUrl,
    excerpt: row.excerpt,
  });
  const checkedAt = new Date();

  return db.transaction(async (transaction) => {
    const [current] = await transaction
      .select({
        reviewStatus: claimEvidence.reviewStatus,
        claimStatus: claims.status,
        version: claimEvidence.version,
      })
      .from(claimEvidence)
      .innerJoin(claims, eq(claimEvidence.claimId, claims.id))
      .where(eq(claimEvidence.id, row.evidenceId))
      .limit(1);
    if (
      !current ||
      current.claimStatus !== "investigating" ||
      current.reviewStatus !== "unreviewed" ||
      current.version !== row.version
    ) {
      throw new AppError(
        "CLAIM_EVIDENCE_SOURCE_CHECK_STATE_INVALID",
        "证据状态或内容已经变化，本次来源检查未写入。",
      );
    }

    const [attempt] = await transaction
      .insert(evidenceSourceChecks)
      .values({
        evidenceId: row.evidenceId,
        verificationMethod: "web",
        requestedUrl: inspection.requestedUrl,
        finalUrl: inspection.finalUrl,
        status: inspection.status,
        httpStatus: inspection.httpStatus,
        contentType: inspection.contentType,
        contentHash: inspection.contentHash,
        fetchedTitle: inspection.fetchedTitle,
        excerptMatch: inspection.excerptMatch,
        responseBytes: inspection.responseBytes,
        errorCode: inspection.errorCode,
        checkedAt,
      })
      .returning({ id: evidenceSourceChecks.id });

    const [updated] = await transaction
      .update(claimEvidence)
      .set({
        sourceCheckStatus: inspection.status,
        sourceExcerptMatch: inspection.excerptMatch,
        sourceCheckedAt: checkedAt,
        latestSourceCheckId: attempt.id,
      })
      .where(
        and(
          eq(claimEvidence.id, row.evidenceId),
          eq(claimEvidence.reviewStatus, "unreviewed"),
          eq(claimEvidence.version, row.version),
        ),
      )
      .returning({ id: claimEvidence.id });
    if (!updated) {
      throw new AppError(
        "CLAIM_EVIDENCE_SOURCE_CHECK_STATE_INVALID",
        "证据状态已经变化，本次来源检查未写入。",
      );
    }
    return {
      id: updated.id,
      captureId: row.captureId,
      status: inspection.status,
      excerptMatch: inspection.excerptMatch,
      errorCode: inspection.errorCode,
      verificationMethod: "web" as const,
    };
  });
}

export async function reviewClaimEvidence(input: {
  evidenceId: string;
  decision: "accepted" | "rejected";
}) {
  await requireEvidenceAccess(input.evidenceId);
  const [row] = await db
    .select({
      evidenceId: claimEvidence.id,
      reviewStatus: claimEvidence.reviewStatus,
      sourceCheckStatus: claimEvidence.sourceCheckStatus,
      sourceExcerptMatch: claimEvidence.sourceExcerptMatch,
      latestSourceCheckId: claimEvidence.latestSourceCheckId,
      claimStatus: claims.status,
      captureId: claims.captureId,
    })
    .from(claimEvidence)
    .innerJoin(claims, eq(claimEvidence.claimId, claims.id))
    .where(eq(claimEvidence.id, input.evidenceId))
    .limit(1);
  if (!row) throw new AppError("CLAIM_EVIDENCE_NOT_FOUND", "证据不存在。");
  if (row.claimStatus !== "investigating") {
    throw new AppError(
      "CLAIM_EVIDENCE_STATE_INVALID",
      "只有调查中的主张可以审核证据。",
    );
  }
  if (row.reviewStatus !== "unreviewed") {
    throw new AppError(
      "CLAIM_EVIDENCE_ALREADY_REVIEWED",
      "这条证据已经完成审核。",
    );
  }
  if (
    input.decision === "accepted" &&
    !hasConfirmedEvidenceSource({
      status: row.sourceCheckStatus,
      excerptMatch: row.sourceExcerptMatch,
      latestCheckId: row.latestSourceCheckId,
    })
  ) {
    throw new AppError(
      "CLAIM_EVIDENCE_SOURCE_NOT_CONFIRMED",
      "采纳前必须成功检查来源，并确认摘录存在于来源内容中。",
    );
  }

  const [updated] = await db
    .update(claimEvidence)
    .set({ reviewStatus: input.decision, reviewedAt: new Date() })
    .where(
      and(
        eq(claimEvidence.id, input.evidenceId),
        eq(claimEvidence.reviewStatus, "unreviewed"),
        ...(input.decision === "accepted"
          ? [
              eq(claimEvidence.sourceCheckStatus, "passed"),
              eq(claimEvidence.sourceExcerptMatch, true),
              eq(claimEvidence.latestSourceCheckId, row.latestSourceCheckId!),
            ]
          : []),
      ),
    )
    .returning({ id: claimEvidence.id });
  if (!updated) {
    throw new AppError(
      "CLAIM_EVIDENCE_ALREADY_REVIEWED",
      "这条证据已经完成审核。",
    );
  }
  return { ...updated, captureId: row.captureId };
}

export async function concludeClaim(input: {
  claimId: string;
  assessment: "supported" | "refuted" | "inconclusive";
  rationale: string;
  limitations?: string;
  reviewer: { id: string; name: string };
}) {
  await requireClaimAccess(input.claimId);
  return db.transaction(async (transaction) => {
    const [claim] = await transaction
      .update(claims)
      .set({ status: "concluded", updatedAt: new Date() })
      .where(
        and(
          eq(claims.id, input.claimId),
          eq(claims.status, "ready_for_review"),
        ),
      )
      .returning({ id: claims.id, captureId: claims.captureId });
    if (!claim) {
      throw new AppError(
        "CLAIM_STATUS_CONFLICT",
        "只有待审核的主张可以形成结论，请刷新后重试。",
      );
    }

    const acceptedEvidence = await transaction
      .select({
        evidenceId: claimEvidence.id,
        sourceCheckId: evidenceSourceChecks.id,
        stance: claimEvidence.stance,
        sourceUrl: claimEvidence.sourceUrl,
        sourceTitle: claimEvidence.sourceTitle,
        excerpt: claimEvidence.excerpt,
        finalUrl: evidenceSourceChecks.finalUrl,
        sourceContentHash: evidenceSourceChecks.contentHash,
        sourceCheckedAt: evidenceSourceChecks.checkedAt,
      })
      .from(claimEvidence)
      .innerJoin(
        evidenceSourceChecks,
        eq(claimEvidence.latestSourceCheckId, evidenceSourceChecks.id),
      )
      .where(
        and(
          eq(claimEvidence.claimId, claim.id),
          eq(claimEvidence.reviewStatus, "accepted"),
          eq(claimEvidence.sourceCheckStatus, "passed"),
          eq(claimEvidence.sourceExcerptMatch, true),
          eq(evidenceSourceChecks.status, "passed"),
          eq(evidenceSourceChecks.excerptMatch, true),
        ),
      );
    if (!acceptedEvidence.length) {
      throw new AppError(
        "CLAIM_ACCEPTED_EVIDENCE_REQUIRED",
        "形成结论前至少需要一条来源已确认的采纳证据。",
      );
    }
    if (
      input.assessment === "supported" &&
      !assessmentHasRequiredStance(
        input.assessment,
        acceptedEvidence.map((evidence) => evidence.stance),
      )
    ) {
      throw new AppError(
        "CLAIM_SUPPORTING_EVIDENCE_REQUIRED",
        "“得到支持”的结论至少需要一条已采纳的支持证据。",
      );
    }
    if (
      input.assessment === "refuted" &&
      !assessmentHasRequiredStance(
        input.assessment,
        acceptedEvidence.map((evidence) => evidence.stance),
      )
    ) {
      throw new AppError(
        "CLAIM_CONTRADICTING_EVIDENCE_REQUIRED",
        "“已被反驳”的结论至少需要一条已采纳的反驳证据。",
      );
    }
    if (
      acceptedEvidence.some(
        (evidence) => !evidence.finalUrl || !evidence.sourceContentHash,
      )
    ) {
      throw new AppError(
        "CLAIM_EVIDENCE_SNAPSHOT_INVALID",
        "证据来源快照不完整，无法形成结论。",
      );
    }

    const [previousReview] = await transaction
      .select({ reviewNumber: claimReviews.reviewNumber })
      .from(claimReviews)
      .where(eq(claimReviews.claimId, claim.id))
      .orderBy(desc(claimReviews.reviewNumber))
      .limit(1);
    const [review] = await transaction
      .insert(claimReviews)
      .values({
        claimId: claim.id,
        reviewNumber: (previousReview?.reviewNumber ?? 0) + 1,
        assessment: input.assessment,
        rationale: input.rationale.trim(),
        limitations: input.limitations?.trim() || null,
        reviewerId: input.reviewer.id,
        reviewerName: input.reviewer.name,
      })
      .returning({
        id: claimReviews.id,
        reviewNumber: claimReviews.reviewNumber,
        assessment: claimReviews.assessment,
      });
    await transaction.insert(claimReviewEvidence).values(
      acceptedEvidence.map((evidence) => ({
        reviewId: review.id,
        evidenceId: evidence.evidenceId,
        sourceCheckId: evidence.sourceCheckId,
        stance: evidence.stance,
        sourceUrl: evidence.sourceUrl,
        sourceTitle: evidence.sourceTitle,
        excerpt: evidence.excerpt,
        finalUrl: evidence.finalUrl!,
        sourceContentHash: evidence.sourceContentHash!,
        sourceCheckedAt: evidence.sourceCheckedAt,
      })),
    );
    return { ...review, captureId: claim.captureId };
  });
}
