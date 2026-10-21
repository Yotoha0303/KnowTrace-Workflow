"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod";

import {
  auditClaimSchema,
  detectCCSwitchSchema,
  decideSuggestionSchema,
  organizeCaptureSchema,
  rollbackSuggestionSchema,
  testCCSwitchCurrentProviderSchema,
  testCCSwitchCodexOAuthSchema,
} from "@/features/ai-processing/schema";
import {
  detectCCSwitch,
  testCCSwitchCurrentProvider,
  testCCSwitchCodexOAuth,
} from "@/features/ai-processing/connection-check";
import {
  auditClaim,
  decideSuggestion,
  organizeCapture,
  rollbackSuggestion,
} from "@/features/ai-processing/service";
import {
  captureIdSchema,
  createCaptureSchema,
  updateCaptureSchema,
} from "@/features/capture/schema";
import {
  createCapture,
  deleteCapture,
  setCaptureCategories,
  setCaptureStatus,
  updateCapture,
} from "@/features/capture/service";
import {
  createCategorySchema,
  deleteCategorySchema,
  renameCategorySchema,
  setCaptureCategoriesSchema,
} from "@/features/classification/schema";
import {
  createCategory,
  deleteCategory,
  renameCategory,
  setCategoryStatus,
} from "@/features/classification/service";
import {
  addClaimEvidenceSchema,
  checkClaimEvidenceSourceSchema,
  commitClientUploadedEvidenceImageSchema,
  concludeClaimSchema,
  createManualClaimSchema,
  reviewClaimEvidenceSchema,
  transitionClaimSchema,
  updateClaimEvidenceSchema,
  uploadEvidenceImageSchema,
} from "@/features/claims/schema";
import {
  addClaimEvidence,
  checkClaimEvidenceSource,
  commitClientUploadedEvidenceImage,
  concludeClaim,
  createManualClaim,
  reviewClaimEvidence,
  transitionClaim,
  updateClaimEvidence,
  uploadEvidenceImage,
} from "@/features/claims/service";
import { toPublicError } from "@/shared/errors/app-error";
import type { ActionResult } from "@/shared/result";
import { isAuthEnabled } from "@/features/auth/go-user-system";
import { requireAuthenticatedUser } from "@/features/auth/session";
import { currentActionActor } from "@/features/auth/actor";
import {
  decideTopicSynthesisSchema,
  generateTopicSynthesisSchema,
} from "@/features/topic-synthesis/schema";
import {
  decideTopicSynthesis,
  generateTopicSynthesis,
} from "@/features/topic-synthesis/service";
import {
  assessSourceAuthoritySchema,
  independentReviewSchema,
  publishKnowledgeSchema,
} from "@/features/reliability/schema";
import {
  assessSourceAuthority,
  publishReliableKnowledge,
  submitIndependentReview,
} from "@/features/reliability/service";

function fieldErrors(error: z.ZodError): Record<string, string[]> {
  const output: Record<string, string[]> = {};
  for (const issue of error.issues) {
    const key = String(issue.path[0] ?? "form");
    output[key] = [...(output[key] ?? []), issue.message];
  }
  return output;
}

async function runAction<TInput, TOutput>(
  schema: z.ZodType<TInput>,
  raw: unknown,
  operation: (input: TInput) => Promise<TOutput>,
): Promise<ActionResult<TOutput>> {
  const requestId = crypto.randomUUID();
  if (isAuthEnabled() && !(await requireAuthenticatedUser())) {
    return {
      ok: false,
      error: {
        code: "AUTH_REQUIRED",
        message: "登录会话已失效，请重新登录。",
        requestId,
      },
    };
  }
  const parsed = schema.safeParse(raw);
  if (!parsed.success) {
    return {
      ok: false,
      error: {
        code: "VALIDATION_ERROR",
        message: "请检查输入内容。",
        requestId,
        fieldErrors: fieldErrors(parsed.error),
      },
    };
  }

  try {
    return { ok: true, data: await operation(parsed.data) };
  } catch (error) {
    const publicError = toPublicError(error);
    return { ok: false, error: { ...publicError, requestId } };
  }
}

export async function createCaptureAction(raw: unknown) {
  const result = await runAction(createCaptureSchema, raw, async (input) => {
    const row = await createCapture(input);
    return { id: row.id, version: row.version };
  });
  return result;
}

export async function updateCaptureAction(raw: unknown) {
  const result = await runAction(updateCaptureSchema, raw, async (input) => {
    const row = await updateCapture(input);
    return { id: row.id, version: row.version, changed: row.changed };
  });
  if (result.ok) {
    revalidatePath("/");
    revalidatePath(`/captures/${result.data.id}`);
  }
  return result;
}

const captureStatusSchema = captureIdSchema.extend({
  status: z.enum(["active", "archived"]),
});

export async function setCaptureStatusAction(raw: unknown) {
  const result = await runAction(captureStatusSchema, raw, async ({ id, status }) => {
    const row = await setCaptureStatus(id, status);
    return { id: row.id, status: row.status };
  });
  if (result.ok) {
    revalidatePath("/");
    revalidatePath("/archived");
    revalidatePath(`/captures/${result.data.id}`);
  }
  return result;
}

export async function deleteCaptureAction(raw: unknown) {
  const result = await runAction(captureIdSchema, raw, async ({ id }) => {
    await deleteCapture(id);
    return { id };
  });
  if (result.ok) {
    revalidatePath("/");
    revalidatePath("/archived");
    revalidatePath("/claims");
    revalidatePath("/search");
    revalidatePath("/subjects");
  }
  return result;
}

export async function setCaptureCategoriesAction(raw: unknown) {
  const result = await runAction(setCaptureCategoriesSchema, raw, async (input) => {
    const update = await setCaptureCategories(input.captureId, input.categoryIds);
    return { id: input.captureId, changed: update.changed };
  });
  if (result.ok) {
    revalidatePath("/");
    revalidatePath(`/captures/${result.data.id}`);
  }
  return result;
}

export async function createCategoryAction(raw: unknown) {
  const result = await runAction(createCategorySchema, raw, async (input) => {
    const row = await createCategory(input);
    return { id: row.id, name: row.name };
  });
  if (result.ok) revalidatePath("/", "layout");
  return result;
}

export async function renameCategoryAction(raw: unknown) {
  const result = await runAction(renameCategorySchema, raw, async ({ id, name }) => {
    const row = await renameCategory(id, name);
    return { id: row.id, name: row.name };
  });
  if (result.ok) revalidatePath("/", "layout");
  return result;
}

export async function deleteCategoryAction(raw: unknown) {
  const result = await runAction(deleteCategorySchema, raw, async ({ id }) => {
    const row = await deleteCategory(id);
    return { id: row.id, name: row.name };
  });
  if (result.ok) {
    revalidatePath("/", "layout");
    revalidatePath("/categories");
  }
  return result;
}

const categoryStatusSchema = z.object({
  id: z.uuid(),
  status: z.enum(["active", "archived"]),
});

export async function setCategoryStatusAction(raw: unknown) {
  const result = await runAction(categoryStatusSchema, raw, async ({ id, status }) => {
    const row = await setCategoryStatus(id, status);
    return { id: row.id, status: row.status };
  });
  if (result.ok) revalidatePath("/", "layout");
  return result;
}

export async function organizeCaptureAction(raw: unknown) {
  const result = await runAction(organizeCaptureSchema, raw, organizeCapture);
  if (result.ok) revalidatePath("/", "layout");
  return result;
}

export async function auditClaimAction(raw: unknown) {
  const result = await runAction(auditClaimSchema, raw, auditClaim);
  if (result.ok) {
    revalidatePath(`/captures/${result.data.captureId}`);
    revalidatePath("/claims");
  }
  return result;
}

export async function detectCCSwitchAction(raw: unknown) {
  return runAction(detectCCSwitchSchema, raw, detectCCSwitch);
}

export async function testCCSwitchCodexOAuthAction(raw: unknown) {
  return runAction(
    testCCSwitchCodexOAuthSchema,
    raw,
    testCCSwitchCodexOAuth,
  );
}

export async function testCCSwitchCurrentProviderAction(raw: unknown) {
  return runAction(
    testCCSwitchCurrentProviderSchema,
    raw,
    testCCSwitchCurrentProvider,
  );
}

export async function transitionClaimAction(raw: unknown) {
  const result = await runAction(transitionClaimSchema, raw, transitionClaim);
  if (result.ok) revalidatePath(`/captures/${result.data.captureId}`);
  return result;
}

export async function createManualClaimAction(raw: unknown) {
  const result = await runAction(
    createManualClaimSchema,
    raw,
    createManualClaim,
  );
  if (result.ok) {
    revalidatePath(`/captures/${result.data.captureId}`);
    revalidatePath("/claims");
  }
  return result;
}

export async function addClaimEvidenceAction(raw: unknown) {
  const result = await runAction(addClaimEvidenceSchema, raw, addClaimEvidence);
  if (result.ok) revalidatePath(`/captures/${result.data.captureId}`);
  return result;
}

export async function updateClaimEvidenceAction(raw: unknown) {
  const result = await runAction(updateClaimEvidenceSchema, raw, updateClaimEvidence);
  if (result.ok) revalidatePath(`/captures/${result.data.captureId}`);
  return result;
}

export async function uploadEvidenceImageAction(formData: FormData) {
  const result = await runAction(
    uploadEvidenceImageSchema,
    {
      evidenceId: formData.get("evidenceId"),
      file: formData.get("file"),
    },
    uploadEvidenceImage,
  );
  if (result.ok) revalidatePath(`/captures/${result.data.captureId}`);
  return result;
}

/**
 * 客户端直传后的提交（云端部署）。
 *
 * 字节已经由浏览器直接送进对象存储；这里只接收很小的 JSON，并在服务端回读字节复核，
 * 因此既绕开了 Vercel 4.5 MB 的请求体上限，也不把证据链的可信度外包给浏览器。
 */
export async function commitClientUploadedEvidenceImageAction(raw: unknown) {
  const result = await runAction(
    commitClientUploadedEvidenceImageSchema,
    raw,
    commitClientUploadedEvidenceImage,
  );
  if (result.ok) revalidatePath(`/captures/${result.data.captureId}`);
  return result;
}

export async function checkClaimEvidenceSourceAction(raw: unknown) {
  const result = await runAction(
    checkClaimEvidenceSourceSchema,
    raw,
    checkClaimEvidenceSource,
  );
  if (result.ok) revalidatePath(`/captures/${result.data.captureId}`);
  return result;
}

export async function concludeClaimAction(raw: unknown) {
  const result = await runAction(concludeClaimSchema, raw, async (input) =>
    concludeClaim({
      ...input,
      reviewer: await currentActionActor(),
    }),
  );
  if (result.ok) revalidatePath(`/captures/${result.data.captureId}`);
  return result;
}

export async function reviewClaimEvidenceAction(raw: unknown) {
  const result = await runAction(
    reviewClaimEvidenceSchema,
    raw,
    reviewClaimEvidence,
  );
  if (result.ok) revalidatePath(`/captures/${result.data.captureId}`);
  return result;
}

export async function decideSuggestionAction(raw: unknown) {
  const result = await runAction(decideSuggestionSchema, raw, decideSuggestion);
  if (result.ok) {
    revalidatePath("/");
    revalidatePath(`/captures/${result.data.captureId}`);
  }
  return result;
}

export async function rollbackSuggestionAction(raw: unknown) {
  const result = await runAction(
    rollbackSuggestionSchema,
    raw,
    rollbackSuggestion,
  );
  if (result.ok) {
    revalidatePath("/");
    revalidatePath(`/captures/${result.data.captureId}`);
    revalidatePath("/claims");
    revalidatePath("/search");
  }
  return result;
}

export async function generateTopicSynthesisAction(raw: unknown) {
  const result = await runAction(
    generateTopicSynthesisSchema,
    raw,
    generateTopicSynthesis,
  );
  if (result.ok) revalidatePath(`/categories/${result.data.categoryId}`);
  return result;
}

export async function decideTopicSynthesisAction(raw: unknown) {
  const result = await runAction(
    decideTopicSynthesisSchema,
    raw,
    decideTopicSynthesis,
  );
  if (result.ok) revalidatePath(`/categories/${result.data.categoryId}`);
  return result;
}

export async function assessSourceAuthorityAction(raw: unknown) {
  const result = await runAction(
    assessSourceAuthoritySchema,
    raw,
    async (input) => assessSourceAuthority({ ...input, actor: await currentActionActor() }),
  );
  if (result.ok) {
    revalidatePath(`/captures/${result.data.captureId}`);
    revalidatePath(`/claims/${result.data.claimId}/reliability`);
  }
  return result;
}

export async function submitIndependentReviewAction(raw: unknown) {
  const result = await runAction(
    independentReviewSchema,
    raw,
    async (input) => submitIndependentReview({ ...input, actor: await currentActionActor() }),
  );
  if (result.ok) {
    revalidatePath(`/captures/${result.data.captureId}`);
    revalidatePath(`/claims/${result.data.claimId}/reliability`);
  }
  return result;
}

export async function publishReliableKnowledgeAction(raw: unknown) {
  const result = await runAction(
    publishKnowledgeSchema,
    raw,
    async (input) => publishReliableKnowledge({ ...input, actor: await currentActionActor() }),
  );
  if (result.ok) {
    revalidatePath(`/captures/${result.data.captureId}`);
    revalidatePath(`/claims/${result.data.claimId}/reliability`);
    revalidatePath("/claims");
    revalidatePath("/search");
  }
  return result;
}
