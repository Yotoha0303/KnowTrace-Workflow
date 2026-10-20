# Compose PostgreSQL 备份与恢复演练

该工具用于开发和验收环境，目标是证明**备份可校验、可恢复**。生产环境优先使用托管 PostgreSQL 的自动备份、PITR、加密异地保留和独立恢复实例。

> `ADR-0019` 起，认证库与主应用**同为 PostgreSQL**，但**仍是独立实例、独立库**。
> 备份格式统一为 `pg_dump --format=custom`（与主应用 `scripts/linux/backup-all.sh` 的 `postgres.dump` 同形）。

## 安全边界

- 备份在 PostgreSQL 容器内完成，密码不进宿主机命令行参数（`pg_dump` 走容器内的认证配置）。
- 输出目录 `backups/` 被 Git 忽略。
- 每份 dump 必须同时存在 `.manifest.json`，并校验大小与 SHA-256。
- **dump 是二进制**：`grep` 不可用、非空也**不等于**可解析。校验必须过两道：
  ① `pg_restore --list`（TOC 可解析）② `pg_restore --data-only --file=/dev/null`（**数据块完整**）。
  只做 ① 抓不到**尾部截断**——实测尾部砍 128 字节时 `--list` 仍 exit 0，而真实恢复才报
  「无法从输入文件中读取：文件的结尾」。
- 恢复数据库只能包含字母、数字、下划线并以 `_restore_test` 结尾。
- 恢复必须传入 `-ConfirmRestore`；脚本不会自动删除演练库。
- 工具不执行生产 restore、migration down、PVC 删除或 Secret 轮换。

## 创建备份

先确保 Compose 的认证 PostgreSQL 正在运行。**服务名可配置**：`ADR-0019` 切库前/后容器名不同，
默认 `postgres`（服务内自建 compose）/ `auth-postgres`（统一 compose 切库后），用 `-ComposeService` 覆盖。

```powershell
docker compose ps postgres
powershell -NoProfile -File scripts/ops/backup-postgres.ps1 -ComposeService postgres
```

使用隔离 Compose project 时：

```powershell
powershell -NoProfile -File scripts/ops/backup-postgres.ps1 `
  -ComposeService postgres -ComposeProjectName go-user-system-ops-test
```

输出包含：

```text
backups/go_user_system-<UTC timestamp>.dump
backups/go_user_system-<UTC timestamp>.dump.manifest.json
```

Manifest 记录来源、时间、应用提交、文件名、大小、SHA-256、格式与 compose 服务名，不记录数据库密码或业务行。从 Git checkout 运行时记录当前提交；发布归档或未安装 Git 的主机使用 `application_commit: unknown`，不会影响备份与恢复。

## 恢复演练

```powershell
powershell -NoProfile -File scripts/ops/restore-postgres.ps1 `
  -BackupPath backups/go_user_system-<timestamp>.dump `
  -ComposeService postgres `
  -RestoreDatabase go_user_system_restore_test `
  -ConfirmRestore
```

脚本会：

1. 在 Docker 操作前拒绝不安全数据库名和缺失确认参数。
2. 校验 dump 与 manifest（大小 + SHA-256）。
3. **先验证可解析与数据块完整**（两道），再动任何数据库。
4. `DROP DATABASE IF EXISTS` / `CREATE DATABASE … OWNER` **分两条执行**——psql 的 `-c` 里多语句会被当成隐式事务块，`DROP DATABASE` 会直接报错。
5. 以 `--no-owner --no-privileges --exit-on-error` 恢复。
6. 查询**目标库内**的表数量与 Goose 迁移版本（PG 不支持跨库引用，两个读数都必须连到目标库）。
7. 在 `artifacts/operations/` 写入不含业务数据的 JSON 证据。

使用隔离 project 时，备份与恢复必须传入相同的 `-ComposeProjectName`。

Windows PowerShell 使用 `powershell`；安装 PowerShell 7 的 Windows 或 Linux/macOS 使用 `pwsh`。Makefile 会根据操作系统选择默认命令，也可以通过 `POWERSHELL=<command>` 覆盖。

## 验收

最低验收条件：

- dump 非空，容器与宿主机 SHA-256 一致。
- `pg_restore --list` 与 `pg_restore --data-only --file=/dev/null` 均通过（截断的 dump 必须被拒）。
- 非 `_restore_test` 目标在任何 Docker 操作前被拒绝。
- 恢复数据库表数量大于 0。
- 恢复 migration 版本与源库一致。
- 使用指向恢复库的隔离应用完成登录、刷新、改密和 RBAC 测试；只检查表数量不算完整演练。
- 记录实际耗时，并在不再需要时单独审批清理演练库。

备份文件包含用户与认证状态，必须移入受控、加密存储，不能提交 Git、上传公开 Issue 或作为面试附件。
