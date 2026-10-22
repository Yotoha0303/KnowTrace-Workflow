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
 * 存储凭据的形态。
 *
 * - `read-write-token`：静态 `BLOB_READ_WRITE_TOKEN`（自建环境、或手工注入）。
 * - `oidc`：Vercel 上把存储「连接」到项目时的默认方式——只注入 `BLOB_STORE_ID`，
 *   运行时用短期的 `VERCEL_OIDC_TOKEN` 换授权。**服务端读写只靠 OIDC 就够**。
 *
 * ⚠️ 区分它们是有代价的教训：`2026-10-22` 生产上传失败，日志是「没有可用的对象存储凭据」，
 * 而项目其实已经用 OIDC 连好了存储——因为驱动判定只认静态 token 就回落到了只读的本地磁盘。
 */
export type EvidenceImageBlobCredentials = "read-write-token" | "oidc" | "none";

export function evidenceImageBlobCredentials(): EvidenceImageBlobCredentials {
  if (process.env.BLOB_READ_WRITE_TOKEN?.trim()) return "read-write-token";
  // OIDC 的 token 由 `@vercel/oidc` 从**请求上下文头** `x-vercel-oidc-token` 取
  // （`getVercelOidcToken()` 的首选来源，env 只是兜底），所以这里**不能**只查 env：
  // 在 Vercel 上只要存储已连接（BLOB_STORE_ID 在场），OIDC 就是运行时可得。
  const storeConnected = Boolean(process.env.BLOB_STORE_ID?.trim());
  if (storeConnected && (process.env.VERCEL === "1" || process.env.VERCEL_OIDC_TOKEN?.trim())) {
    return "oidc";
  }
  return "none";
}

/**
 * 选择存储驱动。
 *
 * `EVIDENCE_IMAGE_STORAGE` 显式指定时以它为准；未指定时，**只要存储可用就走对象存储**：
 * 静态 token 或 OIDC（Vercel 连接存储的默认方式）都算——少一种「记得配哪个变量」的静默失败。
 */
export function evidenceImageStorageDriver(): EvidenceImageStorageDriver {
  const configured = process.env.EVIDENCE_IMAGE_STORAGE?.trim();
  if (configured === "local" || configured === "vercel-blob") return configured;
  return evidenceImageBlobCredentials() === "none" ? "local" : "vercel-blob";
}

export function usesObjectStorage(): boolean {
  return evidenceImageStorageDriver() === "vercel-blob";
}

/**
 * 浏览器**直传**是否可用：SDK 的 `handleUpload`（签发客户端令牌）只接受静态读写令牌，
 * 没有 token 时 SDK 自己会抛错，不会退到 OIDC。
 *
 * ⇒ OIDC 存储上走服务端中转写入（文件 ≤10 MB，通过 Server Action，见 `client-upload` 的探测）。
 */
export function supportsClientDirectUpload(): boolean {
  return evidenceImageBlobCredentials() === "read-write-token";
}

/**
 * 显式要求走对象存储、但凭据缺失时的说明。
 *
 * 不静默回落：回落到"云端写本地"正好复现本 issue 的症状（看起来在跑，实际写进易失目录）。
 */
export function objectStorageCredentialWarning(): string | null {
  if (evidenceImageStorageDriver() !== "vercel-blob") return null;
  if (evidenceImageBlobCredentials() !== "none") return null;
  return (
    "[knowtrace-startup] EVIDENCE_IMAGE_STORAGE=vercel-blob 但没有可用的对象存储凭据：\n" +
    "  需要 `BLOB_READ_WRITE_TOKEN`，或在 Vercel 上把 Blob 存储**连接**到本项目" +
    "（注入 BLOB_STORE_ID，运行时由 VERCEL_OIDC_TOKEN 鉴权）。"
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
  try {
    // 写入之后可能立刻被回读校验（见 service.ts 的提交路径），故关掉随机后缀与覆盖，
    // 让 pathname 与数据库里的 storage_path 一一对应。
    await put(evidenceImageBlobPathname(storagePath), Buffer.from(bytes), {
      access: blobAccess(),
      addRandomSuffix: false,
      allowOverwrite: false,
      contentType,
    });
  } catch (error) {
    if (error instanceof AppError) throw error;
    throw translateBlobError(error) ?? error;
  }
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
  // 凭据类失败**没有** HTTP 状态码（SDK 在发请求前就抛了），必须单独识别，
  // 否则会落进「未知错误」→ 500，用户看不到该配什么。
  if (/No blob credentials found|No read-write token found/i.test(message)) {
    return new AppError(
      "EVIDENCE_IMAGE_STORAGE_UNAUTHORIZED",
      "图片存储没有可用凭据：请把 Blob 存储连接到项目（OIDC），或注入 BLOB_READ_WRITE_TOKEN。",
      { cause: message },
    );
  }
  if (/Invalid token|unable to extract store ID/i.test(message)) {
    return new AppError(
      "EVIDENCE_IMAGE_STORAGE_UNAUTHORIZED",
      "图片存储凭据无效（token 无法解析出 store id），请检查 BLOB_READ_WRITE_TOKEN。",
      { cause: message },
    );
  }
  const status = Number(/\b(\d{3})\b/.exec(message)?.[1] ?? NaN);
  if (status === 404) return new AppError("EVIDENCE_IMAGE_NOT_FOUND", "图片不存在。");
  if (status === 401 || status === 403) {
    return new AppError(
      "EVIDENCE_IMAGE_STORAGE_UNAUTHORIZED",
      "图片存储凭据无效或已过期，请检查 Blob 存储的连接状态与 token。",
      { cause: message },
    );
  }
  if (/store.*not.*found|storeId/i.test(message)) {
    return new AppError(
      "EVIDENCE_IMAGE_STORAGE_NOT_CONFIGURED",
      "图片存储未正确配置（存储不存在，或凭据与存储不匹配）。",
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
  try {
    await del(evidenceImageBlobPathname(storagePath));
  } catch (error) {
    // 删除时的「不存在」等价于已删除；其余错误仍要如实上抛。
    if (translateBlobError(error)?.code === "EVIDENCE_IMAGE_NOT_FOUND") return;
    throw translateBlobError(error) ?? error;
  }
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
