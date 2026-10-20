# 2026-10-20 · M4 切库：compose 把认证库从 MySQL 切到 PostgreSQL

> **状态：实施完成与验证回填。**
> 依据：`ADR-0019` §5.2 ②（先在新库上产出并验收可恢复归档，然后才允许改 `compose.yaml`）
> · §5.3（SSOT 收口）· §5.4(a)（卷段）· §5.5（回滚基线）· 施工方案 `M4`。

## 0. 前置（已满足）

| 前置 | 证据 |
| --- | --- |
| 驱动/DSN 已是 PG | `go.mod` 无 mysql 驱动；`pkg/database/db.go` 用 `gorm.io/driver/postgres` |
| 迁移是 PG 方言 | 6 个 goose 文件；CI `go` job 实测 `server_version=18.6` |
| 备份/恢复链已 PG 化 | 分支 `ops/auth-backup-postgres`（M5①②③） |
| `0-2b` 业务级恢复验收 | `2026-10-19` PG 恢复到新库 → 用恢复库起服务 → 密码正确 200 / 错误 401 |

## 1. 目标形态

```text
auth-mysql (mysql:8.0)  ──►  auth-postgres (postgres:18-alpine)
  auth_mysql_data(卷)           auth_postgres_data(普通具名卷，非 external)
  DB_HOST=auth-mysql            DB_HOST=auth-postgres
  DB_PORT=3306                  DB_PORT=5432
  DB_PASSWORD=${AUTH_DB_PASSWORD}  DB_PASSWORD=${AUTH_DB_PASSWORD}
```

## 2. 改动范围

| 文件 | 改动 | 验收判据 |
| --- | --- | --- |
| `compose.yaml` | `auth-mysql` 服务 → `auth-postgres`；`x-auth-database-environment` 的 `DB_HOST`/`DB_PORT`；`auth-migrate` 的 `depends_on`；卷段 `auth_postgres_data` | `Select-String compose.yaml -Pattern "auth-mysql"` 命中为 0 |
| `compose.production.yaml` | 服务名同步（`logging` 锚） | `Select-String compose.production.yaml -Pattern "auth-mysql"` 命中为 0 |
| `Makefile` | `auth-logs` 的服务名；淘汰 `auth-frontend-test` 目标 | `Select-String Makefile -Pattern "auth-mysql\|auth-frontend"` 命中为 0 |
| `deploy/postgres-init/auth-db.sh` | 新增初始化脚本（LF 换行，非超级用户权限分离） | 静态语法门 exit 0，权限 100755 |
| `deploy/rollback/auth-mysql.yaml` | 新增回滚基线（`profiles: ["rollback"]`） | 仅在 rollback profile 生效 |
| `scripts/linux/prepare-host.sh` · `scripts/install.sh` · `scripts/start-all.ps1` | 去掉 `go-user-system_mysql_data` 外部卷；保留 redis 卷 | 外部卷只检测 redis，脚本全链路幂等 |
| `services/go-user-system/config.yml` | `postgres.port: "3306"` → `"5432"`（修复 M2 遗留） | 值 = 5432 |
| `services/go-user-system/compose.yaml` | 自建栈 `mysql:` → `postgres:`；端口 5432；物理清理 `frontend:` 服务块 | `Select-String services/go-user-system/compose.yaml -Pattern "mysql\|frontend"` 命中为 0 |
| `services/go-user-system/deploy/postgres-init/auth-db.sh` | 自建栈初始化脚本（与统一栈一字不差） | 内容一致，权限 100755 |
| `services/go-user-system/k8s/` | `mysql.yaml` → `postgres.yaml`；`configmap.yaml` 键与端口更名；`migration-job.yaml` 方言与 DSN；清理 `frontend` 清单与 ingress 路由 | 清单内无 mysql / frontend 残留 |
| `.github/workflows/auth-e2e-repeat.yml` | `mysql` service → `auth-postgres` (5433:5432)；环境变量与端口对齐 `ci.yml` | 解决 Issue #52 / KT-DEFER-014 |
| `docs/日常运维/运维手册.md` · `docs/24` · `README*.md` | 架构图与描述「MySQL」→「PostgreSQL（认证库）」 | 全局对齐 |

## 3. 凭据模型

PG 的超级用户是实例级的。为避免超级用户与应用角色混淆：
- `POSTGRES_USER: auth_admin`（超级用户，口令 `${AUTH_DB_ROOT_PASSWORD}`，仅用于初始化与运维）
- `go_user_system`（普通角色，口令 `${AUTH_DB_PASSWORD}`，由 `auth-db.sh` 显式创建，为 `go_user_system` 数据库 OWNER）
- 应用容器仅注入普通用户口令 `AUTH_DB_PASSWORD`。

## 4. 卷段（ADR §5.4(a) 裁定）

- `auth_mysql_data`（external 历史卷）彻底废弃。
- 新卷 `auth_postgres_data` 为普通具名卷，与主应用 `knowtrace_workflow_postgres18` 形态一致。
- `auth_redis_data` 保留为 external。

## 5. 回滚方案

- 统一栈中通过 `deploy/rollback/auth-mysql.yaml` 保留了切库前的服务定义，带 `profiles: ["rollback"]`，默认不启动。
- 若需回滚至 MySQL：
  `docker compose -f compose.yaml -f deploy/rollback/auth-mysql.yaml --profile rollback up`
  配合 ADR-0019 §5.5 的回滚步骤恢复 MySQL 数据与配置。
- 观察期结束（M6）后方可物理清理 `deploy/rollback/` 目录。

## 6. 验证与实测结果

| # | 判据 | 验证命令 | 结果 |
| --- | --- | --- | --- |
| V1 | 静态脚本语法门 | `powershell -File tests/ci/static-script-gate.ps1` | **PASS**（受检 54 个文件，失败 0 个） |
| V2 | 根 compose 残留 | `Select-String compose.yaml -Pattern "auth-mysql"` | **0 命中** |
| V3 | 生产 compose 残留 | `Select-String compose.production.yaml -Pattern "auth-mysql"` | **0 命中** |
| V4 | Makefile 残留 | `Select-String Makefile -Pattern "auth-mysql\|auth-frontend"` | **0 命中** |
| V5 | 自建栈 compose 残留 | `Select-String services/go-user-system/compose.yaml -Pattern "mysql\|frontend"` | **0 命中** |
| V6 | k8s 清单残留 | `Select-String services/go-user-system/k8s/* -Pattern "mysql\|frontend"` | **0 命中** |
| V7 | auth-e2e-repeat 修复 | `Select-String .github/workflows/auth-e2e-repeat.yml -Pattern "mysql"` | 仅剩历史变更注释 1 行 |
| V8 | 初始化脚本可执行位 | `git ls-files -s deploy/postgres-init/auth-db.sh` | 模式 `100755`，LF 换行 |

## 7. 边界与说明

1. 本机无 Docker 守护进程，容器编排运行时健康检查及全栈端到端测试依赖 GitHub Actions CI 矩阵（`ci.yml` 与 `auth-e2e-repeat.yml`）。
2. k8s 清单已完成语法与方言升级，待部署目标环境明确（`DEFER-005`）后进行物理集群验证。
