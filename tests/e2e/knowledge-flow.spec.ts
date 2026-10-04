import { expect, test } from "@playwright/test";

test("capture → AI review → accepted knowledge structure", async ({ page }) => {
  const consoleErrors: string[] = [];
  page.on("console", (message) => {
    if (message.type() === "error") {
      consoleErrors.push(message.text());
      console.error("browser console:", message.text());
    }
  });
  page.on("pageerror", (error) => console.error("browser pageerror:", error.message));

  const suffix = Date.now().toString().slice(-6);
  const categoryName = `AI 实践 ${suffix}`;
  const title = `散碎知识整理 ${suffix}`;

  await page.goto("/");
  if (new URL(page.url()).pathname === "/login") {
    const username = process.env.AUTH_E2E_USERNAME;
    const password = process.env.AUTH_E2E_PASSWORD;
    if (!username || !password) {
      throw new Error(
        "authentication is enabled; provide AUTH_E2E_USERNAME and AUTH_E2E_PASSWORD",
      );
    }
    await page.getByLabel("用户名").fill(username);
    await page.getByLabel("密码", { exact: true }).fill(password);
    await page.getByRole("button", { name: "登录", exact: true }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.waitForLoadState("networkidle");
    consoleErrors.length = 0;
  }
  await expect(page.getByRole("heading", { name: "先留下，再慢慢想清楚。" })).toBeVisible();
  await expect(page.locator("[data-nextjs-dialog]")).toHaveCount(0);

  await page.getByLabel("新分类名称").fill(categoryName);
  await expect(page.getByLabel("创建分类")).toBeEnabled({ timeout: 5_000 });
  await page.getByLabel("创建分类").click();
  await expect(page.getByRole("link", { name: new RegExp(categoryName) })).toBeVisible();

  await page.getByPlaceholder("标题可以稍后再补").fill(title);
  await page
    .getByPlaceholder(/输入关键词/)
    .fill("软件；AI接入管理知识库；输入不确定性，输出结构化和系统化的内容");
  await page.locator(".category-picker summary").click();
  await page.getByRole("button", { name: categoryName }).click();
  await page.getByRole("button", { name: /保存并整理/ }).click();

  await expect(page).toHaveURL(/\/captures\/[0-9a-f-]+$/);
  await expect(page.getByRole("heading", { name: "AI 整理台" })).toBeVisible();
  await page.evaluate(() => {
    window.sessionStorage.setItem(
      "knowtrace.ai-credentials.v1",
      JSON.stringify({ openAIConnectionMode: "ccswitch" }),
    );
  });
  await page.reload();
  await page.waitForLoadState("networkidle");
  await page.getByLabel("处理引擎").selectOption("openai");
  await expect(page.getByLabel("OpenAI 连接方式")).toBeVisible();
  await expect(page.getByLabel("OpenAI 连接方式")).toHaveValue(
    "ccswitch_auto",
  );
  await expect(
    page.getByLabel("OpenAI 连接方式").locator('option[value="ccswitch"]'),
  ).toHaveCount(0);
  // 2026-10-04 更正：本段原先断言手工的「测试当前供应商」按钮与门禁按钮
  // 「先测试当前供应商，再开始 AI 整理」。自动检测落地后（KT-DEFER-002，
  // 见 docs/changes/2026-10-01-体验三项修复.md），用户不再需要先手工测试，
  // 于是改为「模型测试（可选）」+ 一行说明文字。此断言到 2026-10-04 才被 CI 发现过期——
  // 因为在此之前 E2E **不在任何自动化门里**（KT-GAP-06）。
  await expect(
    page.getByRole("button", { name: "模型测试（可选）", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("自动检测到可用路由后即可直接整理"),
  ).toBeVisible();
  await expect(page.locator(".connection-check")).toContainText(
    /等待检测|正在自动检测|未能连接|正在测试/,
  );
  await expect(page.getByLabel("CC-Switch 地址")).not.toBeVisible();
  await page.getByText("高级设置（通常无需修改）").click();
  await expect(page.getByLabel("CC-Switch 地址")).toHaveValue(
    "http://host.docker.internal:15721/v1",
  );
  await expect(page.getByLabel("CC-Switch 代理令牌")).toBeVisible();
  await expect(page.getByLabel("CC-Switch 模型路由名")).toHaveValue(
    "claude-sonnet-4-5",
  );
  await page.screenshot({
    fullPage: true,
    path: "test-results/ai-connection-ui.png",
  });
  if (process.env.CC_SWITCH_E2E === "true") {
    await page
      .getByRole("button", { name: "测试当前供应商", exact: true })
      .click();
    await expect(
      page.getByText("当前供应商可用于 AI 整理", { exact: true }),
    ).toBeVisible({ timeout: 35_000 });
    await expect(
      page.getByRole("button", { name: /开始分析版本/ }),
    ).toBeEnabled();
  }
  await page.getByLabel("OpenAI 连接方式").selectOption("api_key");
  await page.getByLabel("OpenAI API Key").fill("sk-openai-session-test");
  await page.getByLabel("仅在当前浏览器标签页记住凭据").check();
  await page.reload();
  await page.waitForLoadState("networkidle");
  await page.getByLabel("处理引擎").selectOption("openai");
  await expect(page.getByLabel("OpenAI 连接方式")).toHaveValue("api_key");
  await expect(page.getByLabel("OpenAI API Key")).toHaveValue(
    "sk-openai-session-test",
  );
  await page.getByLabel("仅在当前浏览器标签页记住凭据").uncheck();
  await page.getByLabel("OpenAI 连接方式").selectOption("ccswitch_auto");
  await page.getByText("高级设置（通常无需修改）").click();
  await page.getByLabel("CC-Switch 地址").fill("https://example.com/v1");
  await expect(
    page.getByText(/CC-Switch 仅允许使用本机 HTTP\(S\) 地址/),
  ).toBeVisible();
  await page.getByLabel("处理引擎").selectOption("deepseek");
  await expect(page.getByLabel("DeepSeek API Key")).toBeVisible();
  await page.getByLabel("处理引擎").selectOption("mock");
  await expect(page.getByText(/将分析已保存版本 v\d+/)).toBeVisible();

  const savedContent = `${await page.getByLabel("原文").inputValue()}\n补充一段需要先保存的内容。`;
  await page.getByLabel("原文").fill(savedContent);
  await expect(page.getByText("有未保存修改，AI 暂时不会分析这些内容。")).toBeVisible();
  await page.getByRole("button", { name: /先保存，再开始 AI 整理/ }).click();
  await expect(page.getByText(/检测到原始记录有未保存修改/)).toBeVisible();
  await expect(page.getByRole("button", { name: "保存修改" })).toBeFocused();
  await page.getByRole("button", { name: "保存修改" }).click();
  await expect(page.getByText("Source record · v2")).toBeVisible();
  await expect(page.locator(".form-saved")).toHaveText("已保存版本 v2");
  await page.reload();
  await page.waitForLoadState("networkidle");
  await expect(page.getByRole("button", { name: /开始分析版本/ })).toBeEnabled();

  await page.getByRole("button", { name: /开始分析版本/ }).click();
  await expect(page.getByText("等待你的决定")).toBeVisible();
  await expect(page.getByText("这是本地规则生成的演示建议，不包含事实核验。")).toBeVisible();
  await expect(page.locator(".review-options label")).toHaveCount(1);
  await expect(page.locator(".content-suggestion-list label")).toHaveCount(1);
  const comparison = page.locator(".content-comparison-block");
  await expect(comparison.getByRole("heading", { name: "AI 文本替换前后对比" })).toBeVisible();
  await expect(comparison.getByText("0 处替换")).toBeVisible();
  await expect(comparison.getByText("尚未选择文本替换")).toBeVisible();
  await page.locator(".content-suggestion-list input").check();
  await expect(comparison.getByText("1 处替换")).toBeVisible();
  await expect(comparison.getByText("应用当前所选建议")).toBeVisible();
  await expect(comparison.locator("article").nth(0).locator("pre")).toContainText("输入不确定性");
  await expect(comparison.locator("article").nth(1).locator("pre")).toContainText("将不确定输入整理为结构化、系统化内容");
  await page.screenshot({
    fullPage: true,
    path: "test-results/ai-text-comparison.png",
  });

  await page.getByRole("button", { name: /接受当前选择/ }).click();
  await expect(page.getByText("生成一份可审阅的整理建议")).toBeVisible();
  await expect(page.getByLabel("标题")).toHaveValue(title);
  await expect(page.getByLabel("原文")).toHaveValue(/将不确定输入整理为结构化、系统化内容/);
  await page.locator(".history-list summary").click();
  await expect(page.getByText(/修改后接受/)).toBeVisible();
  await expect(page.getByRole("button", { name: "整体回退这次整理" })).toBeVisible();
  await page.reload();
  await page.waitForLoadState("networkidle");
  await expect(page.getByRole("button", { name: "整体回退这次整理" })).toBeEnabled();

  await page.getByRole("button", { name: "整体回退这次整理" }).click();
  await expect(page.getByText("恢复采纳前的标题、内容类型、原文和 AI 分类。")).toBeVisible();
  await page.getByRole("button", { name: "确认整体回退" }).click();
  await expect(page.getByLabel("原文")).toHaveValue(savedContent);
  await page.locator(".history-list summary").click();
  await expect(page.getByText("已整体回退")).toBeVisible();
  await expect(page.getByRole("button", { name: "整体回退这次整理" })).toHaveCount(0);

  await page.screenshot({ fullPage: true, path: "test-results/knowtrace-flow.png" });
  await page.getByRole("link", { name: /返回收集箱/ }).click();
  await expect(page).toHaveURL(/http:\/\/localhost:\d+\/$/);
  await expect(page.getByRole("heading", { name: title })).toBeVisible();
  await page.getByRole("heading", { name: title }).click();
  await expect(page).toHaveURL(/\/captures\/[0-9a-f-]+$/);
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByRole("button", { name: "永久删除" }).click();
  await expect(page).toHaveURL(/http:\/\/localhost:\d+\/$/);
  await expect(page.getByRole("heading", { name: title })).toHaveCount(0);

  await page.goto("/categories");
  const categoryRow = page.locator(".category-manage-row").filter({
    has: page.getByLabel(`${categoryName}的名称`),
  });
  page.once("dialog", (dialog) => dialog.accept());
  await categoryRow.getByRole("button", { name: "删除" }).click();
  await expect(categoryRow).toHaveCount(0);
  expect(consoleErrors).toEqual([]);
});
