# 2026-10-19 · go-user-system 驱动与测试基建迁到 PostgreSQL（M2 + M3）

> 依据：`docs/adr/0019-auth-db-postgres.md`（`accepted`）第 3 / 4 / 7 步。
> 本记录覆盖**同一个 PR** 的两半：M2（应用侧驱动与 DSN）与 M3（`internal/testutil` 及其调用方 + CI 两道门）。
> 两半**合并为一个提交**：单独存在时各是一条"看起来对"的中间态——M2 之后集成测仍连 MySQL，
> M3 之后 CI 仍起 MySQL service，任一单独合入都会让 CI 的绿色继续代表 MySQL 方言。

## 1. 变动范围

| 文件 | 改动 | 归属 |
| --- | --- | --- |
| `pkg/database/db.go` · `migration.go` | GORM 驱动与迁移路径改为 PG（`pgx` stdlib + URL DSN，`timezone=UTC`） | M2 |
| `config/config.go` · `config.yml` · `cmd/main.go` | 配置与 goose dialect 改 PG | M2 |
| `internal/testutil/postgres.go` | **新增**（原 `mysql.go` 删除）：PG 建表 / `current_database()` / `server_version` / `pg_try_advisory_lock` | M3 |
| `internal/testutil/postgres_test.go` | 由 `mysql_test.go` **重命名**；fake driver 与断言改 PG | M3 |
| `internal/dao/user_integration_test.go` · `internal/service/auth_integration_test.go` · `internal/service/user_test.go` | 调用方改 `OpenTestDB` / `CloseTestDB` | M3 |
| `pkg/database/db_test.go` | 默认 opener 的失败用例改 PG URL；函数名去 MySQL | M3 |
| `scripts/check-go-integration-server-witness.mjs` | 见证机制由 `mysql.general_log` 换为 `pg_stat_database.sessions` **差值** | M3 |
| `scripts/check-go-integration-gate.mjs` | 仅措辞：去掉 MySQL 表述，指向新见证机制（判据本身不变） | M3 |
| `.github/workflows/ci.yml`（`go` job） | `services.mysql` → `services.postgres:18-alpine`；DSN 改 PG；prepare / assert 两步改 PG | M3 |
| `.gitignore` | 新增 `.go-integration-witness-baseline.json`（见证基线，运行态产物） | M3 |

**不碰**：`migrations/`（PR #45 已做）、`main` 分支、`e2e` job（仍用 MySQL，见 §7）。

## 2. 依据（实测，非推断）

1. **函数改名的影响面：40 处引用**（`grep -rn "OpenMySQL\|CloseMySQL\|openMySQLDB" --include=*.go .`）。
   逐文件分布：`internal/testutil/mysql_test.go` 31 处、`internal/dao/user_integration_test.go` 2 处、
   `internal/service/auth_integration_test.go` 2 处、`internal/service/user_test.go` 2 处、
   `pkg/database/db_test.go` 1 处（那是 `TestDefaultOpenMySQL...` 的**名字**，调用的是另一种 API）、
   以及 `postgres.go` 注释里 2 处自指。
2. **fake 方言必须跟着换**：`gorm.Open(mysql.New(...))` 造出来的 `*gorm.DB` 在 PG 迁移后仍能 PASS，
   但它的 PASS 不再说明「PG 方言下这条路径能走通」。四处 fake 全部改为 `postgres.New`（`Conn` + `DisableAutomaticPing`，不探测版本、不连接）。
3. **PG 的 `server_version` 是两段**（本机 `17.11`）：`postgres.go` 的正则 `^\d+\.\d+(\.\d+)?` 与之匹配；
   fake driver 的兜底答案 `"0"`（单段）被拒——`TestBuildRealDBFingerprintRejectsFakeConnection` 因此仍成立。
   `TestIsRealDBFingerprint` 的表已改为 PG 版本形态（含「单段必须被拒」一条）。
4. **`sessions` 的语义（本机 PG 17.11 实测）**：每次真实连接 +1（连 2 次 → +2）；
   `pg_isready` 探活 **+0**（不建会话）；`pg_stat_database` 对被测库之外的连接**不计入**。
   因此见证判据用**差值**，且脚本自己连维护库 `postgres`，避免读数给被测库加会话。

## 3. 改动方案（关键决策）

- **`OpenMySQL` → `OpenTestDB`**：库已不是 MySQL，保留旧名会让读者以为驱动还是 mysql。
- **`pg_try_advisory_lock` 不是 `GET_LOCK`**：MySQL 返回 1/0/NULL，PG 返回 **boolean 且不等待**。
  照抄 `!= 1` 会让判据永远为真。`acquireIntegrationLock` 用 `pg_try_advisory_lock(hashtext(?))` + 显式重试 30 秒。
- **`SET FOREIGN_KEY_CHECKS=0/1` 直接删除**：本 schema 无外键（`migrations/` 里 `REFERENCES` = 0 处）；
  PG 的等价物 `session_replication_role` 需超级用户。没有外键就没有要绕过的检查。
- **`quoteIdentifier` 改双引号**（原反引号是 ADR §3.3「3 条」之外的第 4 条 PG 不存在构造）。
- **服务端见证门新机制**（见 §4）：`pg_stat_database.sessions` 的**差值** + `stats_reset` 不变。
  测试进程伪造不了：该计数**没有写入接口**，只能靠真实建连增长；清零需超级用户，且会被 `stats_reset` 比对抓住。
- **`auth_integration_test.go` 的 token_hash 改用 SHA-256 十六进制**：见 §5 的实测发现。

## 4. 服务端见证门：新机制与理由

| 项 | 旧（MySQL） | 新（PostgreSQL） |
| --- | --- | --- |
| 读什么 | `mysql.general_log`（连接与语句日志） | `pg_stat_database.sessions`（PG 14+ 累计会话数） |
| 判据 | 满足启动序列（GET_LOCK / DATABASE() / VERSION()）的连接数 ≥ 8 | 测试前后 **Δsessions ≥ 8** |
| 前置 | `--prepare` 打开并清空 general_log | `--prepare` 记基线到 `.go-integration-witness-baseline.json` |
| 防清零 | （general_log 由 root 控制） | 比对 `stats_reset`，两次读数之间变化即判不通过 |
| 凭据 | `MYSQL_PWD` | `PGPASSWORD` |

**为什么换了机制而不是照搬**：PG 没有 `general_log` 这种可开关的语句日志表；
`log_statement` 要改服务端配置且只写文件；`pg_stat_statements` 需要扩展且对 app 账户的可见性依赖配置。
`sessions` 是**默认就有、默认可读、谁都不能写**的服务端计数——攻击面比 general_log 更小。

**如实声明的弱化**：旧门要求「连接上执行过 OpenMySQL 的启动序列」，新门只要求「连接发生过」。
新门**不能**区分「testutil 连的」与「别的进程连的」——它证明的是「有 N 次真实连接」，
与第一道门（测试进程自称连过）互为交叉证据。这一点已写进脚本头注释。

## 5. 验收（可判定）与**执行结果**

| # | 判据 | 命令 | 实测结果 |
| --- | --- | --- | --- |
| P1 | 构建 / 静态检查 | `go build ./...` · `go vet ./...` | 均 exit 0 |
| P2 | 无 DSN ⇒ 全绿、集成测 SKIP | `go test ./... -count=1`（不设 `TEST_DATABASE_DSN`） | **exit 0**，全部 ok |
| P3 | **带 PG DSN ⇒ 8 条集成测真跑并 PASS** | `TEST_DATABASE_DSN=postgres://…/go_user_system_test?sslmode=disable&timezone=UTC go test ./... -count=1 -json` | **exit 0**；日志门：带指纹的顶层集成 PASS **8** 个 |
| P4 | 服务端见证：Δsessions ≥ 8 | `node scripts/check-go-integration-server-witness.mjs --database go_user_system_test --min-new-sessions 8` | **Δ=9**，exit 0 |
| N1 | DSN 指向**不存在**的库 ⇒ **Fatal，不是 SKIP** | `TEST_DATABASE_DSN=…/go_user_system_does_not_exist… go test ./internal/dao -run Integration -v` | **FAIL**（3 条均 `open test postgres failed … SQLSTATE 3D000`），exit 1 |
| N2 | 不连库（无 DSN，只跑单元测）⇒ 见证门必须红 | 先 `--prepare`，再 `go test ./...`（不设 DSN），再判定 | `go test` **exit 0** 而见证门 **Δ=0 ⇒ exit 1** |
| N3 | 只跑 fake 用例（`TestAcquireIntegrationLockSucceeds`）⇒ 测试 PASS 但见证门必须红 | `go test ./internal/testutil -run TestAcquireIntegrationLockSucceeds -v` 后判定 | 测试 `PASS`，见证门 **Δ=0 ⇒ exit 1** |
| N4 | 篡改基线里的 `stats_reset` ⇒ 判「统计被重置」 | 改基线 JSON 后判定 | exit 1（`stats_reset … → never`） |
| N5 | 无 `PGPASSWORD` ⇒ fail-closed | 判定 | exit 1 |
| N6 | `--prepare` 指向不存在的库 ⇒ 拒绝 | 判定 | exit 1 |
| N7 | 维护库 == 被测库 ⇒ 用法错误 | `--maintenance-database <被测库>` | exit 2 |

**过程中发现并修掉的两处真实问题**：

1. **PG 的 `char(64)` 与 MySQL 的 `CHAR(64)` 读回语义相反**：PG 读出时**补空格**到 n 位，
   MySQL 读出时**截掉**尾部空格。集成测用 `"old-hash"`（9 位）写入 `token_hash char(64)`，
   PG 读回是 `"old-hash"` + 55 个空格 ≠ 入参 ⇒ `RotateRefreshToken` 走 `ErrRefreshTokenInvalid`，
   并发刷新用例两条请求**都**失败（MySQL 上它是绿的）。改成真实的 SHA-256 十六进制（恰好 64 位，
   与生产 `auth/token_manager.go:252` 一致）。**这是迁移暴露的真实差异，不是测试写得松**。
2. 见证脚本自身两处：`psql` 端口参数是 `-p`（`-P` 是 `\pset`）；`-tA` 的默认字段分隔符是 `|` 而非 TAB。
   两者都被 fail-closed 路径当场抓住（报错退出 1，而不是静默通过）。

## 6. 回滚

单提交可整体 `git revert`。回滚后：驱动回 MySQL、`testutil` 回 `OpenMySQL`、CI service 回 `mysql:8.0`、
见证门回 `general_log` 版本（本提交前的文件在 git 历史里）。**迁移文件不在本提交范围内**，回滚不影响它们。

## 7. 边界与未验证项（如实）

- **CI 的 service 形态本机无法验证**：本机无 Docker。`services.postgres:18-alpine`、
  `pg_isready` 健康检查参数、`PGPASSWORD: knowtrace` 的权限（能否读 `pg_stat_database`）**均未在 CI 跑过**。
  本机验证用的是 **PG 17.11**，CI 是 **18**。
- **`e2e` job 仍是 MySQL**（`ci.yml` 同文件内 `services.mysql`，`DB_PORT: 3306`，健康检查 `mysqladmin`）。
  M2 已把 `go run ./cmd migrate up` 改成 PG 驱动，该 job 的迁移步会因此失败——**属 M5「compose / k8s / CI」范围**，
  本次未改，需在 M5 一并切换。**不要把本 job 的绿色当成 e2e 的绿色。**
- **`variance`：`go test` 的包级并行会让 Δsessions 略小于「单包串行之和」**——本次实测 Δ=9（8 条集成用例 9 条会话，
  其中 1 条来自 `cmd` 包的 bootstrap 集成测）。下界 8 与实测 9 之间只有 1 的余量；
  若将来该用例被 skip，Δ 可能降到 8 仍绿而日志门会红（两道门互补）。这一余量**偏紧**，已在 GAP 中登记（见交付说明）。
- **`pkg/database/migration_test.go` 仍把 `DB_HOST` 写成 `"mysql"`**：那是测试夹具里的任意值，不涉方言，故未改。

## 8. 执行结果（回填）

见 §5 表格的「实测结果」列——全部为本次在 `feat/auth-migrations-pg` 工作树上跑出的真实 stdout。
时间：`2026-10-19T06:44Z`（prepare 基线）至 `2026-10-19T07:05Z`（N8 收尾）。
