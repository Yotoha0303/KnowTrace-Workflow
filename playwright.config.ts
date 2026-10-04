import { defineConfig, devices } from "@playwright/test";

const port = Number(process.env.PLAYWRIGHT_PORT ?? 3000);
const baseURL = `http://localhost:${port}`;

export default defineConfig({
  testDir: "./tests/e2e",
  // A full knowledge workflow performs several server actions and may trigger
  // first-use route compilation in `next dev`. Keep the per-assertion timeout
  // strict while allowing the complete scenario enough time to finish.
  timeout: 90_000,
  fullyParallel: false,
  // Tests mutate persistent knowledge records. Serial execution prevents
  // global revalidation and cleanup from one scenario racing another scenario.
  workers: 1,
  retries: 0,
  reporter: "html",
  expect: {
    timeout: 15_000,
  },
  use: {
    baseURL,
    navigationTimeout: 20_000,
    trace: "retain-on-failure",
  },
  webServer: {
    // 2026-10-04 改为跑**生产构建**而不是 dev。
    // 两个理由：
    //   1. 生产跑的就是 `next start`，E2E 该验同一形态；dev 与 prod 的行为差异
    //      （热更新、开发态覆盖层、React 开发态告警）会让门禁测的不是要发布的东西。
    //   2. 实测：dev 会在输入框上注入 `style={{caret-color:"transparent"}}`（源码里
    //      grep `caret` 为空，属 Next 开发态行为），它使 `/claims` 页产生
    //      hydration mismatch，被 claim-workflow 的 consoleErrors 断言逮到而报红。
    //      那是**开发态产物**，生产构建里不存在。
    command: `pnpm build && pnpm start --port ${port}`,
    url: `${baseURL}/api/health`,
    reuseExistingServer: true,
    // 首次要跑一次 next build，给足时间。
    timeout: 300_000,
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
