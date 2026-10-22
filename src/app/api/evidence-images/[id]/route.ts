import { eq } from "drizzle-orm";

import { readEvidenceImage } from "@/features/claims/image-storage";
import { isAuthEnabled } from "@/features/auth/go-user-system";
import { requireAuthenticatedUser } from "@/features/auth/session";
import { db } from "@/server/db/client";
import { evidenceAttachments } from "@/server/db/schema";
import { requireAttachmentReadAccess } from "@/features/auth/access";
import { AppError } from "@/shared/errors/app-error";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ id: string }> },
) {
  if (isAuthEnabled() && !(await requireAuthenticatedUser())) {
    return new Response("Unauthorized", { status: 401 });
  }
  const { id } = await params;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) {
    return new Response("Not found", { status: 404 });
  }
  try {
    await requireAttachmentReadAccess(id);
  } catch {
    return new Response("Not found", { status: 404 });
  }
  const [attachment] = await db
    .select({
      storagePath: evidenceAttachments.storagePath,
      mimeType: evidenceAttachments.mimeType,
      byteSize: evidenceAttachments.byteSize,
    })
    .from(evidenceAttachments)
    .where(eq(evidenceAttachments.id, id))
    .limit(1);
  if (!attachment) return new Response("Not found", { status: 404 });

  try {
    const image = await readEvidenceImage(attachment.storagePath);
    // `new Uint8Array(buffer)` 会复制到一个带独立 ArrayBuffer 的视图：
    // Node 的 Buffer 是 ArrayBufferLike，不能直接作为 Response body（TS 会拒绝）。
    return new Response(new Uint8Array(image), {
      headers: {
        "Cache-Control": "private, max-age=31536000, immutable",
        "Content-Length": String(attachment.byteSize),
        "Content-Type": attachment.mimeType,
        "X-Content-Type-Options": "nosniff",
      },
    });
  } catch (error) {
    // 只有「存储里确实没有这张图」才是 404。凭据失效、存储未配置、网络故障
    // 一律 503 并记录真实原因 —— 否则它们会被伪装成"图片不存在"，
    // 排查时看不到任何线索（ISSUE-S3-024 的同类形态）。
    if (error instanceof AppError && error.code === "EVIDENCE_IMAGE_NOT_FOUND") {
      return new Response("Not found", { status: 404 });
    }
    console.error("[evidence-images] 读取图片存储失败", {
      attachmentId: id,
      code: error instanceof AppError ? error.code : "UNKNOWN",
      message: error instanceof Error ? error.message : String(error),
    });
    return new Response("Storage unavailable", { status: 503 });
  }
}
