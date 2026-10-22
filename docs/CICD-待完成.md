# CICD 待完成（只能由「人」或「平台」执行的指令）

> **性质声明（`AGENTS.md` §5）**：本文件是**「待执行指令」**，**不是历史记录**。
> 因此它**必须与仓库实测一致**——与「历史快照不改写」正好相反：
> 判据是「**已发生**」还是「**待做**」。做过的事请从本表**删除**，而不是标成完成。
>
> **它不是台账**：本表的条目**不占** `KT-DEFER-*` / `KT-GAP-*` 编号，也**不进** `docs/14-deferred-issues.md`。
> 台账记「框架/代码自己该做而未做」，本表记「**AI 做不了、只能由人或平台做**」的外部动作。
>
> **本文建立时点**：`2026-10-19`，检出新分支 `ops/auth-backup-postgres`（HEAD `2ac6fc7`）实测。
> **最近校准**：`2026-10-20`，PR #55 闭环 Issue #52 / KT-DEFER-014，更新 E2 前置状态。

---

## 一、待执行指令

下表**每行只答三件事**：缺什么 / 在哪补 / 谁做。「谁做」只有两个取值：**人** 或 **平台**。

| # | 缺什么 | 在哪补 | 谁做 |
| --- | --- | --- | --- |
| **E1** | M4（`compose.yaml` 切库）合并后、观察期结束前，**定时备份 unit 的启用/禁用**——这个决定没有默认值，且**安装器会自动启用**：`scripts/linux/deploy-observability.sh:135` 无条件 `systemctl enable --now knowtrace-workflow-backup.timer`。M4 之前启用 ⇒ 每天整点 `backup-all.sh` 停在 `Compose 服务未运行: auth-postgres`，**每天都失败一次**；M4 之后不启用 ⇒ 观察期内**没有新的定时备份** | 主机 `systemctl enable --now knowtrace-workflow-backup.timer` / `systemctl disable --now knowtrace-workflow-backup.timer`（单元文件在 `deploy/systemd/knowtrace-workflow-backup.{service,timer}`） | **人** |
| E2 | **认证态 e2e 的一次人工触发运行**。`.github/workflows/auth-e2e-repeat.yml:21-31` 只有 `workflow_dispatch`，`schedule:` 被刻意注释掉，**不会自己跑**。（注：Issue #52 / `KT-DEFER-014` 已在 PR #55 闭环，认证服务段已切为 PostgreSQL 18，前置阻塞已解除，可随时人工触发） | GitHub → Actions → **Auth E2E Repeat** → Run workflow（可改 `repeat`，判据建议 ≥ 5）；判定看产物 `auth-e2e-repeat/result.txt` 的 `clean_pass` 与 `flaky_total`，**有 flaky 就算没过**（第 235–240 行） | **人** |
| **E3** | 已部署主机上的 `EXPECTED_SERVICES` **与仓库模板不一致**。模板现为 `app auth postgres auth-postgres auth-redis`（`scripts/ops/ops.conf.example:97`），而主机真正生效的是 `/etc/knowtrace/ops.conf`，**不受版本控制影响**。模板注释已写明这期间须显式覆盖 | 主机 `/etc/knowtrace/ops.conf`：M4 之前该行应覆盖为仍存在的服务名，M4 之后删掉覆盖 | **人** |
| **E4** | **异地备份链路的运行时凭据**。`scripts/linux/offsite-backup.sh` 要求三样外部状态：`OFFSITE_AGE_RECIPIENT_FILE`（默认 `/etc/knowtrace/age-recipient.pub`，第 62 行）、`OFFSITE_REMOTE`（第 63、107 行）、可用的 `rclone` remote（第 112 行 `rclone lsd`）。三者**都不在仓库里**，且远端账户属外部系统，AI 无法创建或校验 | 主机 `/etc/knowtrace/ops.conf` 与 rclone 配置；age 公钥文件按第 98 行给出的安装命令落到 `OFFSITE_AGE_RECIPIENT_FILE` | **人** |
| **E5** | **Vercel 项目上的 Blob 存储与凭据**（`ADR-0020` / `ISSUE-S3-024`）。**2026-10-22 实测更新**：存储已用 **OIDC 连接**（注入 `BLOB_STORE_ID`），但**代码此前只认静态 token**，导致驱动误判并回落进只读文件系统——该误判已修复（OIDC 现被识别，服务端读写可用）。**仍缺的一步（可选，决定单张上限）**：注入 `BLOB_READ_WRITE_TOKEN`，使**浏览器直传**可用、单张可达 10 MB；不注入则走服务端写入，单张上限 4.5 MB（平台限制） | Vercel 项目 → Storage → Blob → 复制读写令牌 → 项目 Settings → Environment Variables 增加 `BLOB_READ_WRITE_TOKEN` → Redeploy。另确认 `EVIDENCE_IMAGE_BLOB_ACCESS=private`（默认即为 private，**不要改成 public**——证据图片是用户隐私数据） | **平台** |

---

## 二、阻塞关系

**阻塞项单独抽引如下**（`阻塞=否` **不等于**「不必做」——这个区分必须写出来）：

| # | 阻塞别的什么 | 阻塞=是/否 | 说明 |
| --- | --- | --- | --- |
| E1 | **M4 之后的备份连续性** | **是** | 未做决定之前，观察期内是否仍有定时备份**处于未定状态**。至少一种状态（提前启用）会**每天都失败一次**，且失败原因不是备份坏了，而是「切库还没落地」 |
| E2 | **`KT-DEFER-009` 的验收判据**、以及「切库没弄坏认证 e2e」这个结论 | **是** | `KT-DEFER-009` 明写：「在 E2E 进入 CI 之前，本条的验收判据是**有一份人工触发运行的全绿报告并标注人工触发**」。前置 `KT-DEFER-014`（Issue #52）已由 PR #55 闭环（工作流认证服务已切为 PG 18），目前处于就绪待人工触发状态 |
| E3 | **daily 巡检的可信度** | **是** | `EXPECTED_SERVICES` 与实际不符时，巡检会报一个**假的「缺容器」FAIL**；真假故障混在一起，等于巡检读数不可用 |
| E4 | **`ADR-0019` §5.5 异地副本前置**、灾备「密文已离开 VPS」这条结论 | **否**（当前） | 该条**不阻塞** M4 切库：`compose` 切库不依赖异地通道。但在「能否从灾难中恢复」这一级，它仍是硬前置 |
| E5 | **云端证据图片功能**（`ISSUE-S3-024` 的验收） | **是** | 代码已随 `ADR-0020` 落地并合入；**未做 E5 之前，云端上传会以「缺少 `BLOB_READ_WRITE_TOKEN`」失败**——启动日志会明确报出，不再是原来的 `EACCES`。完成 E5 后按 `docs/11-operations.md` §7.1 第 4 条做 >4.5 MB 的判别实测 |

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
