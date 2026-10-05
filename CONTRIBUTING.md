# 贡献指南

感谢你关注 KnowTrace-Workflow。项目优先接受范围清晰、行为可验证、不会模糊“记录、主张、证据与结论”边界的改动。

## 开始之前

1. 对较大的功能或行为变更，先创建 Issue 说明目标、使用场景和验收方式。
2. 不要提交真实 API Key、账号凭据、数据库备份、用户记录或证据附件。
3. 保持一次 Pull Request 只解决一个主题，避免无关重构和依赖升级。

## 本地开发

要求：Node.js、pnpm、Go、Docker Desktop，以及 Windows PowerShell 或兼容环境。

```bash
pnpm install
make up
```

如果环境中没有 GNU Make，可运行：

```powershell
.\scripts\start-all.ps1
```

## 提交前验证

```bash
pnpm typecheck
pnpm lint
pnpm test
pnpm build
cd services/go-user-system && go test ./...
cd services/go-user-system/frontend && npm ci --no-audit --no-fund && npm run lint && npm test && npm run build
```

与 `make check` 和 CI 的三个 job（`quality` / `go` / `auth-frontend`）一一对应。
**这三处要一起改**——只改一处会让「本地过了」与「CI 过了」不再是同一件事（见 `.github/workflows/ci.yml` 的 `go` job 注释）。

> **注意 `services/go-user-system/frontend` 的两点**：它是 `git subtree` 引入的上游副本，
> 用 **npm**（自带 `package-lock.json`），不是 pnpm；它**自带一份 flat config**
> （`eslint.config.mjs`），因为仓库根的 flat config 会向上查找并忽略整棵子树
> （`globalIgnores` 里有 `services/go-user-system/**`），且 flat 模式没有 `--ext`。
> 详见 `docs/08` §2.3.1。

涉及迁移、鉴权、Workspace、导入导出或附件的改动，还应补充对应的真实数据库或端到端验证，并在 Pull Request 中区分单元测试、本地集成测试和部署验证。

### 部署验证

在 VPS 上部署用 `scripts/linux/deploy-observability.sh --build-app`（或 `make deploy`）。
**不要手写 `docker compose up -d --build`** —— 必须同时给两个 `--env-file` 和三个 `-f`
（`scripts/linux/deploy-observability.sh:48` 是唯一的权威写法）：

```bash
docker compose --project-directory .   --env-file .env --env-file .env.observability   -f compose.yaml -f compose.production.yaml -f compose.observability.yaml   up -d --no-deps --build --wait app
```

**`--build-app` 是关键开关**：不带它时脚本走 `--no-build`，只重启旧镜像却照样报成功。
2026-09-29 观察到的「部署目录 HEAD 47a4c20 / 运行中 7ce26f7d，差 37 个提交」就是这么来的。

脚本在最后一步断言运行态：不一致时，若两者之间 `src/`、`drizzle/` 或构建相关文件
**有变化**则以退出码 2 失败；**没有变化**则只告警（只改监控配置时不一致是预期的）。
这条断言是必要的：`git pull` 成功、`HEAD` 对得上、容器 healthy、探针 200，
**都不能证明跑的是新代码**。

## Pull Request

- 说明问题、解决方案、风险和回滚方式。
- 列出修改文件和实际执行的验证命令。
- UI 变化请附截图，但先移除真实姓名、记录正文、密钥和其他隐私信息。
- 新增行为应同步更新测试与相关文档。

提交代码即表示你同意按照项目的 [MIT License](LICENSE) 提供该贡献。

## 目录与命名约定

本节是把仓库里**已经在执行**的约定写下来。每条都可在代码里核验，不是新规定
（核验方法：文件命名为 `git ls-files src` 全量枚举；错误码为 `grep -rhoE '"[A-Z][A-Z0-9_]{4,}"' src/`）。

### 目录结构（实际，非规划）

```text
src/
├── app/          Next.js App Router（直接路由，无 route group）
├── components/   跨域复用的 UI 组件
├── features/     业务域，每个域自带 service / repository / schema / components
├── server/       只有 ai/ 与 db/（基础设施适配，不含业务规则）
└── shared/       跨域共享：errors/、validation/、常量
drizzle/          必须提交的 SQL 迁移（Drizzle Schema 不是唯一文档）
tests/e2e/        Playwright 端到端
services/go-user-system/   Go 认证服务（独立模块，有自己的 git 忽略与测试）
deploy/           Ansible / Caddy / 监控 / systemd 等分层部署资产
docs/             00–24 契约与说明 + adr/ + changes/ + 日常运维/
scripts/          bootstrap / linux / ops 三类脚本
```

> `docs/06-architecture.md` 第 4 节保留着一份**实施前的规划目录树**，与实际结构有差异，
> 该节开头已标注「不要逐条核对路径」。**以本节为准。**

### 命名

| 对象 | 约定 | 实例 |
|---|---|---|
| 源文件名 | **kebab-case**，一律小写（仓库内零例外） | `claim-evidence-revision.ts`、`workspace-switcher.tsx` |
| React 组件 | 导出名 PascalCase，文件名仍 kebab-case | `export function WorkspaceSwitcher` ← `workspace-switcher.tsx` |
| 业务域目录 | kebab-case | `data-transfer/`、`topic-synthesis/` |
| 数据库表 / 列 | `snake_case`（SQL 与迁移里） | `data_import_objects.import_run_id` |
| 错误码 | `SCREAMING_SNAKE_CASE`，**以域名为前缀**；经 `AppError(code, message)` 抛出 | `CAPTURE_VERSION_CONFLICT`、`WORKSPACE_ACCESS_DENIED` |
| 测试文件 | 与被测文件**同目录**，后缀 `.test.ts(x)` | `src/features/workspace/policy.test.ts` ← `policy.ts` |

**错误码为什么带域前缀**：错误码是给客户端分支用的契约。`NOT_FOUND` 这种无前缀名
在两个域同时出现时就无法区分，而前缀让它天然自解释。新增错误码前先
`grep -r` 一遍，避免同义不同名。

**测试为什么同目录**：域内聚。**例外只有两处** —— `tests/e2e/` 是跨域的浏览器级用例，
`src/client-server-boundary.test.ts` 是全局边界断言。

### 项目纪律（评审必查）

1. **依赖方向**：`Page/Component → Server Action/Query → Application Service → Repository/Provider → Drizzle/SDK`，**禁止反向**。完整禁令清单见 `docs/06-architecture.md` 第 5 节。
2. **Workspace 边界**：所有可归属业务行带 `workspace_id`，隔离**只在应用层强制（数据库未开 RLS）**——新增任何读写入口必须显式带 `eq(<表>.workspaceId, scope.workspaceId)`。见 [ADR-0017](docs/adr/0017-workspace-isolation-model.md)。
3. **服务端不信任客户端提交的身份与 Workspace**：只能用回带的令牌重新解析。客户端提交的 workspace 是「优先项」，越权在服务端被拒。
4. **迁移只追加不修改**：已执行 Migration 不改，只新增；`docs/04` 的表清单必须与 `drizzle/` 一一对应。
5. **部署命令只有一处权威写法**：`scripts/linux/deploy-observability.sh`（见上节）。**任何人不得手写 `docker compose up -d --build`。**
6. **`docs/changes/` 先写后填**：行为变更先在 `docs/changes/` 落一份记录，再提交代码。
