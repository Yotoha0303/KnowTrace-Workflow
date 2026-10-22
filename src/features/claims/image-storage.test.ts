import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("@vercel/blob", () => ({
  put: vi.fn(),
  get: vi.fn(),
  del: vi.fn(),
  BlobError: class BlobError extends Error {},
}));

const blob = await import("@vercel/blob");
const {
  evidenceImageBlobPathname,
  evidenceImageBlobCredentials,
  evidenceImageStorageDriver,
  objectStorageCredentialWarning,
  readEvidenceImage,
  removeEvidenceImage,
  supportsClientDirectUpload,
  usesObjectStorage,
  writeEvidenceImage,
} = await import("./image-storage");

const UUID_PNG = "0f1e2d3c-4b5a-4968-8776-655443322110.png";
const UUID_JPG = "0f1e2d3c-4b5a-4968-8776-655443322110.jpg";

const PNG_HEADER = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

afterEach(() => {
  delete process.env.EVIDENCE_IMAGE_STORAGE;
  delete process.env.EVIDENCE_IMAGE_BLOB_ACCESS;
  delete process.env.BLOB_READ_WRITE_TOKEN;
  delete process.env.BLOB_STORE_ID;
  delete process.env.VERCEL_OIDC_TOKEN;
  delete process.env.VERCEL;
  vi.mocked(blob.put).mockReset();
  vi.mocked(blob.get).mockReset();
  vi.mocked(blob.del).mockReset();
});

describe("证据图片存储驱动选择", () => {
  it("没有 Blob 凭据时回落本地磁盘", () => {
    expect(evidenceImageStorageDriver()).toBe("local");
    expect(usesObjectStorage()).toBe(false);
    expect(objectStorageCredentialWarning()).toBeNull();
  });

  it("Vercel 上自动注入 BLOB_READ_WRITE_TOKEN 后走对象存储", () => {
    process.env.BLOB_READ_WRITE_TOKEN = "vercel_blob_rw_test";
    expect(evidenceImageStorageDriver()).toBe("vercel-blob");
    expect(usesObjectStorage()).toBe(true);
    // 有凭据时不产生告警
    expect(objectStorageCredentialWarning()).toBeNull();
  });

  it("显式配置优先于凭据推断（两个方向都要能覆盖）", () => {
    process.env.BLOB_READ_WRITE_TOKEN = "vercel_blob_rw_test";
    process.env.EVIDENCE_IMAGE_STORAGE = "local";
    expect(evidenceImageStorageDriver()).toBe("local");

    delete process.env.BLOB_READ_WRITE_TOKEN;
    process.env.EVIDENCE_IMAGE_STORAGE = "vercel-blob";
    expect(evidenceImageStorageDriver()).toBe("vercel-blob");
  });

  it("显式要求对象存储但缺凭据时给出可读告警，而不是静默回落", () => {
    process.env.EVIDENCE_IMAGE_STORAGE = "vercel-blob";
    expect(evidenceImageStorageDriver()).toBe("vercel-blob");
    expect(objectStorageCredentialWarning()).toContain("BLOB_READ_WRITE_TOKEN");
  });

  it("Vercel 用 OIDC 连接存储（BLOB_STORE_ID + VERCEL=1，OIDC 从请求头取）时也必须走对象存储", () => {
    // 2026-10-22 生产故障：只认静态 token ⇒ 已用 OIDC 连好的存储被判定为「没有凭据」，
    // 驱动回落本地磁盘，上传必然失败。
    // 注意：`@vercel/oidc` 的 getVercelOidcToken() 首选读**请求上下文头** x-vercel-oidc-token，
    // env 只是兜底 ⇒ 判定不能只查 VERCEL_OIDC_TOKEN。
    process.env.BLOB_STORE_ID = "store_abc123";
    process.env.VERCEL = "1";
    expect(evidenceImageBlobCredentials()).toBe("oidc");
    expect(evidenceImageStorageDriver()).toBe("vercel-blob");
    expect(objectStorageCredentialWarning()).toBeNull();
    // 但 OIDC 下**不能**浏览器直传（SDK 的 handleUpload 只认静态读写令牌）
    expect(supportsClientDirectUpload()).toBe(false);
  });

  it("有 BLOB_STORE_ID + VERCEL_OIDC_TOKEN（本地模拟）时同样判为 OIDC", () => {
    process.env.BLOB_STORE_ID = "store_abc123";
    process.env.VERCEL_OIDC_TOKEN = "oidc-token-value";
    expect(evidenceImageBlobCredentials()).toBe("oidc");
  });

  it("只有 BLOB_STORE_ID、既不在 Vercel 也没有 OIDC 时不算可用（本地脚本常见）", () => {
    process.env.BLOB_STORE_ID = "store_abc123";
    expect(evidenceImageBlobCredentials()).toBe("none");
    expect(evidenceImageStorageDriver()).toBe("local");
  });

  it("静态读写令牌下浏览器直传可用", () => {
    process.env.BLOB_READ_WRITE_TOKEN = "vercel_blob_rw_test";
    expect(supportsClientDirectUpload()).toBe(true);
  });
});

describe("Blob pathname 映射（护栏）", () => {
  it("把数据库里的 storage_path 映射到 evidence/ 前缀", () => {
    expect(evidenceImageBlobPathname(UUID_PNG)).toBe(`evidence/${UUID_PNG}`);
  });

  it("拒绝目录穿越、非法扩展名与非 uuid 名称", () => {
    for (const invalid of [
      `evidence/../${UUID_PNG}`,
      `${UUID_PNG.toUpperCase()}`,
      "0f1e2d3c-4b5a-4968-8776-655443322110.svg",
      "screenshot.png",
      "",
    ]) {
      expect(() => evidenceImageBlobPathname(invalid)).toThrowError(
        expect.objectContaining({ code: "EVIDENCE_IMAGE_PATH_INVALID" }),
      );
    }
  });
});

describe("对象存储驱动上的读写删", () => {
  it("写入时按扩展名给出 content-type，且不加随机后缀、不允许覆盖", async () => {
    process.env.BLOB_READ_WRITE_TOKEN = "vercel_blob_rw_test";
    await writeEvidenceImage(UUID_PNG, PNG_HEADER);
    expect(vi.mocked(blob.put)).toHaveBeenCalledTimes(1);
    expect(vi.mocked(blob.put).mock.calls[0][0]).toBe(`evidence/${UUID_PNG}`);
    expect(vi.mocked(blob.put).mock.calls[0][2]).toMatchObject({
      access: "private",
      addRandomSuffix: false,
      allowOverwrite: false,
      contentType: "image/png",
    });
  });

  it("读回字节；404 翻译成「图片不存在」而不是存储故障", async () => {
    process.env.BLOB_READ_WRITE_TOKEN = "vercel_blob_rw_test";
    const body = new Blob([PNG_HEADER]);
    vi.mocked(blob.get).mockResolvedValue({
      statusCode: 200,
      stream: body.stream(),
      headers: new Headers(),
      blob: {
        url: "https://store.private.blob.vercel-storage.com/evidence/x.png",
        downloadUrl: "https://store.private.blob.vercel-storage.com/evidence/x.png",
        pathname: `evidence/${UUID_PNG}`,
        contentType: "image/png",
        contentDisposition: "inline",
        cacheControl: "private",
        uploadedAt: new Date(),
        etag: "etag",
        size: PNG_HEADER.byteLength,
      },
    });
    const bytes = await readEvidenceImage(UUID_PNG);
    expect(Array.from(bytes)).toEqual(Array.from(PNG_HEADER));

    vi.mocked(blob.get).mockRejectedValue(
      new blob.BlobError("Failed to fetch blob: 404 Not Found"),
    );
    await expect(readEvidenceImage(UUID_PNG)).rejects.toMatchObject({
      code: "EVIDENCE_IMAGE_NOT_FOUND",
    });
  });

  it("凭据失效不能被伪装成「图片不存在」", async () => {
    process.env.BLOB_READ_WRITE_TOKEN = "vercel_blob_rw_test";
    vi.mocked(blob.get).mockRejectedValue(
      new blob.BlobError("Failed to fetch blob: 403 Forbidden"),
    );
    await expect(readEvidenceImage(UUID_PNG)).rejects.toMatchObject({
      code: "EVIDENCE_IMAGE_STORAGE_UNAUTHORIZED",
    });
  });

  it("其它存储故障原样上抛（不翻译、不吞掉）", async () => {
    process.env.BLOB_READ_WRITE_TOKEN = "vercel_blob_rw_test";
    vi.mocked(blob.get).mockRejectedValue(
      new blob.BlobError("Failed to fetch blob: 500 Internal Server Error"),
    );
    await expect(readEvidenceImage(UUID_PNG)).rejects.toThrow("500 Internal Server Error");
  });

  it("删除走 del；不吞掉其它错误", async () => {
    process.env.BLOB_READ_WRITE_TOKEN = "vercel_blob_rw_test";
    await removeEvidenceImage(UUID_JPG);
    expect(vi.mocked(blob.del)).toHaveBeenCalledWith(`evidence/${UUID_JPG}`);

    vi.mocked(blob.del).mockRejectedValue(new Error("network down"));
    await expect(removeEvidenceImage(UUID_JPG)).rejects.toThrow("network down");
  });

  it("凭据类失败（无状态码）必须翻译成可读错误，不能落进「未知错误」", async () => {
    process.env.BLOB_READ_WRITE_TOKEN = "vercel_blob_rw_test";
    vi.mocked(blob.put).mockRejectedValue(
      new blob.BlobError("No blob credentials found. Pass a `token` option, set BLOB_READ_WRITE_TOKEN, or use `oidcToken`"),
    );
    await expect(writeEvidenceImage(UUID_PNG, PNG_HEADER)).rejects.toMatchObject({
      code: "EVIDENCE_IMAGE_STORAGE_UNAUTHORIZED",
    });
  });
});
