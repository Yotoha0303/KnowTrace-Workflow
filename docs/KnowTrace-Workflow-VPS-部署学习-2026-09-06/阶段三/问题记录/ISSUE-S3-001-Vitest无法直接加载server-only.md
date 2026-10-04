# ISSUE-S3-001：Vitest 无法直接加载 server-only

- 范围：本地测试。
- 状态：已关闭。
- 影响：新增 metrics route 测试首次无法加载 Next.js 的 `server-only` 边界模块；未影响 VPS。

## 现象

指标实现被设计为只在服务端加载，但 Vitest 的 Node 测试环境不等同于 Next.js 构建运行时，直接导入时触发 `server-only` 保护。

## 根因

测试环境缺少 Next.js 对该边界包的构建期处理。问题是测试夹具边界，不是把服务器代码改成客户端可用的理由。

## 修复

在相应测试中显式 mock `server-only`，生产代码仍保留服务端边界。

## 验证

- 37 个测试文件、144 个测试通过。
- TypeScript、ESLint、Next.js production build 通过。
- 构建产物包含 `/api/metrics`。

## 经验

测试框架与真实框架运行时不同。修测试隔离时不能删除安全边界；应 mock 环境依赖并同时跑 production build。
