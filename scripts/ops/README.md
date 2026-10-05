# scripts/ops —— 运维工具包

日 / 周 / 月三档巡检脚本，以及它们的公共库、定时任务单元和使用手册。
按 `../../KnowTrace-ops/` 里那份《bash与python的运维使用建议》第 5 节的规划落位。

## 目录

| 路径 | 内容 |
| --- | --- |
| `scripts/daily-check.sh` | 日巡检（12 个章节，覆盖最广）：主机/负载/内存/磁盘/inode、systemd 服务、Docker、容器日志扫描、健康端点、备份新鲜度、监听端口与 UFW、仓库状态 |
| `scripts/daily-ops.sh` | 日巡检（精简版）：资源、磁盘、容器、健康端点、**监控 Targets**、**主机 systemd 单元**，带统一结论与退出码 |
| `scripts/weekly-check.sh` | 周巡检：备份完整性校验、日志错误聚类与上周基线对比、证书有效期、异常登录 |
| `scripts/monthly-ops.sh` | 月巡检：隔离恢复演练、依赖更新检查、故障复盘、文档更新。**唯一会写服务器的脚本** |
| `scripts/log_analyzer.py` | 被 weekly 调用：日志错误聚类 + 与基线对比 |
| `scripts/ops-report.py` | 被 monthly 调用：多期报告汇总、巡检闭环新鲜度 |
| `scripts/cert_check.py` | 被 weekly 调用：TLS 证书有效期与链校验 |
| `scripts/security-check.sh` | 被 weekly 调用：异常登录与端口合规 |
| `lib/` | Bash 与 Python 公共库，两个日巡检脚本都依赖。**2026-10-05 起含 `ops_systemd_check()`**（关键服务 / 备份定时器 / failed 单元白名单）与 `mon.textfile` 判据 —— 放在这里是因为 `daily-check.sh` **没有定时器**，判据必须落在真会跑的脚本上 |
| `systemd/` | 6 个定时任务单元 + [`MEMO.md`](systemd/MEMO.md)（安装/回滚/退出码语义/踩过的坑）。**2026-09-28 已安装并 enable** |
| `../deploy/systemd/` | ⚠️ **另一组单元在这里，不在本目录** —— 见下方说明 |
| `ops.conf.example` | 配置模板。**2026-10-05 新增键 `SYSTEMD_FAILED_ALLOWLIST`** —— failed 单元判据的白名单，**缺省为空**（= 任何 failed 都算问题）。每一项都要能说清理由；当前只有 `repass.service`（`INC-S2-003` 判为云厂商控制台救援链路，刻意保留）。**改这个键等于改判据口径**，别为了让列表好看而往里面加 |

### 为什么 systemd 单元分在两处

仓库里有两组 systemd 单元，**不是重复，是由不同的安装器负责**：

| 位置 | 单元 | 安装者 | 装的是什么 |
| --- | --- | --- | --- |
| `scripts/ops/systemd/` | `daily-ops` / `weekly-check` / `monthly-ops`（3 组 service+timer）+ `install.sh` | **本目录的 `systemd/install.sh`**，或 `scripts/bootstrap/bootstrap.sh --stage ops` | **巡检**（只读巡检的定时任务） |
| `deploy/systemd/` | `knowtrace-workflow-backup` / `knowtrace-workflow-offsite-backup` / **`knowtrace-workflow-alert-drill`**（3 组 service+timer） | `scripts/linux/deploy-observability.sh`（第 105 行起） | **备份**（本地一致性备份 + 异地上传）+ **告警送达演练** |

**为什么没有合并**：两者的安装时机与归属不同——备份与演练单元随「核心监控部署」一起装
（`deploy-observability.sh` 的 `[5/5]` 步），巡检单元随「运维工具包」一起装。
合并到一处需要在两个安装器之间建立依赖，收益不抵改动风险。

> **2026-10-05 修**：上面 `deploy/systemd/` 那行原先只写了两组（backup / offsite），
> 且 `deploy-observability.sh` **实际只装了 backup 那两个** ——
> `offsite-backup.{service,timer}` 全仓没有任何安装器（只能找到 timer 引用自己），
> 所以**全新机器上永远不会被装**，而 `bootstrap.sh` 的 verify 只是「检查它是否 enabled」。
> 已把三组装在一起。新增的 `alert-drill` 是告警送达演练（`Mon 20:30 UTC`，
> `Persistent=false` —— 判据要求自然触发，补跑不算）。

**改单元时注意**：改 `scripts/ops/systemd/` 下的要跑 `install.sh`；
改 `deploy/systemd/` 下的要重跑 `deploy-observability.sh`。**两者都要 `daemon-reload`。**
| `docs/运维脚本使用说明.md` | 完整手册：安装、用法、安全模型、阈值说明 |
| `ops.conf.example` | 配置模板。**实际使用的 `ops.conf` 不入库**（含内网地址与账号名，已在 `.gitignore`） |

## daily-check.sh 与 daily-ops.sh 的分工

仓库里原本有一份 `scripts/linux/daily-check.sh`（429 行，输出原始数据），
**已于 2026-09-28 删除**，由本目录的版本取代：

- `daily-check.sh` —— 覆盖最广的巡检，12 个章节，输出带结论分级与退出码
- `daily-ops.sh` —— 精简版，聚焦「日清单」五项，与 weekly / monthly 共用同一套报告格式

两者可以并存，报告都写进 `ops.conf` 的 `REPORTS_DIR`（`/var/lib/knowtrace/reports`）。
如果没有特别需要，**建议只挂一个**，避免同一目录下出现两套日巡检报告。

## 结论分级与退出码

| 级别 | 含义 |
| --- | --- |
| `OK` | 已确认符合预期（必须实际验证过） |
| `WARN` | 需要关注，但尚未影响可用性 |
| `FAIL` | 已确认异常，需要处理 |
| `INFO` | 事实记录，不构成判断（包括所有「无法验证」的情况） |

| 退出码 | 含义 |
| --- | --- |
| 0 | 未发现异常 |
| 1 | 存在 WARN |
| 2 | 存在 FAIL |
| 3 | 脚本自身错误（参数、依赖、环境） |

## 常用参数

`--conf <文件>` `--json <文件或目录>` `--markdown <文件或目录>` `--no-json`
`--quiet/-q` `--no-color` `--record`（生成记录骨架） `--help/-h`

## 快速开始

```bash
# 1) 部署（不要放进 /opt/knowtrace，避免被部署覆盖）
sudo mkdir -p /opt/knowtrace-ops
sudo cp -a lib scripts systemd docs README.md ops.conf.example /opt/knowtrace-ops/

# 2) 配置
sudo cp /opt/knowtrace-ops/ops.conf.example /opt/knowtrace-ops/ops.conf
sudo chmod 600 /opt/knowtrace-ops/ops.conf
sudo vi /opt/knowtrace-ops/ops.conf    # 至少确认 PROJECT_DIR / CERT_DOMAINS / PUBLIC_HEALTH_URL

# 3) 报告目录
sudo mkdir -p /var/lib/knowtrace/reports

# 4) 试跑（只读，不会改任何东西）
sudo bash /opt/knowtrace-ops/scripts/daily-check.sh

# 5) 挂定时任务 —— 已挂好，见 systemd/MEMO.md
#    重建顺序：先 cp 单元 + daemon-reload，再「手工 start 验证」，
#    确认 journal 无 specifier 报错后才 enable --now
```

## 只读保证

`daily-check.sh` / `daily-ops.sh` / `weekly-check.sh` **不做任何修改性动作**。
唯一写入是报告文件与 `--record` 生成的记录骨架。

`monthly-ops.sh` 是唯一会改动服务器的，用**四道闸**保护（`--apply` + `ops.conf` 开关 +
未被 `--without-*` 关闭 + `MONTHLY_WRITE_WINDOW` 时间窗），之后还需输入 `yes`。
`apt` 升级另需 `--apply-updates`；重启系统永不自动执行。详见 `docs/运维脚本使用说明.md` 第 5 节。
