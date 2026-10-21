import { describe, expect, it } from "vitest";

import {
  commitClientUploadedEvidenceImageSchema,
} from "./schema";
import { verifyStoredEvidenceImageBytes } from "./image-validation";

const EVIDENCE_ID = "d92f5b20-52d0-4b3e-b9ad-3b1fd759bd6a";

describe("客户端直传提交载荷（形状校验）", () => {
  it("接受服务端生成的 <uuid>.<ext> 路径", () => {
    expect(
      commitClientUploadedEvidenceImageSchema.safeParse({
        evidenceId: EVIDENCE_ID,
        storagePath: "0f1e2d3c-4b5a-4968-8776-655443322110.png",
        originalName: "截图.png",
      }).success,
    ).toBe(true);
  });

  it("拒绝穿越、大写扩展名、带前缀或非 uuid 的路径（浏览器不得指定任意对象 key）", () => {
    for (const storagePath of [
      "../secret.png",
      "evidence/0f1e2d3c-4b5a-4968-8776-655443322110.png",
      "0f1e2d3c-4b5a-4968-8776-655443322110.PNG",
      "0f1e2d3c-4b5a-4968-8776-655443322110.exe",
      "notes.png",
    ]) {
      expect(
        commitClientUploadedEvidenceImageSchema.safeParse({ evidenceId: EVIDENCE_ID, storagePath })
          .success,
        storagePath,
      ).toBe(false);
    }
  });

  it("必填 evidenceId，且 originalName 可省略", () => {
    expect(
      commitClientUploadedEvidenceImageSchema.safeParse({
        storagePath: "0f1e2d3c-4b5a-4968-8776-655443322110.png",
      }).success,
    ).toBe(false);
    expect(
      commitClientUploadedEvidenceImageSchema.safeParse({
        evidenceId: EVIDENCE_ID,
        storagePath: "0f1e2d3c-4b5a-4968-8776-655443322110.png",
      }).success,
    ).toBe(true);
  });
});

describe("服务端回读字节的复核（不信任浏览器声明）", () => {
  const pngBytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const pngPath = "0f1e2d3c-4b5a-4968-8776-655443322110.png";

  it("按真实字节计算 MIME / 大小 / SHA-256", () => {
    const verified = verifyStoredEvidenceImageBytes(pngBytes, pngPath);
    expect(verified.mimeType).toBe("image/png");
    expect(verified.byteSize).toBe(pngBytes.byteLength);
    // SHA-256 of the 8-byte PNG signature
    expect(verified.sha256).toMatch(/^[0-9a-f]{64}$/);
  });

  it("字节与 pathname 扩展名不一致时拒绝（例如把 .png 路径指向非 PNG 内容）", () => {
    expect(() =>
      verifyStoredEvidenceImageBytes(pngBytes, "0f1e2d3c-4b5a-4968-8776-655443322110.jpg"),
    ).toThrowError(expect.objectContaining({ code: "EVIDENCE_IMAGE_TYPE_INVALID" }));
    expect(() =>
      verifyStoredEvidenceImageBytes(new TextEncoder().encode("not an image"), pngPath),
    ).toThrowError(expect.objectContaining({ code: "EVIDENCE_IMAGE_TYPE_INVALID" }));
  });

  it("空字节与超过 10 MB 的字节都被拒绝", () => {
    expect(() => verifyStoredEvidenceImageBytes(new Uint8Array(0), pngPath)).toThrowError(
      expect.objectContaining({ code: "EVIDENCE_IMAGE_SIZE_INVALID" }),
    );
    const oversized = new Uint8Array(10 * 1024 * 1024 + 1);
    oversized.set(pngBytes);
    expect(() => verifyStoredEvidenceImageBytes(oversized, pngPath)).toThrowError(
      expect.objectContaining({ code: "EVIDENCE_IMAGE_SIZE_INVALID" }),
    );
  });
});
