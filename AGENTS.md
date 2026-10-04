<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

## 本项目的 AI 工具与模型

**客户端（开发工具）**

- ChatGPT Codex —— Windows 桌面软件
- Claude Code —— 经 CC-Switch 代理

**模型**

- ChatGPT
- DeepSeek

**不使用 Claude 模型，也不使用 claude.ai。**

### 别把 `claude-*` 读成「在用 Claude」

代码里的 `createAnthropic`、`claude-sonnet-4-5` 是 CC-Switch 路由的**入站协议别名**，
不是模型选择：

- `src/features/ai-processing/schema.ts` 要求 `ccswitch_codex_oauth` 路由的模型名以
  `claude-` 开头——因为**入站**说的是 Anthropic Messages 协议；
- **出站**去哪由 CC-Switch 决定，`src/server/ai/provider.ts` 里注明「CC-Switch 可能把
  请求转发给不同供应商」；
- 因此 `claude-sonnet-4-5` 只是满足前缀要求的默认别名，**不等于真的会调用 Claude**。

CC-Switch 的用途就是让说 Anthropic 协议的客户端去用别的模型；开发机上这么用，
应用里那条 `ccswitch_codex_oauth` 路由是同一件事。
