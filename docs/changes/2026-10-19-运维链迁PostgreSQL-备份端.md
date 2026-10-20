# 2026-10-19 · M5 运维链迁 PostgreSQL（① 备份端）

> 依据：`ADR-0019` §5.4(b)（备份/恢复链「必须同一变更改完」）· 施工方案 `M5`。
> 范围：**只改备份的「生产端」**——恢复端（`verify-restore.sh` / `restore-mysql.ps1`）与巡检/配置在后续两个提交。
> **不碰**：`compose.yaml` · `compose.production.yaml` · `scripts/install.sh` · `scripts/linux/prepare-host.sh` ·
> `scripts/start-all.ps1` · `services/go-user-system/compose.yaml` · `services/go-user-system/k8s/*`（部署目标未定，见 `docs/09-delivery-plan.md` §8 与 `KT-DEFER-011` 第 2–3 条）。

## 1. 变动范围

| 文件 | 改动 |
| --- | --- |
| `scripts/linux/backup-all.sh` | `mysql_counts()` + `mysqldump` → 复用主应用的逐表计数程序 + `pg_dump --format=custom`；服务名/库名/镜像可配置；metadata 键改名 |
| `scripts/backup-auth.ps1` | 四步校验（执行 → 容器内 sha256 → cp → 主机 sha256）**保留**，前面**新增两道可解析性校验** |
| `scripts/backup-all.ps1` | 一行输出文案 |
| `services/go-user-system/scripts/ops/backup-mysql.ps1` → `backup-postgres.ps1` | `git mv` + 改写成 PG（同样的两道校验） |
| `services/go-user-system/Makefile` | `ops-backup` / `ops-restore-drill` 指向新文件名 |

## 2. 归档组件改名（**备份端与恢复端必须同名**）

| 旧 | 新 |
| --- | --- |
| `mysql.sql` | `auth-postgres.dump`（`pg_dump --format=custom`） |
| `mysql-counts.tsv` | `auth-postgres-counts.tsv` |
| metadata `mysql_image=mysql:8.0` | `auth_postgres_image=postgres:18-alpine` |

**为什么加 `auth-` 前缀**：归档里已有主应用的 `postgres.dump` / `postgres-counts.tsv`；
不加前缀，两个 PG 库的组件在同一目录里同名，恢复端只能覆盖或改名——两种都是静默错。

**为什么用 custom 格式而不是 `pg_dump` 的纯 SQL**：与主应用 `postgres.dump` 同形，
恢复端可复用同一条 `pg_restore` 路径；且 custom 格式可被 `pg_restore --list` 校验。

## 3. 两条「必须保留、但校验器必须换」的机制之 ①：归档强制必需组件

`verify-restore.sh:74-86` 的 `required_file` 名单**保留**，名单内容在恢复端提交里随之改名；
本提交保证**生产者真的产出这两个文件**，否则演练永远不能通过。

## 4. 两条「必须保留、但校验器必须换」的机制之 ②：四步校验

四步**原样保留**，但 custom 格式是二进制，`grep` 不可用、`-s` 只挡 0 字节。
故在「执行 dump」与「容器内 sha256」之间插入**两道**校验，**都在容器内**：

| 校验 | 命令 | 抓住什么 |
| --- | --- | --- |
| ① TOC 可解析 | `pg_restore --list <dump>` | 头部截断 / 非 dump 文件 |
| ② 数据块完整 | `pg_restore --data-only --file=/dev/null <dump>` | **尾部截断** |

**第 ② 道是实测逼出来的**，不是设计时想到的：见 §5 的 `trunc tail-128B` 一行——
`pg_restore --list` 在尾部被砍 128 字节时**仍然 exit 0**（它只读 TOC），
而真实恢复报「无法从输入文件中读取：文件的结尾」。
**只做第 ① 道，四步校验对尾部截断依然全绿。**
第 ② 道**不连数据库**（实测：`PGHOST=127.0.0.1 PGPORT=1` 下仍是 0/1），所以可在容器内安全执行。

## 5. 实测（本机 PG 17.11，临时集群 `127.0.0.1:5433`，非 Docker）

**夹具**：认证库 6 张业务表 + `goose_db_version`；3 users（含中文昵称）、2 tokens、2 roles、3 permissions。

| # | 判据 | 结果 |
| --- | --- | --- |
| P1 | 逐表计数（与 `auth_postgres_counts` 同样的 psql 参数） | 7 行，`public.users 3` 等，与源库一致 |
| P2 | `pg_dump -Fc` → `pg_restore --list` | dump 10825 B，`--list` **EXIT=0**，TOC 47 行 |
| P3 | 完整 dump → 新库恢复 → 逐表行数 `cmp` | `pg_restore` **EXIT=0**；`cmp` **EXIT=0** |
| N1 | 截断到 90% / 50% / 10% | `--list` **EXIT=1**；`[-s]` **放行**（证明「非空 ≠ 可解析」） |
| N2 | **尾部截断 128 B** | `--list` **EXIT=0**（盲区）→ 靠第 ② 道：`--data-only -f /dev/null` **EXIT=1** |
| N3 | 截断 dump 做真实恢复（`--exit-on-error`） | **EXIT=1**「无法从输入文件中读取：文件的结尾」 |
| P4 | stdout 重定向形态（`backup-all.sh` 用 `> file`） | 10825 B，`pg_restore --list < dump` **EXIT=0** |
| P5 | 第 ② 道不连库 | `PGHOST=127.0.0.1 PGPORT=1`：完整 dump **EXIT=0**，尾部截断 **EXIT=1** |
| P6 | 语法 | `bash -n backup-all.sh` EXIT=0；3 个 `.ps1` 解析器校验 OK |

## 6. 边界与未验证项（如实）

- **容器路径未在本机跑过**：本机无 Docker，`docker compose exec` / `docker compose cp` 那两层未执行。
  实际验证的是**同一组 `pg_dump` / `pg_restore` 命令在 PG 17.11 上的行为**，不是 compose 编排。
- **CI 是 PG 18，本机是 17.11**（与 M2/M3 同一处已知差异）。
- **合并顺序有耦合**：本脚本要求认证库已是 PostgreSQL。在 `compose.yaml` 切库（M4）**之前**合并本提交，
  `backup-all.sh` 会停在 `Compose 服务未运行: auth-postgres` —— **有意失败**，不是回归。
  建议顺序：本分支与 M4 一并合入，或合入后**不启用**定时备份直至 M4 完成。
- **`monthly-ops.sh` 的镜像预热与本提交不同步**：它仍在等 `mysql:8.0`。属后续提交（巡检/配置）。

## 7. 回滚

> 本节为 `docs/changes/README.md:38` 要求的「回滚」项，由三跳链裁决（`2026-10-19`）补登；
> **本提交未执行回滚**，下列步骤在执行时须留实测输出。

- **单独 revert 本提交（`2e019b5`）只在 compose 仍是 `auth-mysql` 时成立**：脚本退回
  `mysql_counts()` + `mysqldump --single-transaction`，归档组件名退回 `mysql.sql` / `mysql-counts.tsv`。
  M4 切库之后 revert，`backup-all.sh` 会停在 `Compose 服务未运行: auth-mysql`——**`die`，会响**。
- **正确的回滚单元是 M5 整批（`2e019b5..2ac6fc7`），不是单个提交**：备份端产出 `auth-postgres.dump` /
  `auth-postgres-counts.tsv`，恢复端（`7ca4c84`）按这两个名字做 `required_file` 检查（`verify-restore.sh:83-84`）。
  只回滚备份端 ⇒ 恢复端 `die "备份组件缺失或为空: auth-postgres.dump"`，同样是**会响的失败**，不是静默。
- **回滚后必须做**：连续跑两次 `backup-all.sh`（第二次验证不改状态），再跑一次 `verify-restore.sh`
  并确认输出 `RESTORE_VERIFY=PASS` 与 `MYSQL_TABLES=…`。**退出码 0 不算验收**（`docs/changes/README.md` 第 4 条）。
- **不可逆项**：无。本提交不删既有归档、不改 `compose.yaml`、不写数据库；`backup-mysql.ps1 → backup-postgres.ps1`
  的改名由 `git mv` 承载，revert 恢复原名与旧内容。
