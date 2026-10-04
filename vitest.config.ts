import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./src", import.meta.url)),
      // `server-only` 在打包期由 Next 标记，import 时直接抛错，单测里换成 no-op。
      "server-only": fileURLToPath(
        new URL("./tests/stubs/server-only.ts", import.meta.url),
      ),
    },
  },
  test: {
    environment: "node",
    // 收 .tsx：组件测试需要 JSX。
    // 环境仍是全局 node，需要 DOM 的文件用 `// @vitest-environment jsdom` 按文件指定——
    // 这样不会影响既有的大量 node 测试。
    include: ["src/**/*.test.{ts,tsx}", "tests/**/*.test.{ts,tsx}"],
    // 覆盖率：CI 通过 `pnpm add -D @vitest/coverage-v8@<与 vitest 同版本>` 提供 provider。
    // 本地未装 provider 时 `--coverage` 会报 `MISSING DEPENDENCY`，这是**预期**的，
    // 不是配置错误。阈值见下方 thresholds —— 它们是**实测基线之后**才写进来的，
    // 现在留空表示「先采集、后设门」，避免拍脑袋定一个数字。
    coverage: {
      provider: "v8",
      reporter: ["text", "json-summary", "html"],
      // 只统计源码；排除测试自身、Next 生成物与类型声明。
      include: ["src/**/*.{ts,tsx}"],
      exclude: [
        "src/**/*.test.{ts,tsx}",
        "src/**/*.d.ts",
        "src/instrumentation.ts",
      ],
      // thresholds：待 CI 首次产出 json-summary 后回填（见 docs/08 §2.4）。
      // 回填之前**故意不给数字**——没有基线的阈值只会被绕过。
    },
  },
});
