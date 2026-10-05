import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTypeScript from "eslint-config-next/typescript";

export default defineConfig([
  ...nextVitals,
  ...nextTypeScript,
  globalIgnores([
    ".next/**",
    "coverage/**",
    // 两份 Playwright 报告：主配置与认证态配置各一份。
    "playwright-report/**",
    "playwright-report-auth/**",
    "test-results/**",
    "services/go-user-system/**",
    // Understand-Anything 插件的扫描产物。ESLint 的 flat config **不读 .gitignore**，
    // 所以两处都要写：.gitignore 管 git，这里管 lint。
    // 2026-10-05：它此前未被忽略，本机 `pnpm lint` 因此报 15 error（`require()` 风格导入）。
    ".ua/**",
  ]),
]);
