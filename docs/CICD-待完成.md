# CICD 待完成（只能由「人」或「平台」执行的指令）

> **性质声明（`AGENTS.md` §5）**：本文件是**「待执行指令」**，**不是历史记录**。
> 因此它**必须与仓库实测一致**——与「历史快照不改写」正好相反：
> 判据是「**已发生**」还是「**待做**」。做过的事请从本表**删除**，而不是标成完成。
>
> **它不是台账**：本表的条目**不占** `KT-DEFER-*` / `KT-GAP-*` 编号，也**不进** `docs/14-deferred-issues.md`。
> 台账记「框架/代码自己该做而未做」，本表记「**AI 做不了、只能由人或平台做**」的外部动作。
>
> **本文建立时点**：`2026-10-19`，检出新分支 `ops/auth-backup-postgres`（HEAD `2ac6fc7`）实测。
> **最近校准**：`2026-10-26`，CI/CD 工业级缺口体检后补入 **E6 ~ E11**（来源
> [`changes/2026-10-26-CICD工业级缺口体检.md`](changes/2026-10-26-CICD工业级缺口体检.md)）。

---

## 一、待执行指令

下表**每行只答三件事**：缺什么 / 在哪补 / 谁做。「谁做」只有两个取值：**人** 或 **平台**。

| # | 缺什么 | 在哪补 | 谁做 |
| --- | --- | --- | --- |
| **E1** | M4（`compose.yaml` 切库）合并后、观察期结束前，**定时备份 unit 的启用/禁用**——这个决定没有默认值，且**安装器会自动启用**：`scripts/linux/deploy-observability.sh:135` 无条件 `systemctl enable --now knowtrace-workflow-backup.timer`。M4 之前启用 ⇒ 每天整点 `backup-all.sh` 停在 `Compose 服务未运行: auth-postgres`，**每天都失败一次**；M4 之后不启用 ⇒ 观察期内**没有新的定时备份** | 主机 `systemctl enable --now knowtrace-workflow-backup.timer` / `systemctl disable --now knowtrace-workflow-backup.timer`（单元文件在 `deploy/systemd/knowtrace-workflow-backup.{service,timer}`） | **人** |
| E2 | **认证态 e2e 的一次人工触发运行**。`.github/workflows/auth-e2e-repeat.yml:21-31` 只有 `workflow_dispatch`，`schedule:` 被刻意注释掉，**不会自己跑**。（注：Issue #52 / `KT-DEFER-014` 已在 PR #55 闭环，认证服务段已切为 PostgreSQL 18，前置阻塞已解除，可随时人工触发） | GitHub → Actions → **Auth E2E Repeat** → Run workflow（可改 `repeat`，判据建议 ≥ 5）；判定看产物 `auth-e2e-repeat/result.txt` 的 `clean_pass` 与 `flaky_total`，**有 flaky 就算没过**（第 235–240 行） | **人** |
| **E3** | 已部署主机上的 `EXPECTED_SERVICES` **与仓库模板不一致**。模板现为 `app auth postgres auth-postgres auth-redis`（`scripts/ops/ops.conf.example:97`），而主机真正生效的是 `/etc/knowtrace/ops.conf`，**不受版本控制影响**。模板注释已写明这期间须显式覆盖 | 主机 `/etc/knowtrace/ops.conf`：M4 之前该行应覆盖为仍存在的服务名，M4 之后删掉覆盖 | **人** |
| **E4** | **异地备份链路的运行时凭据**。`scripts/linux/offsite-backup.sh` 要求三样外部状态：`OFFSITE_AGE_RECIPIENT_FILE`（默认 `/etc/knowtrace/age-recipient.pub`，第 62 行）、`OFFSITE_REMOTE`（第 63、107 行）、可用的 `rclone` remote（第 112 行 `rclone lsd`）。三者**都不在仓库里**，且远端账户属外部系统，AI 无法创建或校验 | 主机 `/etc/knowtrace/ops.conf` 与 rclone 配置；age 公钥文件按第 98 行给出的安装命令落到 `OFFSITE_AGE_RECIPIENT_FILE` | **人** |
| **E6** | **`main` 的分支保护 / ruleset**（`ISSUE-S3-027`）。实测 `gh api .../branches/main/protection` → `404 Branch not protected`，`/rulesets` → `[]`。⇒ **CI 不是门禁**：红灯能合、能直推，三种合并策略并存 | Settings → Rules → Rulesets → New branch ruleset（目标 `main`）：① 禁止直推、必须 PR；② **required status checks** = `quality` · `static-script-gate` · `go` · `e2e`；③ *Require branches to be up to date*；④ 禁 force-push / 禁删除。合并策略**收敛为一种** | **人** |
| **E7** | **Secret Scanning 与 Push Protection**（`ISSUE-S3-033`）。本仓 **PUBLIC**，而 `secret_scanning` / `secret_scanning_push_protection` / `..._non_provider_patterns` / `..._validity_checks` **四项全部 `disabled`** | Settings → Code security and analysis → 开启 **Secret scanning** + **Push protection**（建议同开 non-provider patterns 与 validity checks）。开启后**先扫一遍历史**；有泄露则**轮换凭据**，不要只删文件 | **平台** |
| **E8** | **供应链安全门所需的凭据/开关**（`ISSUE-S3-032`）：`dependency-review-action` 无需凭据（走 `GITHUB_TOKEN`），但 **CodeQL 的 `security-events: write`** 与 **Dependabot 新生态（gomod / github-actions / docker）** 需要仓库级启用 | Settings → Code security → 启用 **Code scanning**；`.github/dependabot.yml` 增三个 ecosystem 由仓库内改（**不需外部动作**，仅 CodeQL 的扫描开关需平台启用） | **平台** |
| **E9** | **镜像仓库（registry）**（`ISSUE-S3-031`）。当前镜像只在 VPS 上 `--build` 现场烤，无 registry、无 digest。要落地「不可变 Digest」，需选定一个镜像仓库并给出推送凭据 | 二选一：**GHCR**（`ghcr.io`，复用 `GITHUB_TOKEN`，无需新凭据）或现有 VPS 上的私有 registry。选定后在仓库 Settings → Secrets 增加对应凭据，并在 `.github/workflows/` 增加构建 job | **人** |
| **E10** | **外部探针的告警送达通道**（`ISSUE-S3-036`）。`production-health-check.yml` 每 12h 探活，但三个 workflow **一次都没用过 `secrets.`**，失败只留一个 GitHub 红叉 | 选定通道后加 Secret：`HEALTH_ALERT_WEBHOOK`（Slack/飞书/邮件转发）或改用「失败即开 issue」（需 `permissions: issues: write`）。**通道选哪个是人的决定** | **人** |
| **E11** | **移动端 App 的发布凭据**（`ISSUE-S3-038` / #76）：**Expo 账号 + EAS 项目**，以及（若同时做 iOS）**Apple 开发者账号**；Android 签名 **Keystore** | expo.dev 注册 → `eas init` 建项目；iOS 需 Apple Developer Program（¥688/年）；Keystore 用 `eas credentials` 生成或本地 `keytool`——**生成后必须放 Secret，不得入库** | **人** |

> ⚠️ **E6 ~ E11 是 `2026-10-26` CI/CD 体检新增的**（来源：[`changes/2026-10-26-CICD工业级缺口体检.md`](changes/2026-10-26-CICD工业级缺口体检.md)）。
> **E11 与 `docs/CICD-待完成.md` 的原始用途（CI/CD）边界略宽**——App 发布凭据严格说是
> **产品发布**而非 CI/CD；但它是 #76 里 **A-1 / A-7 两步的硬前置**，不登记会在「P-5 前置」与
> 「谁能做」之间断链。**若你判断它该单列，请告知**——这是 `AGENTS.md` §4.0 判据② 的一类
> （登记位置属于文档组织决定，总控不擅改）。

---

## 二、阻塞关系

**阻塞项单独抽引如下**（`阻塞=否` **不等于**「不必做」——这个区分必须写出来）：

| # | 阻塞别的什么 | 阻塞=是/否 | 说明 |
| --- | --- | --- | --- |
| E1 | **M4 之后的备份连续性** | **是** | 未做决定之前，观察期内是否仍有定时备份**处于未定状态**。至少一种状态（提前启用）会**每天都失败一次**，且失败原因不是备份坏了，而是「切库还没落地」 |
| E2 | **`KT-DEFER-009` 的验收判据**、以及「切库没弄坏认证 e2e」这个结论 | **是** | `KT-DEFER-009` 明写：「在 E2E 进入 CI 之前，本条的验收判据是**有一份人工触发运行的全绿报告并标注人工触发**」。前置 `KT-DEFER-014`（Issue #52）已由 PR #55 闭环（工作流认证服务已切为 PG 18），目前处于就绪待人工触发状态 |
| E3 | **daily 巡检的可信度** | **是** | `EXPECTED_SERVICES` 与实际不符时，巡检会报一个**假的「缺容器」FAIL**；真假故障混在一起，等于巡检读数不可用 |
| E4 | **`ADR-0019` §5.5 异地副本前置**、灾备「密文已离开 VPS」这条结论 | **否**（当前） | 该条**不阻塞** M4 切库：`compose` 切库不依赖异地通道。但在「能否从灾难中恢复」这一级，它仍是硬前置 |
| E5 | **云端证据图片功能**（`ISSUE-S3-024` 的验收） | **是** | 代码已随 `ADR-0020` 落地并合入；**未做 E5 之前，云端上传会以「缺少 `BLOB_READ_WRITE_TOKEN`」失败**——启动日志会明确报出，不再是原来的 `EACCES`。完成 E5 后按 `docs/11-operations.md
| E6 | **`ISSUE-S3-027` ~ `ISSUE-S3-037` 的全部修复**（11 条） | **是** | **这是最关键的一条**：没有 required check，其余所有门（覆盖率地板 / 静态脚本 / 备份判据 / Go 见证门 / e2e）**都只跑不拦**。先做 E6，其余修复才有强制力 |
| E7 | **`ISSUE-S3-033`**（Secret Scanning）；间接支撑 `AGENTS.md` §5「推送前必做 1 · 敏感值扫描」 | **是** | 该条目前是**纯提示词约束**。本仓为 PUBLIC 且有明文凭证史（`.env.local` / `client_secret_*.json` / `邮箱授权码.txt`），靠人记性守门 |
| E8 | **`ISSUE-S3-032`**（供应链安全门） | **是** | Code scanning 未启用 ⇒ 即使把 `codeql.yml` 迁到根目录，`security-events: write` 也无处可写 |
| E9 | **`ISSUE-S3-031`**（镜像 digest）与 `AGENTS.md` §2 **04 构建环**准出 | **是** | 没有 registry 就没有 digest，「不可变镜像」这条准出**无法满足**；连带 `ISSUE-S3-029`（版本号）也没有可挂载的产物 |
| E10 | **`ISSUE-S3-036`**（外部探针告警）；间接影响 `AGENTS.md` §2 **06 观测环** | **是** | 没有送达通道，外部探针的失败与不存在同形 |
| E11 | **`ISSUE-S3-038` / #76 的 A-1 与 A-7 两步**（建工程 / 出 APK） | **是** | 无 Expo 账号 ⇒ 无法 `eas init`；无 Keystore ⇒ 无法出可安装的签名 APK。**不阻塞 A-2 ~ A-6 的本地开发**（`expo start` 不需要账号） |` §7.1 第 4 条做 >4.5 MB 的判别实测 |

> ⚠️ **E4 的「阻塞=否」的含义**：它**不是**「可以不做」。按 `AGENTS.md` §5 的口径，
> `阻塞=否` 只说明它**不挡当前这一步**；「不必做」与「现在做」是两个不同的判断。

---

## 三、本表不收的东西（边界）

| 内容 | 为什么不在本表 |
| --- | --- |
| `compose.yaml` 仍指向 `auth-mysql` | 这是**仓库里的代码/配置**，AI 能改——属 M4 的范围，不是「只能由人做」 |
| `.github/workflows/auth-e2e-repeat.yml` 里的 `mysql:8.0` service 定义 | **已闭环**：PR #55 已将其替换为 `postgres:18-alpine`（ADR-0019 M4 / Issue #52），与 `ci.yml` 对齐，`KT-DEFER-014` 解决 |
| `services/go-user-system/k8s/` 与 `Makefile` 的 MySQL 引用 | 仓库内文件，且被「部署目标未定」阻塞——已登记为 `KT-DEFER-011` 第 2–3 条 |
| 任何 `GAP-` / `DEFER-` 编号的缺口 | 它们是「框架/代码自身该做而未做」，去 `docs/14-deferred-issues.md` |

---

## 四、维护规则

1. **做过就从表里删**——本表是「待做」，不是「做过」。删掉时在对应 `docs/changes/` 记录里留一句指向。
2. **新增前先看「谁做」**：若这件事 AI 能做（改文件、跑命令、开 PR），**不要进本表**。
3. **不得在此写会变的实测数字**——要写就写**可复跑的命令**，或指向台账里的编号。
4. 本表的「在哪补」必须写到**具体文件或具体入口**；写「在某处配置」等于没写。
