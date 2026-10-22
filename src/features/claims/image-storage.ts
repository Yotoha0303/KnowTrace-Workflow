import "server-only";

import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import path from "node:path";

import { AppError } from "@/shared/errors/app-error";

export type EvidenceImageStorageDriver = "local" | "vercel-blob";

const BLOB_PATHNAME_PREFIX = "evidence/";

/**
 * 云端对象存储里这条记录对应的 pathname。
 *
 * `evidence_attachments.storage_path` 的语义**没有变**（仍是 `<uuid>.<ext>`）；
 * 这里只负责把它映射到存储侧的 key，避免把桶内布局写进数据库。
 */
export function evidenceImageBlobPathname(storagePath: string): string {
  if (!/^[0-9a-f-]+\.(?:jpg|png|webp|gif)$/.test(storagePath)) {
    throw new AppError("EVIDENCE_IMAGE_PATH_INVALID", "图片存储路径无效。");
  }
  return `${BLOB_PATHNAME_PREFIX}${storagePath}`;
}

function blobAccess(): "public" | "private" {
  const configured = process.env.EVIDENCE_IMAGE_BLOB_ACCESS?.trim();
  if (configured === "public" || configured === "private") return configured;
  return "private";
}

/** 上传令牌签发给浏览器时，浏览器必须使用与存储一致的可见性；由服务端告知，避免两处各写一份。 */
export function evidenceImageBlobAccess(): "public" | "private" {
  return blobAccess();
}

/**
 * 选择存储驱动。
 *
 * `EVIDENCE_IMAGE_STORAGE` 显式指定时以它为准；未指定时，只要环境里有 Blob 凭据就走对象存储
 * —— Vercel 上连接 Blob 存储会自动注入 `BLOB_READ_WRITE_TOKEN`，多一步「记得配这个变量」
 * 只会多一种静默失败。
 */
export function evidenceImageStorageDriver(): EvidenceImageStorageDriver {
  const configured = process.env.EVIDENCE_IMAGE_STORAGE?.trim();
  if (configured === "local" || configured === "vercel-blob") return configured;
  return process.env.BLOB_READ_WRITE_TOKEN ? "vercel-blob" : "local";
}

export function usesObjectStorage(): boolean {
  return evidenceImageStorageDriver() === "vercel-blob";
}

/**
 * 显式要求走对象存储、但凭据缺失时的说明。
 *
 * 不静默回落：回落到"云端写本地"正好复现本 issue 的症状（看起来在跑，实际写进易失目录）。
 */
export function objectStorageCredentialWarning(): string | null {
  if (evidenceImageStorageDriver() !== "vercel-blob") return null;
  if (process.env.BLOB_READ_WRITE_TOKEN) return null;
  return (
    "[knowtrace-startup] EVIDENCE_IMAGE_STORAGE=vercel-blob 但缺少 BLOB_READ_WRITE_TOKEN：\n" +
    "  图片上传会在签发直传令牌时失败。请在 Vercel 项目的 Storage 中创建（Private）Blob 存储，\n" +
    "  并在项目环境变量中注入 BLOB_READ_WRITE_TOKEN。"
  );
}

function uploadRoot(): string {
  return path.resolve(
    /* turbopackIgnore: true */
    process.env.EVIDENCE_UPLOAD_DIR ?? path.join(process.cwd(), "data", "uploads", "evidence"),
  );
}

export { uploadRoot as evidenceUploadRoot };

function resolveStoredPath(storagePath: string): string {
  if (!/^[0-9a-f-]+\.(?:jpg|png|webp|gif)$/.test(storagePath)) {
    throw new AppError("EVIDENCE_IMAGE_PATH_INVALID", "图片存储路径无效。");
  }
  const root = uploadRoot();
  const resolved = path.resolve(root, storagePath);
  if (path.dirname(resolved) !== root) {
    throw new AppError("EVIDENCE_IMAGE_PATH_INVALID", "图片存储路径无效。");
  }
  return resolved;
}

async function writeLocal(storagePath: string, bytes: Uint8Array) {
  const root = uploadRoot();
  await mkdir(root, { recursive: true });
  const target = resolveStoredPath(storagePath);
  const temporary = `${target}.${randomUUID()}.tmp`;
  await writeFile(temporary, bytes, { flag: "wx" });
  try {
    await rename(temporary, target);
  } catch (error) {
    await unlink(temporary).catch(() => undefined);
    throw error;
  }
}

async function readLocal(storagePath: string) {
  return readFile(/* turbopackIgnore: true */ resolveStoredPath(storagePath));
}

async function removeLocal(storagePath: string) {
  await unlink(resolveStoredPath(storagePath)).catch((error: NodeJS.ErrnoException) => {
    if (error.code !== "ENOENT") throw error;
  });
}

async function blobModule() {
  return import("@vercel/blob");
}

async function writeBlob(storagePath: string, bytes: Uint8Array, contentType: string) {
  const { put } = await blobModule();
  // 写入之后可能立刻被回读校验（见 service.ts 的提交路径），故关掉随机后缀与覆盖，
  // 让 pathname 与数据库里的 storage_path 一一对应。
  await put(evidenceImageBlobPathname(storagePath), Buffer.from(bytes), {
    access: blobAccess(),
    addRandomSuffix: false,
    allowOverwrite: false,
    contentType,
  });
}

/**
 * 把 SDK 的原始错误翻译成**可区分**的应用错误。
 *
 * 为什么必须分类：调用方（读图路由）原本把一切异常都当成「图片不存在」返回 404，
 * 于是凭据缺失 / 存储无权限 / 网络故障全都伪装成 404 —— 正是本 issue 家族
 * 「看起来正常、其实没在工作」的形态。现在只有真正的 404 才算「不存在」，
 * 其余一律带上真实原因上抛，由调用方记日志并按 5xx 处理。
 */
function translateBlobError(error: unknown): AppError | null {
  const message = error instanceof Error ? error.message : String(error);
  const status = Number(/\b(\d{3})\b/.exec(message)?.[1] ?? NaN);
  if (status === 404) return new AppError("EVIDENCE_IMAGE_NOT_FOUND", "图片不存在。");
  if (status === 401 || status === 403) {
    return new AppError(
      "EVIDENCE_IMAGE_STORAGE_UNAUTHORIZED",
      "图片存储凭据无效或已过期，请联系管理员检查 BLOB_READ_WRITE_TOKEN。",
      { cause: message },
    );
  }
  if (/store.*not.*found|storeId/i.test(message)) {
    return new AppError(
      "EVIDENCE_IMAGE_STORAGE_NOT_CONFIGURED",
      "图片存储未正确配置（存储不存在或 token 与存储不匹配）。",
      { cause: message },
    );
  }
  return null;
}

async function readBlob(storagePath: string): Promise<Buffer> {
  const { get } = await blobModule();
  try {
    const result = await get(evidenceImageBlobPathname(storagePath), { access: blobAccess() });
    if (!result || result.statusCode !== 200) {
      throw new AppError("EVIDENCE_IMAGE_NOT_FOUND", "图片不存在。");
    }
    return Buffer.from(await new Response(result.stream).arrayBuffer());
  } catch (error) {
    if (error instanceof AppError) throw error;
    throw translateBlobError(error) ?? error;
  }
}

async function removeBlob(storagePath: string) {
  const { del } = await blobModule();
  await del(evidenceImageBlobPathname(storagePath));
}

export async function writeEvidenceImage(
  storagePath: string,
  bytes: Uint8Array,
  options: { contentType?: string } = {},
) {
  if (evidenceImageStorageDriver() === "vercel-blob") {
    const extension = path.extname(storagePath).slice(1).toLowerCase();
    const contentType =
      options.contentType ??
      {
        jpg: "image/jpeg",
        png: "image/png",
        webp: "image/webp",
        gif: "image/gif",
      }[extension];
    if (!contentType) {
      throw new AppError("EVIDENCE_IMAGE_PATH_INVALID", "图片存储路径无效。");
    }
    await writeBlob(storagePath, bytes, contentType);
    return;
  }
  await writeLocal(storagePath, bytes);
}

export async function readEvidenceImage(storagePath: string) {
  if (evidenceImageStorageDriver() === "vercel-blob") {
    return readBlob(storagePath);
  }
  return readLocal(storagePath);
}

export async function removeEvidenceImage(storagePath: string) {
  if (evidenceImageStorageDriver() === "vercel-blob") {
    await removeBlob(storagePath);
    return;
  }
  await removeLocal(storagePath);
}
