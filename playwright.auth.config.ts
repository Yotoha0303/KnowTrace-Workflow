import { defineConfig, devices } from "@playwright/test";

/**
 * **认证态**的端到端配置。
 *
 * 为什么要单独一份配置，而不是在主配置里打开认证
 * -------------------------------------------------
 * 主配置（`playwright.config.ts`）跑全部 18 个 spec，其中 6 个
 * （category-deletion / claim-workflow / knowledge-search / similar-captures /
 * subject-timeline / topic-synthesis）**没有登录分支**，直接 `page.goto("/")`。
 * 一旦全局打开 `AUTH_ENABLED=true`，它们会被 Proxy 307 到登录页而全部变红 ——
 * 那不是「测出了问题」，是**门配错了**。
 *
 * 所以这里把认证态**隔离**出来：用不同的端口、只跑那 4 个真正需要账号的 spec。
 * 主配置的运行结果完全不受影响（该跳过的照旧跳过）。
 *
 * 常见坑：`reuseExistingServer` 默认 true，若两个配置共用同一个端口，
 * 第二次会直接复用第一次那个**没有认证**的服务，于是「认证态」名不副实。
 * 所以端口必须不同（`PLAYWRIGHT_PORT` 由 CI 传 3100）。
 *
 * 覆盖的 4 个 spec 与它们需要的东西：
 *   auth-flow      —— 登录 / 刷新续期 / 登出 / 未授权附件返回 401
 *   account-center —— 账户中心与权限展示
 *   mobile-api     —— `/api/v1` 契约（含原生令牌链路）
 *   ai-runs-api    —— AI Run 契约（`provider: mock`，不依赖网络）
 *
 * 刻意**不含**的（各有独立前置，见 ci.yml 的说明）：
 *   content-ownership  需要第二个**非 admin** 账号
 *   iteration-fixes    需要 CC-Switch 代理
 *   reliable-release   需要 RELIABLE_RELEASE_E2E=true 的自建 fixture
 *   account-management 需要注册**开启** + 可丢弃账号
 */
const port = Number(process.env.PLAYWRIGHT_PORT ?? 3100);
const baseURL = `http://localhost:${port}`;

export default defineConfig({
  testDir: "./tests/e2e",
  // 带 `**/` 前缀：Playwright 的 testMatch 是对**完整路径**做 glob，
  // 裸文件名匹配不到 `tests/e2e/xxx.spec.ts`（会一个用例都不跑，而看起来是绿的）。
  testMatch: [
    "**/auth-flow.spec.ts",
    "**/account-center.spec.ts",
    "**/mobile-api.spec.ts",
    "**/ai-runs-api.spec.ts",
  ],
  timeout: 90_000,
  fullyParallel: false,
  workers: 1,
  // ⚠ 2026-10-06：`retries` 从 0 改成 1 —— 这条门**实测是 flaky 的**。
  //
  // 证据（同一份代码、同一条测试，先红后绿三次）：
  //   run 37430511889 (4f96800) e2e **failure** ← auth-flow 登录后停在 /login?next=
  //   run 37434242868 (34d3bbc) e2e success
  //   run 37435716086 (b59c098) e2e success
  //   run 37437081510 (2ffcc5d) e2e success
  // 而 34d3bbc..2ffcc5d 之间只改了 ci.yml（加一条 runbook 检查），**没碰 e2e/auth**。
  //
  // 这是「偶发」而不是「真坏」：失败时测试确实走到了登录表单并提交，
  // 只是没有跳转 —— 候选是认证服务在冷启动后的响应时延。
  //
  // **为什么用 retries=1 而不是把 timeout 调大**：这条配置本来就在文件头警告过
  // 「脆弱到偶发红的门比没有门更坏（会训练人忽略红色）」。retries 是 Playwright
  // **专门为这种非确定性**提供的机制，且失败时仍会留下 trace 与失败报告 ——
  // 它是「吸收抖动」，不是「掩盖问题」。
  //
  // ⚠ 边界（别把 retries 当万能）：它只吸收**偶发**。若这条门变成**经常**需要重试，
  //   那说明有真问题（登录时延、种子账号、限流），要回去查根因，而不是继续加 retries。
  retries: 1,
  reporter: [["list"], ["html", { outputFolder: "playwright-report-auth", open: "never" }]],
  expect: { timeout: 15_000 },
  use: {
    baseURL,
    navigationTimeout: 20_000,
    trace: "retain-on-failure",
  },
  webServer: {
    // 与主配置同样跑**生产构建**（理由见 playwright.config.ts 的注释）。
    // 这里自己 build 而不是复用主配置的产物：两个 step 相互独立，
    // 主配置那步失败时本步仍然要能跑，否则「红在哪」会被混在一起。
    command: `pnpm build && pnpm start --port ${port}`,
    url: `${baseURL}/api/health`,
    reuseExistingServer: false,
    timeout: 300_000,
  },
  projects: [
    {
      name: "chromium-auth",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
