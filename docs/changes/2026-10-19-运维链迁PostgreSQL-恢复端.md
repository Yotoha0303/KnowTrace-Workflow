# 2026-10-19 · M5 运维链迁 PostgreSQL（② 恢复端）

> 依据：`ADR-0019` §5.4(b) · 施工方案 `M5`。承接上一个提交的**生产者**，本提交改**消费者**。
> **不碰**：`compose.yaml` · `compose.production.yaml` · `scripts/install.sh` · `scripts/linux/prepare-host.sh` ·
> `scripts/start-all.ps1` · `services/go-user-system/compose.yaml` · `services/go-user-system/k8s/*`。

## 1. 变动范围

| 文件 | 改动 |
| --- | --- |
| `scripts/linux/verify-restore.sh` | `MYSQL_IMAGE` → `AUTH_POSTGRES_IMAGE`；必需的组件名换新；`mysql_counts_container` → `auth_postgres_counts_container`；临时 MySQL 容器 → 临时认证 PG 容器；输出键 `MYSQL_TABLES` → `AUTH_POSTGRES_TABLES` |
| `services/go-user-system/scripts/ops/restore-mysql.ps1` → `restore-postgres.ps1` | `git mv` + 改写成 PG（`pg_restore --exit-on-error`） |
| `services/go-user-system/Makefile` | `ops-restore-drill` 指向新文件名 |

## 2. 机制 ①「归档强制必需组件」——保留骨架，换名单

`verify-restore.sh` 的 `for required_file in …; [[ -s … ]] || die` **原样保留**（10 项），
只把 `mysql.sql` / `mysql-counts.tsv` 换成 `auth-postgres.dump` / `auth-postgres-counts.tsv`。
镜像预检 `for image_name in …` 同步：`$MYSQL_IMAGE` → `$AUTH_POSTGRES_IMAGE`。

**判据 4 实测**（桩 `docker` + 构造 bundle）：

| 用例 | 结果 |
| --- | --- |
| 名单与备份端产物同名 | `auth-postgres.dump` / `auth-postgres-counts.tsv` **均 MATCH**（名单 10 项，无 `mysql.*` 残留） |
| 完整 bundle | 10 项 `[[ -s ]]` 全过、`sha256sum --check` 全 OK，停在下一道门「本机没有恢复演练所需镜像」（本机无 Docker，预期） |
| 删掉 `auth-postgres.dump` | **EXIT=1** `备份组件缺失或为空: auth-postgres.dump` |
| `auth-postgres-counts.tsv` 置空 | **EXIT=1** `备份组件缺失或为空: auth-postgres-counts.tsv` |

## 3. 恢复路径：与主应用 postgres 段同形

恢复端的认证库段**照抄主应用 postgres 段**（临时容器 → 等 `pg_isready` → `pg_restore --exit-on-error` → 逐表计数 → `cmp`），
只换镜像、库名、用户名与文件名。**逐表计数用的是同一个 `emit_pg_table_counts_sql`**——
备份端与恢复端必须是**同一个程序**，否则 `cmp` 比的不是同一件事。

**为什么认证库单独起一个容器**：`ADR-0019` §4 Option D 未采纳「合并为单一 PG 实例」，
认证库要保持**独立实例、独立库**。演练若把两个 dump 恢复进同一个容器，就绕过了这条隔离假设。

## 4. `restore-postgres.ps1` 里三处 PG 与 MySQL 的语义差（实测踩到）

| # | 现象 | 处置 |
| --- | --- | --- |
| 1 | `psql -c "DROP DATABASE …; CREATE DATABASE …"` → **`DROP DATABASE cannot run inside a transaction block`**（psql 把多语句当隐式事务块） | 拆成**两条** `-Command` |
| 2 | `SELECT … FROM otherdb.public.t` → **`cross-database references are not implemented`** | 「表数」「迁移版本」两个读数**连到目标库**去读，不在维护库上跨库查 |
| 3 | `information_schema.tables` 在维护库上看到的是**维护库自己**的表（实测返回 0，而目标库有 7 张） | 同上：连目标库 |

**这三条都不是推断**：第一条与第二条是实测报错原文，第三条是实测 0 vs 7 的读数差。
**若不测**，`restore-postgres.ps1` 会在第一次真跑时失败在 `DROP`，或更坏——表数读数恒为 0 被当成「恢复失败」。

## 5. 实测（本机 PG 17.11，临时集群 `127.0.0.1:5433`，非 Docker）

| # | 判据 | 结果 |
| --- | --- | --- |
| P1 | `DROP` / `CREATE DATABASE … OWNER` 两条独立执行 | 均 **EXIT=0** |
| P2 | 以库 OWNER（**非超级用户**）`pg_restore --no-owner --exit-on-error` | **EXIT=0** |
| P3 | 表数（连目标库） | **7** |
| P4 | 迁移版本（连目标库，`goose_db_version`） | **6**（与迁移文件数一致） |
| P5 | 逐表行数与源库 `cmp` | **EXIT=0** |
| N1 | 截断 50% 的 dump 真实恢复 | **EXIT=1**「无法从输入文件中读取：文件的结尾」 |
| P6 | 语法 | `bash -n verify-restore.sh` EXIT=0；`restore-postgres.ps1` 解析 OK |

## 6. 边界与未验证项（如实）

- **容器路径未在本机跑过**：本机无 Docker。临时容器、`docker cp`、容器内 `pg_restore` 三层未执行；
  验证的是**同一组命令在 PG 17.11 上的行为**。
- **`pg_restore --no-owner` 以库 OWNER 身份恢复**已实测通过；**以非 OWNER 普通用户**恢复未测
  （生产上恢复用的是 compose 里配置的那个用户，通常是库 OWNER）。
- **`monthly-ops.sh` 的镜像预热仍列 `mysql:8.0`**——属下一个提交（巡检/配置）。
