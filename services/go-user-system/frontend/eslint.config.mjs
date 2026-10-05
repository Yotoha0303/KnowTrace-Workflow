// 这个前端是 `git subtree` 引入的 go-user-system 上游副本，自带 `package-lock.json`、
// 不参与根的 pnpm workspace。它需要**自己的一份 flat config**，原因是两件事叠加：
//
//   1. 仓库根有 `eslint.config.mjs`（flat）。eslint 从被 lint 的目录**向上查找**配置文件，
//      一旦发现 flat config 就整体进入 flat 模式 —— 而 flat 模式**移除了 `--ext`**，
//      原来的 `lint` 脚本（`eslint . --ext ts,tsx`）必然报
//      `Invalid option '--ext' - perhaps you meant '-c'?`。
//   2. 就算去掉 `--ext` 也还是不行：根 flat config 的 `globalIgnores` 里有
//      `services/go-user-system/**`，把整棵子树都忽略掉了（连本目录原来的
//      `.eslintrc.cjs` 一起失效），于是报 `all of the files matching the glob pattern "." are ignored`。
//
// 所以本文件放在这里，让 eslint 在**进入子目录时**就命中 flat config、不再向上走到根，
// 两个问题同时消失。**不需要新依赖** —— 用到的四个包本来就在 devDependencies 里。
//
// 规则与原来的 `.eslintrc.cjs` 对齐（eslint:recommended + ts + react-hooks + react-refresh）。
// `.eslintrc.cjs` 保留但已不生效（flat 模式下 eslint 不看它）；
// 两者都留着是有意的 —— 万一将来升到 eslint 9 再统一，不用回头考古。
import js from "@eslint/js";
import globals from "globals";
import tseslint from "@typescript-eslint/eslint-plugin";
import tsparser from "@typescript-eslint/parser";
import reactHooks from "eslint-plugin-react-hooks";
import reactRefresh from "eslint-plugin-react-refresh";

// vitest 开了 `globals: true`（见 vitest.config.ts），所以测试文件里
// `describe/it/expect/vi` 是全局的、不 import。
const vitestGlobals = {
  describe: "readonly", it: "readonly", test: "readonly", expect: "readonly",
  vi: "readonly", beforeAll: "readonly", beforeEach: "readonly",
  afterAll: "readonly", afterEach: "readonly", suite: "readonly",
};

export default [
  { ignores: ["dist/**", "node_modules/**", "playwright-report/**", "test-results/**"] },
  js.configs.recommended,
  {
    files: ["**/*.{ts,tsx}"],
    languageOptions: {
      parser: tsparser,
      parserOptions: { ecmaVersion: "latest", sourceType: "module" },
      // 等价于原来 `.eslintrc.cjs` 的 `env: { browser: true }`。
      // 用 `globals` 包而不是手写 —— 手写必然漏（我第一版漏了 KeyboardEvent 就报了错）。
      globals: { ...globals.browser, ...globals.node, ...vitestGlobals },
    },
    plugins: {
      "@typescript-eslint": tseslint,
      "react-hooks": reactHooks,
      "react-refresh": reactRefresh,
    },
    rules: {
      ...tseslint.configs.recommended.rules,
      ...reactHooks.configs.recommended.rules,
      "react-refresh/only-export-components": ["warn", { allowConstantExport: true }],
      // 关掉 `no-undef` —— 与 TS 重复，且是 @typescript-eslint 官方建议的做法
      // （TS 自己就报未定义标识符，ESLint 再报一遍只会产生假阳性）。
      // 这也正是原 `.eslintrc.cjs` 的**实际行为**：它 extends 了
      // `plugin:@typescript-eslint/recommended`，而那份配置会关掉 no-undef。
      // 我第一版 flat config 没照搬这一点，于是凭空多出 81 个 no-undef 报错。
      "no-undef": "off",
    },
  },
];
