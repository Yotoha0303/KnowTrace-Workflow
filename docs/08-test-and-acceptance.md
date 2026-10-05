# 测试与验收

> 最后核对：**2026-08-24**，依据 `87956c2`。
> 本行**只在内容变更时**更新，不随改名/格式化变动——约定见 [CONTRIBUTING.md](../CONTRIBUTING.md)「目录与命名约定」。

## 1. 风险优先级

1. 原文保存与修订历史。
2. 并发编辑和重复提交。
3. 分类关系正确性。
4. AI 失败隔离。
5. AI 输出 Schema 与来源约束。
6. 认证开关、会话失效和部署边界不被误解。
7. 管理员与普通成员的数据范围不会串线。
8. AI 候选不会绕过人工选择与证据门槛。

## 2. 单元测试

### 2.1 当前规模（实测）

> 下表是 **2026-10-04 实测**，不是预期值。数字来源与复算方法都写在「怎么复算」里，
> 供下次更新时对照。**凡本节的数字都要带日期与复算命令**——旧版正是没有这两样，
> 才让「36 文件 / 141 用例」这样的旧数字看起来像已验证的结论。

| 范围 | 测试文件 | 用例 | 谁在跑 |
|---|---:|---:|---|
| 根 vitest（`src/**` + `tests/**`） | **44** | **180 passed + 1 skipped** | `pnpm test`（CI `quality` job，每次 push） |
| └ 其中条件跳过的 | 1 | 1 | 未配真实 API Key 时跳过，见 2.2 |
| `services/go-user-system/frontend`（**独立 npm 工作区**） | **7** | **11 passed** | CI `auth-frontend` job（**2026-10-04 新增**）—— 见 2.3 |
| Go `_test.go`（`services/go-user-system`） | 26 | 未采集 | CI `go` job（`go test ./...`） |
| E2E spec（`tests/e2e/`）· **无认证** | 18 | **11 passed + 8 skipped** | CI `e2e` job 第 1 次运行（**2026-10-04 起**，见 §5） |
| E2E spec（`tests/e2e/`）· **有认证** | 4 | **4 passed** | CI `e2e` job 第 2 次运行（**2026-10-05 新增**，`playwright.auth.config.ts`，见 §5） |

受版本控制的「单测文件」总数为 **52**，其中 **8 个**属于上述独立前端工作区，
故根 vitest 实际纳入 **44** 个。**两个数字都真实，差在「谁的口径」**——引用时必须说明是哪一个。

**怎么复算**（三条都要，缺一条就会得出错误对照）：

```bash
# ① 受版本控制的测试文件总数（不要用文件系统遍历，会算进 node_modules）
git ls-files | grep -E '\.(test|spec)\.tsx?$' | grep -v '^tests/e2e/' | wc -l   # → 52
# ② 其中不属于根 vitest 的（独立前端工作区）
git ls-files | grep -E '\.(test|spec)\.tsx?$' | grep -c '^services/go-user-system/frontend/'  # → 8
# ③ 实际执行的真实数字（唯一权威）
./node_modules/.bin/vitest run
# ④ 独立前端工作区（不在 ③ 的范围里，要单独跑）
cd services/go-user-system/frontend && npm ci --no-audit --no-fund && npm test   # → 7 files / 11 tests
```


### 2.2 条件跳过的用例

`src/server/ai/provider.integration.test.ts` 用 `describe.skipIf(!apiKey)` 包住
「真实 AI Provider 集成」一组。未提供 API Key 时整组跳过 —— 这是**刻意**的：
它要打真实供应商，不能进默认门。要跑它必须显式给凭据：

```bash
AI_INTEGRATION_API_KEY=... ./node_modules/.bin/vitest run src/server/ai/provider.integration.test.ts
```

**注意**：它被跳过时**不会**让 CI 变红，所以「CI 全绿」不代表这一组跑过。
这正是「测试数量」与「测试覆盖」两件事的区别。

### 2.3 独立前端工作区（`services/go-user-system/frontend`）

该目录是 `git subtree`（提交 `c945952`）引入的 go-user-system 上游仓库副本，
**自带 `package.json`、`package-lock.json`（376 KB）与自己的 vitest**，
**不参与根的 pnpm workspace**，7 个 vitest 文件也不在根 vitest 的 `include` 范围内
（根只含 `src/**` 与 `tests/**`，这个目录两边都不是）。

> **它不参与本部署**：`compose*.yaml` 里没有对应服务，`nginx`/`Caddy` 不引用它，
> 而 `services/go-user-system/Dockerfile` 只编译 Go 二进制、**不构建这个前端**。
> **但「不属于运行时」不等于「可以没有门」**——受版本控制的测试必须在某个门里，
> 否则它会腐烂而没人知道（见下）。

**2026-10-04：已进 CI**（job `auth-frontend`，`npm ci` → `npm test` → `npm run build`）。
本机实测基线：**`Test Files 7 passed (7)`、`Tests 11 passed (11)`**，构建通过
（`tsc && vite build`，含类型检查）。

**复算方法**：

```bash
cd services/go-user-system/frontend
npm ci --no-audit --no-fund     # 用 npm，不是 pnpm：它有 package-lock.json
npm test                        # vitest run
npm run build                   # tsc && vite build
```

#### 2.3.1 它的 `lint` 脚本曾**必然失败**（2026-10-05 已修）

修复前的失败形态：

```bash
npm run lint   # ✗ Invalid option '--ext' - perhaps you meant '-c'?
```

两个独立的原因叠加：

1. `package.json` 里写的是 `eslint . --ext ts,tsx --max-warnings 0`，
   假设的是 **eslintrc 风格**；但仓库根有一个 **flat config `eslint.config.mjs`**，
   eslint 从被 lint 的目录**向上查找**配置文件，一旦发现 flat config 就走 flat 模式，
   而 **flat 模式移除了 `--ext`** → 报错。
2. 去掉 `--ext` 也还是不行：根 flat config 的 `globalIgnores` 里有
   `services/go-user-system/**`，把整棵子树（**包括子目录自己的 `.eslintrc.cjs`**）一并忽略，
   于是 `eslint .` 报「all of the files matching the glob pattern "." are ignored」。

**修法（采用）**：让子目录**自备一份 flat config**（`eslint.config.mjs`），
这样 eslint 一进子目录就命中，不再向上走到根配置。`lint` 脚本去掉 `--ext`。
**不需要新依赖** —— 用到的 `@eslint/js`、`@typescript-eslint/*`、
`eslint-plugin-react-hooks`、`eslint-plugin-react-refresh`、`globals` 本来就在 devDependencies 里。

```bash
cd services/go-user-system/frontend && npm run lint   # → exit 0
```

**两道容易踩的坑（都实测踩过）**：

- **别用 `ESLINT_USE_FLAT_CONFIG=false` 去「修」它**。实测确实能过，但那只是把 eslint
  推回 eslintrc 模式、继续读那个已被根配置忽略的 `.eslintrc.cjs` ——
  等于承认「这个子目录在仓库的 lint 体系之外」，与 `KT-GAP-32` 要立的规矩相反。
- **写 flat config 时不要照搬 `js.configs.recommended` 就完事**。它会把 `no-undef` 打开，
  而**原来的 `.eslintrc.cjs` 其实是关着它的** —— 因为 `plugin:@typescript-eslint/recommended`
  会关掉 no-undef（TS 自己就报未定义标识符，ESLint 再报一遍是假阳性）。
  照搬会凭空多出 **81 个** no-undef 报错（`^KeyboardEvent`、`vi`、`describe`… 全是假阳性）。
  正确的做法是：`globals: { ...globals.browser, ...globals.node }` + vitest 全局 + `"no-undef": "off"`。

**判据可证伪**（不能只看「现在是绿的」）：往 `src/` 放一个未使用变量，
`npm run lint` 必须报 `@typescript-eslint/no-unused-vars` 且 **exit 1**；删掉后 **exit 0**。

**现在它进了 CI**（job `auth-frontend` 的一步），并且 `Makefile` 的 `check` /
`CONTRIBUTING.md` 的提交前验证也含它。所以「`make check` 通过」现在**包含**这个前端的 lint。



### 2.4 覆盖率基线（KT-GAP-07）

**状态：已采集到基线并设了防回退阈值（2026-10-04）。**

### 基线数字（2026-10-04，CI run `37204939189` 的 `coverage-summary` artifact）

| 指标 | 覆盖 | 分子/分母 |
| --- | ---: | --- |
| lines | **29.36%** | 1486 / 5060 |
| statements | **28.72%** | 1578 / 5493 |
| functions | **25.57%** | 313 / 1224 |
| branches | **21.47%** | 943 / 4391 |

纳入统计的文件 **144 个**（`src/**/*.{ts,tsx}`，排除测试自身、`.d.ts`、`instrumentation.ts`）。

> **这个数字偏低，如实记录、不修饰。** 原因是分母把整个 `src/` 都算进去了——
> 其中包含大量 React 组件与页面，而现有单测以 node 环境下的服务层/纯函数为主。
> 「覆盖率低」在这里的准确含义是「**UI 层没有单测**」，不是「服务层没测」。
> UI 层由 E2E 覆盖（§5，2026-10-04 起已进 CI）。

**阈值（防回退棘轮，不是目标）**：写进 `vitest.config.ts` 的 `coverage.thresholds`，
取值**略低于**上面的基线（留约 1 个百分点余量以免因无关波动报红）：

| 指标 | 阈值 | 基线 |
| --- | ---: | ---: |
| lines | 28 | 29.36 |
| statements | 27 | 28.72 |
| functions | 24 | 25.57 |
| branches | 20 | 21.47 |

**这是「不许掉下去」的门，不是「已经够高」的证明。** 想把阈值往上抬，
先写测试把实际值抬上去，再抬阈值——顺序不能反。

| 项 | 值 |
| --- | --- |
| provider | `@vitest/coverage-v8`，**与 vitest 同版本**（CI 里从 `vitest/package.json` 动态取版本） |
| 配置 | `vitest.config.ts` 的 `coverage`：`provider: v8`、`reporter: text/json-summary/html` |
| 统计范围 | `src/**/*.{ts,tsx}`，排除测试自身、`.d.ts`、`instrumentation.ts` |
| 谁在跑 | CI `quality` job 的 **Collect coverage baseline** 步（每次 push 自然发生） |
| 产物 | `coverage/coverage-summary.json` → CI artifact（保留 14 天） |
| 阈值（棘轮） | lines 28 / statements 27 / functions 24 / branches 20 —— 见上表 |

**为什么 provider 不写进 `package.json`**：本项目 `node_modules` 处于
「与 pnpm store / virtual-store 记录不符」的状态（`node_modules/.modules.yaml` 记的
virtual store 指向一个已不存在的位置），`pnpm add` 与 `npm install` 在本机都会失败，
因此**无法在本地实测基线、也无法本地固化依赖**。与其把它写进 `package.json` 让本地
`pnpm install` 失败，不如让 **CI 承担采集**——CI 每次全新安装，不受本机状态影响。

**阈值怎么定的**：先采到基线（上表），再取略低于基线的整数做棘轮。没有基线的阈值
只会被绕过或被随便调大；有了基线，阈值就只承担「防止悄悄退步」这一件事。

**本地怎么跑**（装好 provider 后）：`pnpm exec vitest run --coverage`。
未装 provider 时报 `MISSING DEPENDENCY`，那是**预期**的，不是配置错误。


### Capture

- 空白正文被拒绝。
- 中文、换行、分号和 URL 原样保存。
- 超长正文被拒绝。
- 合法内容类型被接受，未知枚举被拒绝。
- 编辑生成 Revision。
- 完全相同或仅有可规范化差异的重复保存不增加版本或 Revision。
- expectedVersion 不一致返回冲突。
- 归档和恢复幂等。
- 新建表单默认填入浏览器当前时间，并把本地日期时间转换为 ISO 时点。
- 描述对象或发生时间修改进入 Revision；旧记录迁移后以原创建时间回填发生时间。

### Authentication

- 认证关闭时保持个人本机模式，访问 `/login` 返回首页。
- 认证开启且没有 access token 时，页面跳转登录，受保护 API 返回稳定 JSON 401。
- 登录和刷新只把 access/refresh token 写入 HttpOnly Cookie，响应正文不返回令牌。
- 访问令牌必须由 go-user-system `/users/me` 验证；客户端伪造的身份请求头会被清除并替换。
- 角色必须由 go-user-system `/users/me/authorization` 验证；客户端伪造 `admin` 请求头不能扩大数据范围。
- 管理员可读取全部创建者的内容；普通成员的列表、详情、搜索、分类统计、对象时间线、导出和证据图片可命中本人内容与管理员共享内容，但其他普通成员的私有内容仍不可见。
- 普通成员通过猜测 UUID 调用其他成员的读取或写入接口时，返回不可见/不存在，不泄露资源是否真实存在。
- 认证服务不可用、响应畸形或会话失效时 fail closed，不匿名降级。
- Server Action 与证据图片 Route Handler 独立验证会话，不能只依赖 Proxy。

### Category

- 名称规范化后唯一。
- 大小写和多余空白不会产生重复 Category。
- Capture/Category 重复关联幂等。
- 超过每条 Capture 的 Category 数量限制被拒绝。
- 归档 Category 不能新增关联。
- 空 Category 经二次确认后可以删除；有关联记录（包括已归档记录）的 Category 在界面和服务端都不能删除。

### AI Processing

- Provider 不可用不修改 Capture。
- 超时后 Run 变为 failed。
- 无效 JSON 或 Schema 产生 `AI_RESPONSE_INVALID`。
- 不存在的 Category ID 被拒绝。
- 无法在原文定位的 source_excerpt 不能作为正常语义单元接受。
- Capture 更新后旧 Suggestion 被判定为 stale。
- 已决定 Suggestion 不能再次决定。
- AI 建议永不修改 Capture 正文。
- 主张候选最多 3 个、默认不创建，无法定位来源的候选被过滤。
- 用户可不运行 AI，直接从当前 Capture 版本手动添加主张；来源摘录必须能在当前原文中定位，证伪条件至少 10 字。
- 非法 Claim 状态转换被拒绝。
- 无已采纳 Evidence 时不能提交待审核。
- 私网、回环、保留地址、URL 凭据和非常规端口被来源检查策略阻止。
- 每一跳重定向重新执行网络地址策略，不能跳转到内网。
- 可访问来源保存内容哈希；摘录不匹配时不能采纳 Evidence。
- 未审核 Evidence 编辑后生成旧版本、当前来源检查重置；已审核 Evidence 拒绝编辑和上传。
- 图片声明类型与文件头不一致时拒绝；合法图片落入项目上传目录，并可通过附件 ID 返回正确 MIME 与 `nosniff` 响应头。
- 无链接 Evidence 至少上传一张图片并显式确认后才可人工核验；核验冻结附件哈希，新增图片后旧核验失效且不能采纳。
- AI 审查中的覆盖度和证据平衡由服务端重算，模型伪造的 Evidence ID 被移除。
- 没有已确认采纳证据时，AI 审查必须给出需要更多证据，不能形成事实结论。
- 检索词规范化、有界截断，SQL 通配符按普通字符处理。
- 检索摘录必须包含命中附近上下文且保持长度上限。
- 描述对象既能被普通全文检索命中，也能独立部分匹配筛选。
- 统一检索首次打开时起止日期默认上海时区的今天；显式清空后不自动恢复默认日期，并可检索全部时间。
- 发生日期的结束边界包含当天全部时间，非法日期或反向范围不能误返回结果。

## 3. 数据库集成测试

使用真实 PostgreSQL 测试容器验证：

- 所有 Migration 可以从空库执行。
- Capture 创建事务回滚。
- 幂等键并发写入只产生一条记录。
- 同一创建者、同一导入指纹并发写入只产生一条记录；不同创建者互不去重。
- Revision 版本唯一。
- 乐观锁条件更新。
- Capture/Category 联合唯一约束。
- 接受 AI 分类事务失败时全部回滚。
- 超时 running Run 的清理逻辑。

## 4. Server Action 测试

- 输入通过 Zod 校验后才进入 Service。
- Action 返回稳定 ActionResult，而不是抛出数据库消息到 UI。
- 更新成功后触发正确页面重新验证。
- 并发提交时 UI 能显示冲突并保留用户输入。
- AI 请求进行时重复按钮被禁用，服务端仍能安全处理重复请求。

## 5. 页面和端到端测试

### 5.1 CI 里跑**两次**（2026-10-05 起）

| 运行 | 配置 | 端口 | 覆盖 | 实测（run `37308236690`） |
| --- | --- | --- | --- | --- |
| 无认证 | `playwright.config.ts` | 3000 | 全部 18 spec | `Running 19 tests` → **11 passed / 8 skipped** |
| 有认证 | `playwright.auth.config.ts` | 3100 | 4 个需要账号的 spec | `Running 4 tests` → **4 passed** |

**为什么要拆两次**：18 个 spec 里有 6 个（`category-deletion` / `claim-workflow` /
`knowledge-search` / `similar-captures` / `subject-timeline` / `topic-synthesis`）
**没有登录分支**，直接 `page.goto("/")`。全局打开 `AUTH_ENABLED=true` 会把它们
307 到登录页而**全部变红** —— 那不是「测出了问题」，是**门配错了**。
所以认证态隔离在独立端口上跑，只覆盖真正需要账号的那 4 个。

**两个会让门变脆的坑**（都已处理）：
- 端口必须不同：`reuseExistingServer` 若复用了上一次那个**没有认证**的服务，
  「认证态」就名不副实、等于没测；
- 认证服务的账号登录限流是 `config.yml` 的 `accountLimit: 5 / 15m` 且**没有环境变量覆盖**，
  而登录次数是 6 → CI 里改**运行目录下那份副本**（源文件不动）。

**剩余 8 个 skip 现在各自有明确且互不相同的前置原因**（需要第二个非 admin 账号 /
CC-Switch 代理 / 自建 fixture / 需开启注册），不再是一句含糊的「CI 没有凭据」。

### 5.2 场景

使用 Playwright 覆盖：

### 场景 A：关键词记录

输入：

```text
软件/程序；AI接入管理知识库；输入不确定性，输出结构化和系统化的内容
```

预期：无需标题和分类即可保存，刷新页面后正文一致。

### 场景 B：手动分类

创建“AI 知识管理”Category，将 Capture 关联到该分类。

预期：分类页可以看到该记录，重复关联不产生重复数据。

### 场景 C：AI 整理

使用测试 Provider 返回固定结构化结果。

预期：存在未保存修改时阻止调用并聚焦保存按钮；保存后入口明确显示所分析版本。处理期间显示阶段和耗时；显示标题、摘要、最多 3 个分类和局部原文建议。新分类与局部改写默认不选；勾选时整篇修改前/修改后对比实时更新，只应用用户勾选的局部建议并保留 Revision。采纳后可二次确认整体回退，恢复采纳前内容并新增 Revision；若存在后续修改则安全拒绝。

### 场景 D：AI 失败

测试 Provider 超时。

预期：Run 显示失败，Capture 仍可编辑和分类。

### 场景 E：并发编辑

两个页面打开同一版本并先后提交。

预期：第二次提交显示冲突，不覆盖第一次结果。

### 场景 F：过期建议

AI 基于 v1 生成建议，随后 Capture 更新为 v2。

预期：Suggestion 显示过期，阻止无提示接受。

### 场景 G：永久删除

用户确认删除 Capture。

预期：Capture、Revision、分类关系、AI Run 和 Suggestion 被级联删除；Category 保留；详情链接返回 404。

### 场景 H：候选主张与证据门槛

输入包含“每天复盘能够提高问题处理效率”的记录，使用测试 Provider 生成候选并由用户勾选创建。

预期：候选默认不选；创建后先为 `candidate`；开始调查后提交按钮保持禁用；新 Evidence 显示来源未检查且不能采纳；来源检查成功并匹配摘录后才可采纳；最终只能进入 `ready_for_review`，页面不存在“已验证”操作。

无来源 URL 时上传图片，通过网页打开原图并确认图片与摘录一致。

预期：上传前不能核验；上传后可执行附件人工核验；核验通过后才能采纳；新增第二张图片会使旧核验失效，重新核验冻结两张图片后才能再次采纳并提交待审核。

### 场景 I：不安全来源

输入回环、内网地址或重定向到内网的来源 URL。

预期：检查以稳定错误码失败，不泄露内部响应，不允许采纳，但仍可人工排除该 Evidence。

### 场景 J：人工结论与主张库

对待审核 Claim 选择“现有证据支持”，填写依据和限制。

预期：只有存在支持证据时才能成功；Claim 进入 `concluded`；Review 冻结证据与来源哈希；在主张库中可按 `concluded` 和关键词查到；重新调查后旧 Review 仍可见。

### 场景 K：AI 可靠性审查

对只有一条支持证据的 Claim 使用测试 Provider 运行审查。

预期：按钮显示处理状态；结果显示覆盖有限、证据方向单一和待补反例/独立来源；明确声明不是事实裁决；Claim 状态不变。随后推进 Claim 状态时，旧审查显示输入已变化并要求重新审查。

### 场景 L：统一检索与主题档案

使用同一关键词分别写入 Capture、Claim、Evidence 和 Review，随后执行全部对象检索并限制到某个 Category。

预期：结果按四类分组，显示各自状态和来源 Capture；不属于该 Category 的结果被排除；分类页的记录、主张、有效采纳证据和结论数量与事实表一致，点击结果可以回到完整证据链。

### 场景 M：描述对象和发生时间

创建记录时填写“某公司”为描述对象，并把发生时间改为过去某天上午；正文不包含公司名称。

预期：详情页保存并回显两个字段；普通全文检索公司名称仍能找到记录；清空全文词后，以描述对象部分名称和同一天起止日期组合筛选仍能找到，日期范围之外不能找到。

### 场景 N：相似记录

创建两条描述对象相同、客户投诉处理文字相近的 Capture，再打开第二条记录。

预期：相似记录区出现第一条但不出现当前记录；显示“同一描述对象”和文字相似度原因，点击可回到第一条完整原文，并声明相似不代表真实或已验证。

### 场景 O：对象时间线

为同一描述对象创建两个发生时间不同的 Capture，并让其中一个主张形成人工审核。

预期：对象索引计数正确；时间线严格按发生时间排序，记录时间与审核时间单独显示；每个事件可回到原 Capture。

### 场景 P：AI 主题综合与输入变化

为 Category 创建 Capture，使用本地规则生成并接受主题档案；随后修改 Capture 并保存，再回到 Category。

预期：综合要点和时间脉络都有来源回链；边界声明不允许联网补证或宣告真实；修改后旧档案显示“输入已变化”且不能接受，重新生成后产生新的待决定版本；测试数据可以完整清理。

### 场景 Q：跨身份可靠发布

预置一个由账号 A 形成、含两个独立来源快照的人工结论；账号 B 登录后分别评估为官方来源和专业来源，提交批准型独立复核并发布。

预期：账号 B 不是结论作者；8 项发布门槛全部通过后按钮才启用；发布生成 v1 与 SHA-256，不覆盖结论或证据。发布后修改任一来源权威性评估，旧独立复核显示输入已变化且新发布被阻止，已发布 v1 保持可回看。测试结束永久删除 Capture 时，Release、复核和权威性评估均级联清理且无孤儿版本。

### 场景 R：未来 App 的版本化 API

通过 `/api/v1/captures` 使用 `Idempotency-Key` 创建记录，分页读取并用 `expectedVersion` 修改；读取分类、对象时间线、主张和可靠发布列表，最后使用 `If-Match` 删除。

预期：相同幂等键和请求体只产生一条记录；非法分页参数返回字段错误；旧版本修改和删除返回 `409`；缺少删除版本返回 `428`；响应包含 API 版本、Request ID 和 `private, no-store`；测试数据最终完整清理。

## 6. 安全测试

- 浏览器无法读取服务端环境变量中的 AI API Key；UI 输入的 Key 不会被服务端持久化或记录到日志。
- UI 凭据默认不保存；选择记住时只进入当前标签页的 `sessionStorage`。
- 客户端只能提交白名单内的本地 CC-Switch 地址，不能提交任意远程 Provider URL 或非 `/v1` 路径。
- CC-Switch 健康检查只表示代理可达；“测试当前供应商”必须验证一次小型结构化输出。Codex 与 DeepSeek 切换后都不依赖供应商工具调用，错误响应或不合格 JSON 不得写入 Suggestion。
- Capture 中的 Prompt 注入文本不会触发工具调用或配置变更。
- 日志不包含完整正文、完整 Prompt、API Key 和模型隐藏推理。
- 页面明确显示无应用内鉴权的部署限制。
- 启用认证时验证匿名页面跳转、API 401、登录、刷新轮换、退出与图片访问；浏览器脚本不能读取会话 Cookie。

## 7. 构建和部署验证

- `next build` 成功。
- Docker standalone 镜像可以启动。
- `/api/health/live` 返回成功。
- PostgreSQL 不可用时 `/api/health/ready` 返回失败。
- 空数据库可以自动/手动执行全部 Migration。
- 使用实际 custom-format 备份恢复到隔离临时数据库，确认 Migration 记录和核心表完整，再删除临时库；不得用生产数据库作为首次演练目标。

## 8. P0 发布门槛

- 记录、修订、分类和 AI 建议主流程通过。
- AI 关闭或故障时非 AI 功能完整可用。
- 无已知原文覆盖或并发丢失问题。
- 没有未处理的高危依赖漏洞。
- Docker Compose 在干净环境可启动。
- README 同时说明默认无鉴权边界与 go-user-system 登录的实际能力边界。
