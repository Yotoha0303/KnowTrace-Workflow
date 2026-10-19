# 2026-10-19 · M5 运维链迁 PostgreSQL（③ 巡检 / 配置 / 文档）

> 依据：`ADR-0019` §5.4(c) 的「巡检 / 监控 / 文档点位」清单 · 施工方案 `M5`。
> 承接 ①（备份端）、②（恢复端）。本提交只动**运维脚本与示例配置**。

## 1. 变动范围

| 文件 | 改动 | 失效形态（ADR 原文） |
| --- | --- | --- |
| `scripts/ops/ops.conf.example:95` | `EXPECTED_SERVICES` 的 `auth-mysql` → `auth-postgres` | 会响（`KnowTraceOpsCheckFailed`），但与真故障混淆 |
| `scripts/ops/scripts/daily-check.sh:350` | 同上（内建默认值） | 同上 |
| `scripts/ops/scripts/daily-ops.sh:257` | 同上 | 同上 |
| `scripts/ops/scripts/log_analyzer.py:409` | 同上 | 日志分析会静默地不看认证容器 |
| `scripts/ops/scripts/log_analyzer.py:79` | 脱敏正则补 `pgpassword` | **不响**：`PGPASSWORD=…` 不进键名拦截 |
| `scripts/ops/scripts/monthly-ops.sh:352` | 镜像预热去掉 `mysql:8.0`（与主应用同镜像） | 演练在「文件缺失」态下继续 |
| `scripts/ops/scripts/monthly-ops.sh:339` | 注释 + **显式声明阈值未重算** | 阈值不重算 ⇒ **不响** |
| `scripts/ops/scripts/security-check.sh:388` | `MYSQL_ROOT_PASSWORD` → `AUTH_DB_ROOT_PASSWORD` + `AUTH_DB_PASSWORD` | **不响**：查旧键、不查新键 = 静默少一道防线 |
| `scripts/ops/lib/ops-common.sh:333` | 注释里的命名假设 | **不响**：靠「`auth` 不误配 `auth-mysql`」的命名假设 |
| `services/go-user-system/.env.goose.example` | `GOOSE_DRIVER=mysql` → `postgres`；DSN 换 PG URL | 迁移命令连不上库 |
| `services/go-user-system/.env.example` | 注释与口令占位文案 | 过时事实 |
| `services/go-user-system/docs/deploy/backup-recovery.md` | 全文改 PG（含两道校验、DROP/CREATE 拆条的实测原因） | 文档教人用已删除的脚本 |
| `docs/16-stage3-observability.md:328` | Runbook 正文「auth、MySQL、Redis readiness」→「auth、PostgreSQL（认证库）、Redis」 | **锚点检查器看不见正文** ⇒ 改错不响 |

## 2. 为什么不改（要点名）

| 位置 | 为什么不改 |
| --- | --- |
| `docs/24-architecture-diagrams.md:31,51,74,241` | 这是**拓扑现状图**（描述 compose 里实际存在的容器）。compose 属 M4，切库前改它 = 把现状写成未来 |
| `docs/日常运维/运维手册.md:112` | 同上（容器清单 `knowtrace-workflow-auth-mysql-1` 是现状） |
| `README.md` / `README.en.md` 的「四类备份（PostgreSQL, MySQL, Redis, uploads）」 | 同上，属产品/部署说明 |
| `docs/15-stage2-vps-reliability.md` / `docs/日常运维/*` 的恢复演练**记录** | **历史快照不改写**（`AGENTS.md` §5）：它们记的是当时发生的事 |

**→ 这些随 M4（compose 切库）一起改；本分支不改。** 判据：`git grep -n "auth-mysql" -- docs/` 在 M4 提交里应清零。

## 3. `AUTH_DB_PASSWORD` 而不是 `DB_PASSWORD`

`security-check.sh` 扫的是**根 `.env`**（`ENV_FILE=/opt/knowtrace/.env`），
根 `.env` 里认证库口令的键名是 `AUTH_DB_PASSWORD` / `AUTH_DB_ROOT_PASSWORD`
（`compose.yaml:15,39,42` 与 `.env.example:16-17` 实测）。
`DB_ROOT_PASSWORD` / `DB_PASSWORD` 是**服务自建 compose**（`services/go-user-system/.env.example`）的键名，
二者不是同一个文件——写错键名等于「查了但查不到」。

## 4. 实测

| # | 判据 | 结果 |
| --- | --- | --- |
| P1 | `bash -n` 5 个 shell | 全部 **exit 0** |
| P2 | `python -m py_compile log_analyzer.py` | **exit 0** |
| P3 | 脱敏冒烟：`PGPASSWORD=supersecret` | → `PGPASSWORD=***` |
| P4 | 脱敏冒烟：`postgres_password=abc` | → `postgres_password=***` |
| P5 | 脱敏冒烟：URL 凭据 `postgres://u:p@h/db` | → `postgres://***@h/db` |
| P6 | `node scripts/check-runbook-anchors.mjs` | **13 个引用全部可解析**（改正文不影响锚点，这次实测确认） |

## 5. 边界与未验证项（如实）

- **巡检脚本未在真实主机上跑过**：`ops_service_running` 依赖 `docker compose ps`，本机无 Docker。
  改的是服务名字面量，不是解析逻辑。
- **`monthly-ops.sh` 的 500MiB 内存阈值未重算**：原值按「postgres / mysql / redis 三容器」标定，
  换成「两个 PG 实例 + redis」后内存画像不同。**本提交只把这件事写在注释里，没有给新数字**——
  D1：没有实测就不编阈值。登记为待办。
- **`EXPECTED_SERVICES` 在 M4 之前会与现状不符**：`ops.conf.example` 是模板，主机上真正生效的是
  `/etc/knowtrace/ops.conf`。M4 之前若已按模板部署，需要在该文件里改回 `auth-mysql`（已在模板注释里写明）。
