import { handleUpload, type HandleUploadBody } from "@vercel/blob/client";
import { NextResponse } from "next/server";

import { isAuthEnabled } from "@/features/auth/go-user-system";
import { requireAuthenticatedUser } from "@/features/auth/session";
import {
  assertEvidenceImageUploadAllowed,
  commitClientUploadedEvidenceImage,
} from "@/features/claims/service";
import { evidenceImageStorageDriver, usesObjectStorage } from "@/features/claims/image-storage";
import {
  EVIDENCE_IMAGE_MIME_TYPES,
  MAX_EVIDENCE_IMAGE_BYTES,
} from "@/features/claims/image-validation";
import { commitClientUploadedEvidenceImageSchema } from "@/features/claims/schema";
import { AppError, toPublicError } from "@/shared/errors/app-error";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const EVIDENCE_ID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const BLOB_PATHNAME_PATTERN = /^evidence\/[0-9a-f-]+\.(?:jpg|png|webp|gif)$/;

/**
 * 客户端直传证据图片的入口（`ISSUE-S3-024`）。
 *
 * `GET`  —— 能力与预检：本地单机部署回答 `available:false`（前端回落到既有 Server Action），
 *            云端回答 `available:true` 并顺带把状态门槛提前判一遍，让用户看到可读的原因，
 *            而不是 `@vercel/blob/client` 抛出的通用「Failed to retrieve the client token」。
 * `POST` —— 两种 JSON：Vercel Blob 的上传令牌请求 / 完成回调（交给 `handleUpload`），
 *            以及浏览器直传成功后**提交**（`evidenceId` + `storagePath`）。
 *
 * 为什么不用 Server Action 直传字节：Vercel 函数的请求体上限是 4.5 MB，而单张图片允许 10 MB。
 * 直传把字节直接从浏览器送到对象存储，函数只处理几 KB 的 JSON。
 */
export async function GET(request: Request) {
  if (isAuthEnabled() && !(await requireAuthenticatedUser())) {
    return NextResponse.json(
      { ok: false, error: { code: "AUTH_REQUIRED", message: "登录会话已失效，请重新登录。" } },
      { status: 401 },
    );
  }
  const evidenceId = new URL(request.url).searchParams.get("evidenceId") ?? "";
  const driver = evidenceImageStorageDriver();
  if (!usesObjectStorage()) {
    return NextResponse.json({ available: false, driver });
  }
  if (!EVIDENCE_ID_PATTERN.test(evidenceId)) {
    return NextResponse.json(
      { ok: false, error: { code: "VALIDATION_ERROR", message: "证据 ID 无效。" } },
      { status: 400 },
    );
  }
  try {
    await assertEvidenceImageUploadAllowed(evidenceId);
  } catch (error) {
    const publicError = toPublicError(error);
    return NextResponse.json({ available: true, driver, ready: false, reason: publicError.message });
  }
  return NextResponse.json({ available: true, driver, ready: true });
}

export async function POST(request: Request) {
  if (isAuthEnabled() && !(await requireAuthenticatedUser())) {
    return NextResponse.json(
      { ok: false, error: { code: "AUTH_REQUIRED", message: "登录会话已失效，请重新登录。" } },
      { status: 401 },
    );
  }
  if (!usesObjectStorage()) {
    return NextResponse.json(
      {
        ok: false,
        error: {
          code: "EVIDENCE_IMAGE_UPLOAD_UNAVAILABLE",
          message: "当前部署未启用对象存储，请刷新页面后重试。",
        },
      },
      { status: 409 },
    );
  }

  const raw = (await request.json().catch(() => null)) as unknown;
  if (!raw || typeof raw !== "object") {
    return NextResponse.json(
      { ok: false, error: { code: "VALIDATION_ERROR", message: "请求体无效。" } },
      { status: 400 },
    );
  }

  const type = (raw as { type?: unknown }).type;
  if (type === "blob.generate-client-token" || type === "blob.upload-completed") {
    return handleBlobEvent(request, raw as HandleUploadBody);
  }
  return commitUploadedImage(raw);
}

async function handleBlobEvent(request: Request, body: HandleUploadBody) {
  try {
    return NextResponse.json(
      await handleUpload({
        request,
        body,
        onBeforeGenerateToken: async (pathname, clientPayload) => {
          if (!BLOB_PATHNAME_PATTERN.test(pathname)) {
            throw new AppError("EVIDENCE_IMAGE_PATH_INVALID", "图片存储路径无效。");
          }
          // 浏览器只报 evidenceId；权限与状态门槛在这里用**服务器自己的查询**判定，
          // 不接受客户端声明的任何权限信息。
          if (!clientPayload || !EVIDENCE_ID_PATTERN.test(clientPayload)) {
            throw new AppError("CLAIM_EVIDENCE_NOT_FOUND", "证据不存在。");
          }
          await assertEvidenceImageUploadAllowed(clientPayload);
          return {
            allowedContentTypes: [...EVIDENCE_IMAGE_MIME_TYPES],
            maximumSizeInBytes: MAX_EVIDENCE_IMAGE_BYTES,
            addRandomSuffix: false,
            // 直传重试会重新 PUT 同一个 pathname；pathname 由随机 UUID 生成，覆盖无碰撞风险。
            allowOverwrite: true,
            tokenPayload: clientPayload,
          };
        },
      }),
    );
  } catch (error) {
    const publicError = toPublicError(error);
    return NextResponse.json({ ok: false, error: publicError }, { status: 400 });
  }
}

async function commitUploadedImage(raw: unknown) {
  const parsed = commitClientUploadedEvidenceImageSchema.safeParse(raw);
  if (!parsed.success) {
    const fieldErrors: Record<string, string[]> = {};
    for (const issue of parsed.error.issues) {
      const key = String(issue.path[0] ?? "form");
      fieldErrors[key] = [...(fieldErrors[key] ?? []), issue.message];
    }
    return NextResponse.json(
      {
        ok: false,
        error: { code: "VALIDATION_ERROR", message: "请检查上传内容。", fieldErrors },
      },
      { status: 400 },
    );
  }
  try {
    const attachment = await commitClientUploadedEvidenceImage(parsed.data);
    return NextResponse.json({
      ok: true,
      data: { id: attachment.id, captureId: attachment.captureId },
    });
  } catch (error) {
    const publicError = toPublicError(error);
    return NextResponse.json({ ok: false, error: publicError }, { status: 400 });
  }
}
