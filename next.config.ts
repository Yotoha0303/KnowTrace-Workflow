import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone",
  poweredByHeader: false,
  experimental: {
    serverActions: {
      // 这条只覆盖**本地 / 自建部署**的 FormData 上传通道（单张最大 10 MB）。
      // ⚠️ 它**改不了 Vercel 平台**的函数请求体上限（4.5 MB）——云端部署走浏览器直传
      // 对象存储，见 ADR-0020 与 src/app/api/evidence-images/upload/route.ts。
      bodySizeLimit: "12mb",
    },
  },
  async headers() {
    return [
      {
        // Next 的 /_next/static/ 路径**带内容哈希**，内容变则路径变，
        // 所以可以永久缓存且不会读到旧版本。
        //
        // 为什么需要：2026-10-01 实测，"访问慢"的真实成因不是服务端
        // （p50 5.9 ms，没有一条请求超过 1 秒），而是浏览器要下载
        // 1.2 MB / 24 个 chunk 的 JS，而静态资源此前没有长缓存
        // （响应头是 private, no-cache, no-store）。
        //
        // 这不是"关掉缓存"——HTML 与 API 的 no-store 保持不变，它们是**正确**的：
        // HTML 必须每次校验（会话状态会变），API 更不能缓存。
        // 只对"内容哈希即路径"的静态资源放长缓存。
        source: "/_next/static/:path*",
        headers: [
          {
            key: "Cache-Control",
            value: "public, max-age=31536000, immutable",
          },
        ],
      },
    ];
  },
};

export default nextConfig;
