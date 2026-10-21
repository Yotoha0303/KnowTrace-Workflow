import "server-only";

import { constants } from "node:fs";
import { access, mkdir, writeFile, unlink } from "node:fs/promises";
import path from "node:path";

import {
  evidenceUploadRoot,
  objectStorageCredentialWarning,
  usesObjectStorage,
} from "@/features/claims/image-storage";

/**
 * 检查证据图片的存储真的可用，不可用就大声报错。
 *
 * 两条驱动、两种判据：
 *
 * 1. **本地磁盘（默认）**：`compose.yaml` 把 `./data/uploads` 作为绑定挂载覆盖
 *    `/app/data/uploads`，会盖掉 Dockerfile 里 `chown -R nextjs:nodejs /app/data` 的结果。
 *    宿主机首次 `docker compose up` 时该目录由 root 创建，容器内进程是 uid 1001，于是每次
 *    `writeFile(..., {flag:"wx"})` 都抛 EACCES。这个故障曾经静默发生了 42 次
 *    （2026-09-13 38 次、09-19 4 次），因为写入失败只反映在图片上传的请求里。
 *
 * 2. **对象存储（Vercel Blob）**：容器文件系统不可写是**预期**的，此时再探测本地目录只会
 *    产生一条误导性的告警（`ISSUE-S3-024` 的现场就是这样）。改为检查凭据是否在场，
 *    并说明缺什么、去哪里补。
 *
 * pid 1 和 Next.js 都跑在 uid 1001 下，所以本地探测的结果就是真实写入能力。
 */
export async function assertUploadDirectoryWritable(): Promise<void> {
  if (usesObjectStorage()) {
    const warning = objectStorageCredentialWarning();
    if (warning) console.error(warning);
    return;
  }

  const root = evidenceUploadRoot();

  try {
    await mkdir(root, { recursive: true });
  } catch (error) {
    console.error(
      `[knowtrace-startup] 证据图片目录无法创建：${root}`,
      error instanceof Error ? error.message : error,
    );
    return;
  }

  try {
    await access(root, constants.W_OK);
  } catch {
    console.error(
      `[knowtrace-startup] 证据图片目录不可写：${root}\n` +
        "  图片上传会以 EACCES 失败。宿主机执行（uid/gid 与容器内 nextjs 一致）：\n" +
        "    sudo chown -R 1001:65533 <部署目录>/data/uploads\n" +
        "  若刚执行过 docker compose up，容器会把绑定挂载重新以 root 创建，需要重新执行上面这条。",
    );
    return;
  }

  // access 只反映权限位，不反映挂载只读等情况，这里做一次真实写入。
  const probe = path.join(root, `.startup-write-probe-${process.pid}`);
  try {
    await writeFile(probe, "", { flag: "wx" });
    await unlink(probe);
  } catch (error) {
    console.error(
      `[knowtrace-startup] 证据图片目录写入探测失败：${root}`,
      error instanceof Error ? error.message : error,
    );
  }
}
