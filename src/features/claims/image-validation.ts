import { createHash, randomUUID } from "node:crypto";
import path from "node:path";

import { AppError } from "@/shared/errors/app-error";

export const MAX_EVIDENCE_IMAGE_BYTES = 10 * 1024 * 1024;
export const MAX_EVIDENCE_IMAGES = 5;

export const EVIDENCE_IMAGE_MIME_TYPES = [
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/gif",
] as const;

type SupportedImage = {
  extension: "jpg" | "png" | "webp" | "gif";
  mimeType: (typeof EVIDENCE_IMAGE_MIME_TYPES)[number];
};

function detectImage(bytes: Uint8Array): SupportedImage | null {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return { extension: "jpg", mimeType: "image/jpeg" };
  }
  if (
    bytes.length >= 8 &&
    [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].every(
      (value, index) => bytes[index] === value,
    )
  ) {
    return { extension: "png", mimeType: "image/png" };
  }
  const header = Buffer.from(bytes.subarray(0, 12));
  if (header.subarray(0, 4).toString("ascii") === "RIFF" && header.subarray(8, 12).toString("ascii") === "WEBP") {
    return { extension: "webp", mimeType: "image/webp" };
  }
  const gifHeader = header.subarray(0, 6).toString("ascii");
  if (gifHeader === "GIF87a" || gifHeader === "GIF89a") {
    return { extension: "gif", mimeType: "image/gif" };
  }
  return null;
}

export async function prepareEvidenceImage(file: File) {
  if (file.size < 1 || file.size > MAX_EVIDENCE_IMAGE_BYTES) {
    throw new AppError("EVIDENCE_IMAGE_SIZE_INVALID", "单张图片必须小于 10 MB。");
  }
  const bytes = new Uint8Array(await file.arrayBuffer());
  const detected = detectImage(bytes);
  if (!detected || detected.mimeType !== file.type) {
    throw new AppError(
      "EVIDENCE_IMAGE_TYPE_INVALID",
      "图片实际格式与文件声明不一致，仅支持 JPEG、PNG、WebP 或 GIF。",
    );
  }
  const originalName = path.basename(file.name).replace(/[\u0000-\u001f\u007f]/g, "").slice(0, 255) || `image.${detected.extension}`;
  return {
    bytes,
    originalName,
    storagePath: `${randomUUID()}.${detected.extension}`,
    mimeType: detected.mimeType,
    byteSize: bytes.byteLength,
    sha256: createHash("sha256").update(bytes).digest("hex"),
  };
}

/**
 * 从存储回读的字节重新做一遍格式与大小校验。
 *
 * 客户端直传路径上，字节**先落对象存储、再由浏览器告诉服务端它上传的是哪个 pathname**——
 * 服务端不能相信浏览器声明的 MIME / 大小 / 哈希，所以提交时把字节读回来，用与
 * `prepareEvidenceImage` 相同的魔数判据重新验证，并由服务端计算 SHA-256（证据链的可信度
 * 不能外包给客户端）。
 */
export function verifyStoredEvidenceImageBytes(bytes: Uint8Array, storagePath: string) {
  if (bytes.byteLength < 1 || bytes.byteLength > MAX_EVIDENCE_IMAGE_BYTES) {
    throw new AppError("EVIDENCE_IMAGE_SIZE_INVALID", "单张图片必须小于 10 MB。");
  }
  const detected = detectImage(bytes);
  const extension = path.extname(storagePath).slice(1).toLowerCase();
  if (!detected || detected.extension !== extension) {
    throw new AppError(
      "EVIDENCE_IMAGE_TYPE_INVALID",
      "图片实际格式与存储路径不一致，仅支持 JPEG、PNG、WebP 或 GIF。",
    );
  }
  return {
    mimeType: detected.mimeType,
    byteSize: bytes.byteLength,
    sha256: createHash("sha256").update(bytes).digest("hex"),
  };
}
