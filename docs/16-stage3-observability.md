# VPS 阶段三：指标、可视化、集中日志与邮件告警

## 目标与证据边界

本阶段在单台 2 GiB VPS 上建立可运行、可验证、可回滚的最小可观测性闭环：

- Prometheus 抓取主应用、认证服务、服务器和 HTTP 探针指标；
- Grafana 自动加载数据源和 `KnowTrace-Workflow VPS 可观测性` dashboard；
- Alertmanager 接收 Prometheus 告警，并在配置 SMTP 后发送邮件；
- Alloy 采集边缘代理与全部容器日志送给 Loki，Grafana 里与指标同一处检索（PLG 栈）；
- 通过可恢复的 Blackbox Exporter 停止实验验证“发现 → firing → 送达 Alertmanager → 恢复 → 清除”。

单机 Compose 不能证明高可用、长期容量、SLA、真实值班或外部邮件送达；每一项必须按实际证据表述。

## 架构

```text
公网用户 -> Caddy :443 -> Nginx 127.0.0.1:8080 -> Next.js / Go Auth
                                         ^
Prometheus -> Next.js 私有 /api/metrics --|-- Go /metrics
           -> Node Exporter（主机）
           -> Blackbox Exporter（内部与公网 ready）
           -> Alertmanager -> SMTP（有凭据后）
Grafana ----> Prometheus

Caddy / Nginx / Docker JSON logs -> Alloy -> Loki -> Grafana（同一界面里查日志）
                                      常驻组件，无按需 profile
```

> **2026-10-03 从 ELK 换成 PLG。** 原先的 Elasticsearch + Logstash + Kibana
> 三件合计内存上限约 2 GB，在 1.8 GB 的机器上必须按需启停。Loki 无 JVM，
> 实测占用低一个数量级（**Loki 85 MiB / Alloy 56 MiB**，各自上限 512 / 256 MiB），
> 因此改为**常驻**，与 Prometheus/Grafana 同等待遇，不再有"用前启动、用后停止"的流程。
> 换栈的完整记录（含为什么选 Alloy 而不是 Promtail、以及采集那一路最容易漏）
> 见 [`changes/2026-10-03-ELK换PLG与deploy重构及Ansible引入.md`](changes/2026-10-03-ELK换PLG与deploy重构及Ansible引入.md)。

## 安全与资源策略

- 9090、3001、9093、3100、5000 只绑定 `127.0.0.1`，不开放 UFW 端口。
- Grafana、Prometheus、Alertmanager 和 Loki 只通过 SSH 隧道访问。
- `/api/metrics` 需要随机 Bearer token；Prometheus 从 0400 文件读取。Nginx 对公网该路径固定返回 404。
- `.env.observability` 和渲染后的 Alertmanager 配置不进入 Git；权限分别为 0600/0400。
- Prometheus 同时按 7 天和 512 MB 限制时序数据。
- Docker 日志对新建的阶段三容器限制为 10 MB × 3 文件。
- Loki 采用本地文件系统、7 天保留（与原 ELK 的 ILM 对齐），常驻运行、不设 profile。
  它直接进默认网络与 Grafana 互通，**没有** ELK 时代那两个专用网络
  （`logging-internal` / `logging-management`）—— 它们是 ELK 专属的，随其删除。
- 不使用 `docker compose down --volumes`；它会删除监控或日志数据。

## 关键文件

| 文件 | 用途 |
| --- | --- |
| `compose.observability.yaml` | 核心监控与 PLG 日志栈（全部常驻） |
| `deploy/monitoring/prometheus.yml` | 抓取与 Alertmanager 路由 |
| `deploy/monitoring/rules/knowtrace-workflow.yml` | 应用、主机、备份和自监控规则 |
| `deploy/grafana/` | 数据源（Prometheus + Loki）和 dashboard provisioning |
| `deploy/alloy/config.alloy` | 容器、Caddy、Nginx 与验证事件的采集管道（替代 `logstash/`） |
| `deploy/loki/loki-config.yml` | Loki 单机配置：本地文件系统 + 7 天保留 |
| `scripts/linux/init-observability-env.sh` | 生成本地 secrets、渲染 Alertmanager 配置 |
| `scripts/linux/configure-163-alert-email.sh` | 交互式写入 163 邮箱与隐藏授权码 |
| `scripts/linux/deploy-observability.sh` | 容量预检、配置校验、部署和验收 |
| `scripts/linux/verify-observability.py` | 端点、target、PromQL、Grafana 与 PLG 日志栈验收 |
| `scripts/linux/observability-drill.sh` | 可恢复的监控故障演练 |
| `scripts/linux/verify-alert-delivery-drill.sh` | **告警送达演练的编排器**：跑演练 + **断言邮件投递计数至少 +1**（见下） |

## 部署 SOP

### 1. 发布前

```bash
cd /opt/knowtrace
git status --short --branch
free -h
df -h /
docker stats --no-stream
systemctl status knowtrace-workflow-backup.timer --no-pager
scripts/linux/backup-all.sh
scripts/linux/verify-restore.sh /var/backups/knowtrace/<新归档>
```

记录当前 commit、生产 overlay 哈希、归档 SHA-256、ready 和容器状态。备份会短暂停止 app/auth 写入入口；在可能有用户时先公告维护窗口。

### 2. 部署核心监控

首次包含主应用指标代码变更：

```bash
cd /opt/knowtrace
scripts/linux/deploy-observability.sh --build-app
```

后续只更新监控配置：

```bash
scripts/linux/deploy-observability.sh
```

脚本依次完成容量检查、secret 初始化、Compose/promtool/amtool 校验、固定镜像拉取、应用更新、Nginx 公网 metrics 阻断、监控启动、备份指标接入和完整验收。

### 3. SSH 隧道访问

在 Windows 单独开一个终端：

```powershell
ssh -N `
  -L 3001:127.0.0.1:3001 `
  -L 9090:127.0.0.1:9090 `
  -L 9093:127.0.0.1:9093 `
  knowtrace-vps
```

然后访问：

- Grafana：`http://127.0.0.1:3001`
- Prometheus：`http://127.0.0.1:9090`
- Alertmanager：`http://127.0.0.1:9093`

Grafana 用户名/密码只在 VPS 的 `/opt/knowtrace/.env.observability` 中查看，不复制到公开文档或聊天。

## 邮件告警

外部邮件默认关闭。使用 `sudoedit /opt/knowtrace/.env.observability` 填写：

```dotenv
ALERT_EMAIL_ENABLED=true
ALERT_SMTP_SMARTHOST=smtp.example.com:587
ALERT_SMTP_FROM=alerts@example.com
ALERT_SMTP_AUTH_USERNAME=alerts@example.com
ALERT_SMTP_AUTH_PASSWORD=<应用专用密码>
ALERT_SMTP_REQUIRE_TLS=true
ALERT_EMAIL_TO=operator@example.com
```

推荐 587/STARTTLS 和应用专用密码，不使用邮箱网页登录密码。更新后：

若提供商只开放 465 隐式 TLS（例如本次 163 邮箱），当前固定版本
Alertmanager 0.28.1 应使用：

```dotenv
ALERT_SMTP_SMARTHOST=smtp.163.com:465
ALERT_SMTP_REQUIRE_TLS=false
```

这里的 `false` 只跳过已建立 TLS 后的第二次 STARTTLS 请求，不会把 465
连接降级为明文。Alertmanager 0.28.1 的邮件实现会先对 465 执行 TLS 握手，
而 `require_tls=true` 还会继续检查并请求 STARTTLS。修改端口或升级
Alertmanager 后必须重新核对该版本实现并做证书、配置和实际收件验证。

163 邮箱可用交互助手配置。授权码只通过隐藏提示输入，不放在命令参数、
Shell 历史、聊天或文档中：

```bash
scripts/linux/configure-163-alert-email.sh
```

如果授权码曾出现在聊天、截图或工单中，先在邮箱后台作废并生成新授权码，
再运行助手；不要继续使用已暴露的授权码。

更新后：

```bash
scripts/linux/init-observability-env.sh
docker compose \
  --env-file .env \
  --env-file .env.observability \
  -f compose.yaml \
  -f compose.production.yaml \
  -f compose.observability.yaml \
  up -d --no-deps --force-recreate alertmanager
scripts/linux/test-email-alert.sh
```

只有 Alertmanager 日志显示发送成功且收件箱实际收到测试邮件，才能标记“外部邮件告警已验证”。

## 故障演练

```bash
scripts/linux/observability-drill.sh blackbox
```

脚本先验证正常基线，再停止 Blackbox Exporter，等待 `KnowTraceMetricsTargetDown` 进入 firing 并出现在 Alertmanager，随后通过 trap 恢复容器，重新验证 12 个 targets 并等待告警清除。它不会停止 KnowTrace-Workflow 应用或数据库。

### ⚠ 它**不**验证邮件送达 —— 要验投递得用编排器

上面那个脚本只断言到「**Alertmanager 收到了**」。它**不可能**验证邮件真的发出去，
原因是 AM 的 `group_wait` 是 30s：告警进 AM 后要等满 30 秒才首次投递，
而演练的验证循环 3 秒一轮、一确认收到就**立刻**恢复故障 ——
整组在 `group_wait` 到期前就被清掉，**AM 一封都不发**，而演练照样报 `RESULT=PASS`。

```bash
# 编排器：取投递基线 → 以「保持时长 > group_wait」跑演练 → 断言计数至少 +1
bash scripts/linux/verify-alert-delivery-drill.sh
```

实测时间线（2026-10-04，修复前）：`15:57:40` firing → `15:58:05` 已 resolve，
而首次投递本应在 `15:58:10` —— 差 5 秒，整组就没了。

**判据落在 `alertmanager_notifications_total{integration="email"}` 的增量上**，
不落在「演练报了 PASS」上。2026-10-05 起它每周一 20:30 UTC 由
`knowtrace-workflow-alert-drill.timer` 自然跑（见 `deploy/README.md`）。

## 日志栈（PLG）与查询

日志栈**常驻**，没有启停流程 —— 这也是换掉 ELK 的主要收益。
原先 ELK 要"用前启动、用后停止"，理由是内存；现在 Loki + Alloy 合计实测约
140 MiB，常驻即可，代价低于"每次用都得走一遍启停加验证"的心智负担。

### 查询

Grafana 里 Loki 数据源与 Prometheus 同处（见上面的 SSH 隧道），
在 Explore 里选 `Loki`，用 LogQL 查：

```logql
{container=~".+"}                              # 全部容器日志
{job="caddy"}                                  # Caddy 访问日志
{job="nginx"}                                  # Nginx access + error
{job="external"}                               # 外部投递（脚本/程序推进来的）
{container="knowtrace-workflow-app-1"} |= "EACCES"      # 容器 + 内容过滤
```

也可以用 HTTP API 直接查（排障时不必开 Grafana）：

```bash
# 有哪些流
curl -sG 'http://127.0.0.1:3100/loki/api/v1/series' \
  --data-urlencode 'match[]={job=~".+"}'

# 查容器日志
curl -sG 'http://127.0.0.1:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={container=~".+"}' \
  --data-urlencode "start=$(date -d '1 hour ago' +%s)000000000"
```

### 采到哪几路（换栈时最容易漏的地方）

Alloy 的 `deploy/alloy/config.alloy` 与原先 Logstash 的 pipeline **一一对应**，
顶部有对照表。四路缺一不可：

| 来源 | 组件 |
| --- | --- |
| `/var/log/caddy/*.log` | `loki.source.file` ← `local.file_match`（**必须两步**，见下） |
| `/var/log/nginx/knowtrace.*.log` | 同上 |
| 全部容器 json 日志 | `loki.source.docker`（按 label 自动带 `container` / `service` 标签） |
| 外部投递（原 Logstash TCP :5000） | `loki.source.api` |

> ⚠️ **`loki.source.file` 不做 glob 展开。**
> 实测踩到：直接写 `__path__ = "/var/log/caddy/*.log"` 时，Alloy 把 `*` 当普通字符去
> `stat`，报 `no such file or directory`，而文件其实存在。必须先用
> `local.file_match` 做文件发现，再交给 `loki.source.file` tail。
> 症状是**Caddy/Nginx 日志一条都进不来，但容器日志那一路正常** ——
> 很容易误以为"日志栈是好的"。

### 排障

**Grafana 里日志是空的** —— 先分清是哪一路，再对症：

```bash
docker logs --tail 50 knowtrace-workflow-alloy-1
docker logs --tail 50 knowtrace-workflow-loki-1
# 确认四路各有流
for j in caddy nginx external; do
  curl -sG 'http://127.0.0.1:3100/loki/api/v1/series' \
    --data-urlencode "match[]={job=\"$j\"}" | head -c 200; echo
done
```

- **容器日志和宿主机日志同时为空** → 看 Alloy 是不是根本没起来，或它到 Loki
  的写入地址不通（`http://loki:3100`，同默认网络）。
- **只有 Caddy/Nginx 为空** → 大概率是上面那条 glob 的坑，或文件晚于 Alloy 出现。
  本配置用 `local.file_match` 的 `sync_period = "10s"` 轮询发现新文件
  （实测新机器上 Caddy 日志 09:03 才生成，而 Alloy 09:01 就启动了）。
- **Alloy 启动日志里有 `could not perform the initial load successfully`** →
  这条在启动瞬间出现是正常的（试图装载尚未生成的文件），
  实测容器 `RestartCount=0` 且日志照常进 Loki。**不要**据此判定采集坏了，
  要看的是上面那个"有没有流"。

**Alloy 改配置后**：`alloy fmt` 只查语法、**不查组件属性名** ——
实测 fmt 通过但启动时报 `unrecognized attribute`。
真正的校验是启动后读 `docker logs`。

**Loki 写满了**：7 天保留由 `limits_config.retention_period` 与 compactor 控制。
先看 `df -hT /` 与 `docker exec knowtrace-workflow-loki-1 du -sh /loki`，
不要直接删 `/var/lib/docker/volumes/knowtrace_loki_data`（那是数据卷，不是缓存）。

## 验收命令

```bash
python3 scripts/linux/verify-observability.py --core
python3 scripts/linux/verify-observability.py --logs
curl -sS http://127.0.0.1:9090/api/v1/targets
curl -sS http://127.0.0.1:9090/api/v1/rules
curl -sS http://127.0.0.1:9093/api/v2/status
```

`--core` 与 `--logs` 是**两段独立的验收**，`deploy-observability.sh` 会依次跑完。
`--logs` 断言的是"投递一条 → 能查回"的整条链路，不只是容器在跑。

完成定义：

- 主应用私有 metrics 为 200，Nginx/公网 metrics 为 404；
- Prometheus 至少 12 个 active targets 全部 UP；
- 核心 PromQL 有样本，备份新鲜度指标存在；
- Grafana 数据源和 dashboard 通过 API 证实已 provisioning（含 **Loki 数据源**）；
- Prometheus 发现 active Alertmanager；
- 故障演练经历正常、firing、送达、恢复、清除；
- **Loki 里查得到真实容器日志**，且验证事件能"投递→查回"（`--logs` 全 PASS）；
- 外部邮件必须另有实际收件证据。

## 告警 Runbook

### Target down

先看 Prometheus target 的 `lastError`，再检查对应容器、Docker DNS 和 metrics 鉴权。不要先重启整套服务。

### HTTP probe failed

区分 `up{job="blackbox-exporter"}` 与 `probe_success`：前者表示 Prometheus 能抓取 exporter，后者才表示目标 URL 成功。比较内部 ready 和公网 ready，逐层检查 app → Nginx → Caddy → DNS/TLS。

### Database not ready

保存 app ready 响应和 app/PostgreSQL 日志，检查容器 health、连接数、磁盘和迁移状态。不要删除 volume。

### Auth not ready

同时检查 auth、MySQL、Redis readiness 和认证日志。恢复后必须验证登录/刷新，而不只看容器 running。

### Request errors

按 `route_type`、`route_path` 对照结构化 `[knowtrace-request-error]` 容器日志，并检查同时间的 Caddy/Nginx 请求。动态用户 ID 不进入 Prometheus 标签。

### Host capacity

保存 `uptime`、`free -h`、`vmstat 1 10`、`df -hT /`、`docker stats --no-stream`。
先按占用从大到小看 `docker stats`，不要盲目清缓存或杀数据库。

日志栈（Loki/Alloy）现在是常驻的，合计约 140 MiB —— 内存吃紧时它**不是**
首要嫌疑；先看应用与数据库。真要临时让出内存，停 Loki 会让日志断流（不是数据丢失），
这是有代价的动作，别当成常规手段。

### Backup freshness

检查 timer、`/var/log/knowtrace-workflow-backup.log`、归档 SHA-256 和磁盘。告警恢复前必须生成新归档并通过隔离恢复，不能只手工改时间戳指标。

### Auth HTTP

用路由模板和状态码聚合定位，避免把用户 ID、URL 查询串等高基数字段加入标签。结合日志确认是依赖超时、限流还是应用错误。

### Prometheus self

运行 promtool 检查配置/规则，查看 Prometheus 日志和 `/api/v1/rules` 的 lastError。修复后等待至少一个 15 秒 evaluation 周期。

### Offsite backup

三个指标由 `scripts/linux/offsite-backup.sh` 写入
`runtime/node-exporter/knowtrace-offsite.prom`，经 node-exporter 的 textfile
collector 暴露。它们与存储商无关 —— 换后端不改指标名。

先看现场：

```bash
systemctl status knowtrace-workflow-offsite-backup.timer --no-pager
systemctl status knowtrace-workflow-offsite-backup.service --no-pager
journalctl -u knowtrace-workflow-offsite-backup.service -n 50 --no-pager
ls -l /opt/knowtrace/runtime/node-exporter/knowtrace-offsite.prom
```

分三种情况：

- **NotConfigured**：`/etc/knowtrace/age-recipient.pub` 不存在 → 单元被
  `ConditionPathExists` 跳过。按 `docs/2026-09-29-异地备份实施记录与剩余步骤.md`
  的「剩余 5 步」配置。这是**已知未完成项**，不是故障。
- **Missing**：归档数为 0。检查 `OFFSITE_REMOTE` 是否可达
  （`rclone lsd <remote>`）、凭据是否过期、桶是否还在。
- **Stale**：超过 30 小时没成功上传。先手工跑一次看具体报错：

  ```bash
  bash /opt/knowtrace/scripts/linux/offsite-backup.sh --dry-run
  bash /opt/knowtrace/scripts/linux/offsite-backup.sh
  ```

**恢复前必做的验证**：从异地取一个归档回来，用 age 私钥解密，与原归档比
SHA-256。**未经恢复验证的备份不能算备份。** 私钥只应存在于人的密码管理器/
离线介质，**不在服务器上**——排查时不要为了图方便把它拷到服务器。

### Ops check

巡检结论的三个指标由 `scripts/linux/write-ops-metrics.sh` 从
`REPORTS_DIR` 里最新的报告 JSON 提取，经 node-exporter textfile collector 暴露。
它由三个巡检单元的 `ExecStartPost` 调用，**指标名带 `script` 标签**区分
`daily-ops` / `weekly-check` / `monthly-ops`。

先看现场：

```bash
systemctl list-timers 'knowtrace*' --no-pager
journalctl -u knowtrace-workflow-daily-ops.service -n 40 --no-pager
ls -t /var/lib/knowtrace/reports/ | head
cat /opt/knowtrace/runtime/node-exporter/knowtrace-ops.prom
```

分三种情况：

- **CheckFailed**（`worst_level >= 3`）：报告里有 FAIL。看报告正文定位是哪个
  `check`：

  ```bash
  grep -B2 -A2 'FAIL' "$(ls -t /var/lib/knowtrace/reports/*.md | head -1)"
  ```

- **NeverRan**（`absent(...)`）：报告目录里**一份 JSON 都没有**。常见原因是
  定时器没 enable，或 `REPORTS_DIR` 被改过。检查
  `systemctl is-enabled knowtrace-workflow-daily-ops.timer`。

- **DailyCheckStale / WeeklyCheckStale / MonthlyCheckStale**：跑过但超过周期。
  检查 timer 的 `OnCalendar` 与 `Persistent`，以及 service 是否被
  `ConditionPathExists` 之类跳过。

**排查时注意**：`ExecStartPost` 前缀是 `-`（失败不影响巡检结论），所以
**指标写失败时巡检报告仍然正常**——别只看到报告就说链路没问题，要
`cat` 一下 `.prom` 文件确认指标真的写出来了。

### 运行态版本核对

`knowtrace.revision` 组的指标由 `scripts/linux/write-revision-metrics.sh` 写入，
由 `knowtrace-workflow-daily-ops.service` 的第二个 `ExecStartPost` 调用；
`scripts/linux/deploy-observability.sh` 在部署末尾也会刷新一次。

它回答的是**可用性之外的另一类问题**：服务是否在回答（可用性）与
回答的是不是这一版代码（**同一性**）是两件事。整套监控原本只覆盖前者。

```bash
cat /opt/knowtrace/runtime/node-exporter/knowtrace-app-revision.prom
curl -s 'http://127.0.0.1:9090/api/v1/query?query=knowtrace_app_revision_match'
```

#### 为什么需要它：一次真实的假成功

2026-09-29 实测：`/opt/knowtrace` 的 HEAD 是 `47a4c20`，而运行中容器自报
revision 是 `7ce26f7d`（2026-09-08），**差 37 个提交 / 21 天**。
而当时 4 层健康检查、12 个抓取目标、20+ 条告警规则、整份巡检报告**全部正常**。

**RCA（2026-09-30 实测确认）**：不是「漏了第三个 `-f`」——
`deploy-observability.sh` 的 compose 数组一直带着三个 `-f`。真正的开关是
第 `[2/5]` 步的 `--build-app`：

| 调用 | 实际执行 | 结果 |
| --- | --- | --- |
| `deploy-observability.sh --build-app` | `up -d --no-deps --build --wait` | 真正重建镜像 |
| `deploy-observability.sh`（不带） | `up -d --no-deps --no-build --wait` | **只重启旧镜像，却照样打印成功** |

于是每一次「只更新监控配置」的部署都顺手把应用留在原地，**没有任何一步会说出来**。
容器 label 佐证：`knowtrace-workflow-app-1` 创建于 `2026-09-08T03:04:41Z`，
`com.docker.compose.project.config_files` 带三个 `-f`——说明它正是某次
`--build-app` 的产物，之后再没被重建过。

#### 为什么「不一致」要分成两种

`knowtrace_app_revision_match == 0` **本身不足以判断要不要处理**：
只改 `docs/` 的提交也会让部署目录与运行态不等，而应用行为完全相同。
若不加区分，这条告警会在每次文档提交后误报，很快被训练成忽略它
（参见素材 A17「永久性 WARN 会训练人忽略 WARN」）。

所以 `write-revision-metrics.sh` 额外算一个
`knowtrace_app_revision_app_changed_files`：用 `git diff` 数出
「运行中的 revision → 部署目录 HEAD」之间触及**应用路径**的文件数。
判据路径是 `src/`、`drizzle/`、`Dockerfile`、`package.json`、`pnpm-lock.yaml`
与三个 compose 文件。值为 `-1` 表示无法判断（运行中的 revision 不在本地历史里）。

于是规则分成两条：

| 告警 | 表达式 | 级别 | 含义 |
| --- | --- | --- | --- |
| `KnowTraceAppRevisionMismatch` | `match == 0 and app_changed_files > 0` | warning | **真的要处理**：应用代码变了但没生效 |
| `KnowTraceAppRevisionBehindDocsOnly` | `match == 0 and app_changed_files == 0` | info | 只是文档/脚本落后，**不需要重建** |

#### 部署末尾的断言

`deploy-observability.sh` 的第 `[6/6]` 步会读 `knowtrace_build_info` 与
`git rev-parse HEAD` 比对，并**区分两种情况**（这一步很重要，否则会天天误报）：

- 两者之间 `src/`、`drizzle/`、`Dockerfile`、`package.json`、`pnpm-lock.yaml`
  **有变化** → 是真的落后，**退出码 2**，并提示用 `--build-app` 重跑；
- **没有变化** → 只告警。只改监控配置时不一致是**预期**的。

排查运行态落后：

```bash
# 容器是哪一组 compose 文件创建的、镜像是哪天建的
docker inspect knowtrace-workflow-app-1 -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}'
docker inspect knowtrace-workflow-app-1 -f '{{.Created}}'
docker inspect knowtrace-app -f '{{.Created}}'

# 运行态自报
TOKEN=$(grep -oP '^METRICS_BEARER_TOKEN=\K.*' /opt/knowtrace/.env.observability)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:3000/api/metrics | grep build_info
```

**`revision="unknown"` 是一个专门的信号**：说明构建时没拿到
`KNOWTRACE_APP_REVISION`。核对脚本会把它判为
`knowtrace_app_revision_not_injected` 并写进 `knowtrace_app_revision_undetermined`。

#### 一个必须守住的约束

**`KNOWTRACE_APP_REVISION` 必须是构建时烘进镜像的，不能改成运行时注入。**

它现在是 `compose.yaml` 的 `build.args` → `Dockerfile` 的 `ARG`/`ENV`。
若改回运行时 `environment` 注入，**重建与不重建会得到同一个值**，
`knowtrace_app_revision_match` 将永远报 1 —— 那正是它要发现的问题。

### TLS certificate

指标来自 blackbox-exporter 的 https 探测：`probe_ssl_earliest_cert_expiry`，
不需要额外脚本。当前探测目标是公网 `https://knowtrace.duckdns.org/api/health/ready`。

证书是 Caddy 自动签发与续期的（Let's Encrypt，90 天有效）。**剩不到 21 天
说明自动续期很可能已经失败**——正常情况应该长期维持在 60–90 天。

```bash
# 看剩余天数
curl -s 'http://127.0.0.1:9090/api/v1/query?query=probe_ssl_earliest_cert_expiry'   | python3 -c "import json,sys,datetime;       print([datetime.datetime.fromtimestamp(float(r['value'][1])) for r in json.load(sys.stdin)['data']['result']])"

# 看 Caddy 日志里的续期记录
docker logs knowtrace-caddy-1 2>&1 | grep -iE "certificate|renew|acme" | tail -20
```

**不要手工覆盖证书文件**——Caddy 管理自己的存储，手工放进去的证书会在下次
续期时被覆盖。若续期确实失败，先查 80 端口可达性与 DNS，而不是改证书。

### Email delivery

检查 Alertmanager `/api/v2/status`、容器日志、SMTP DNS/TCP/STARTTLS 和提供商退信。不要在命令行历史、截图、Git 或故障单中暴露应用专用密码。

## 回滚

1. 保存诊断、当前 commit 和监控卷列表。
2. 停止核心监控但保留数据：对 observability overlay 执行 `stop grafana prometheus alertmanager blackbox-exporter node-exporter`。
3. Nginx 从 `/root/knowtrace-ops/backups/<时间>-stage3-nginx/knowtrace-workflow.conf` 恢复，执行 `nginx -t` 后 reload。
4. 应用回退到部署前 commit，保留 `.env`、`.env.observability`、`compose.production.yaml` 和所有数据卷。
5. 验证 app/auth/Nginx/公网 ready 和业务登录。

回滚代码不等于删除监控历史；除非经过单独确认，不删除任何 named volume。
