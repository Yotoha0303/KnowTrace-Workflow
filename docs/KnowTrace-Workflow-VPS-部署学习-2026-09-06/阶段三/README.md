# 阶段三：Prometheus、Grafana、日志栈与邮箱告警

> ⚠️ **本目录是 2026-09-08 的历史快照，不是现行口径。**
> 本文写作时的日志栈是 **ELK**，它已于 **2026-10-03** 被 **PLG（Alloy + Loki）**替换并删除。
> 因此本文的「ELK 按需操作」「Kibana / 5601」「elk.sh」等**均已不存在，不要照做**。
>
> **现行入口**：
> - 日志栈与告警的完整口径 → [`../../16-stage3-observability.md`](../../16-stage3-observability.md)
> - 日常可执行步骤 → [`../../日常运维/运维手册.md`](../../日常运维/运维手册.md)
> - 换栈的完整记录 → [`../../changes/2026-10-03-ELK换PLG与deploy重构及Ansible引入.md`](../../changes/2026-10-03-ELK换PLG与deploy重构及Ansible引入.md)

## 阶段结果（2026-09-09 快照，**当时**的事实）

Prometheus、Grafana、Alertmanager 和 Exporter 已常驻运行；ELK 采用按需 profile。2026-09-09 快照中 12/12 Prometheus targets UP，ELK 三个组件 healthy。外部邮箱告警仍未完成实际收件验收。

> 这段里的「ELK 按需运行」已作废（换成常驻的 Loki + Alloy）。
> 「外部邮箱告警未验收」**仍然成立** —— 且比当时更严重：2026-10-02 的系统重装
> 把已接好的 163 配置一并抹掉了，2026-10-03 才重新接上。

## 1. 一键部署核心监控

第一次需要让应用包含 metrics 代码时：

```bash
cd /opt/knowtrace
scripts/linux/deploy-observability.sh --build-app
```

以后只更新监控配置：

```bash
cd /opt/knowtrace
scripts/linux/deploy-observability.sh
```

脚本会执行资源预检、环境初始化、Compose/promtool/amtool 校验、镜像拉取、Nginx metrics 阻断、容器启动和验收。

## 2. 关键配置

| 本地快照 | 作用 |
| --- | --- |
| `compose.observability.yaml` | Prometheus/Grafana/Alertmanager/Exporter 与 ELK 服务 |
| `deploy/monitoring/prometheus.yml` | 抓取目标和 Alertmanager 地址 |
| `deploy/monitoring/rules/knowtrace.yml` | 应用、主机、备份和自监控规则 |
| `deploy/monitoring/blackbox.yml` | HTTP 探针配置 |
| `deploy/grafana/` | 数据源和 dashboard provisioning |
| `deploy/logstash/` | 日志输入、解析和 Elasticsearch 输出 |
| `.env.observability.example` | 非敏感字段模板 |

上述路径均位于 `服务器文件快照/项目/opt/knowtrace/`。

> **快照已部分删除（2026-10-03）**：`服务器文件快照/` 下
> `deploy/logstash/`、`scripts/linux/elk.sh`、`compose.observability.yaml`、
> `docs/16-stage3-observability.md` 这四项反映的是**现实中已不存在的文件**，已从本目录移除
> —— 留着一份会让人误以为服务器上还有这些文件。其余快照（monitoring / grafana /
> nginx / 脚本）与当前仍基本一致，保留。

真实 `.env.observability`、metrics token、Grafana密码和渲染后的 Alertmanager秘密配置没有复制。

## 3. SSH 隧道访问

在 Windows PowerShell 保持以下命令运行：

```powershell
ssh -N `
  -L 3001:127.0.0.1:3001 `
  -L 9090:127.0.0.1:9090 `
  -L 9093:127.0.0.1:9093 `
  -L 3100:127.0.0.1:3100 `
  knowtrace-vps
```

访问入口：

- Grafana：`http://127.0.0.1:3001`（日志也在 Grafana 里查，选 Loki 数据源）
- Prometheus：`http://127.0.0.1:9090`
- Alertmanager：`http://127.0.0.1:9093`
- Loki（HTTP API，一般不用直连）：`http://127.0.0.1:3100`

不得在 UFW 或云防火墙中直接开放这些端口。

## 4. 日志栈操作（**原文为 ELK，已作废**）

> 2026-10-03 起日志栈是 **PLG**，**常驻运行，没有启停流程**。
> `scripts/linux/elk.sh` 已删除；下面这段只作为历史保留。

```bash
# 【已作废，勿执行】
cd /opt/knowtrace
scripts/linux/elk.sh status
scripts/linux/elk.sh up
python3 scripts/linux/verify-observability.py --elk
scripts/linux/elk.sh stop
```

**现行做法**：Loki + Alloy 常驻，在 Grafana 里用 LogQL 查。
四路采集（容器 / Caddy / Nginx / 外部投递）都要有流；具体命令见
[`../../16-stage3-observability.md`](../../16-stage3-observability.md) 的「日志栈（PLG）与查询」。

禁止使用 `docker compose down --volumes`。

## 5. 核心监控验收

```bash
python3 scripts/linux/verify-observability.py --core
python3 scripts/linux/verify-observability.py --logs
curl -fsS http://127.0.0.1:9090/-/ready
curl -fsS http://127.0.0.1:9093/-/ready
```

（原文还有一条 `curl http://127.0.0.1:9200/_cluster/health` —— Elasticsearch 已不存在，删去。
日志栈的验收改由 `--logs` 承担。）

已保存的 Blackbox 演练日志位于 `证据/knowtrace-observability-drill-20260908T044604Z.log`，记录了 target down、告警 firing、Alertmanager 接收、恢复和清除。

## 6. 邮箱告警边界

配置助手：

```bash
cd /opt/knowtrace
scripts/linux/configure-163-alert-email.sh
scripts/linux/test-email-alert.sh
```

授权码必须在隐藏提示中输入，不得写入命令参数、聊天、Git 或本地 Markdown。此前曾在聊天中提供过授权码，应先到邮箱后台作废并重新生成，再做真实收件测试。只有收件箱实际收到告警，才能标记完成。

## 7. 材料入口

- `文档/08-Prometheus容器监控与企业实践.md`
- `文档/02-日志位置与查询.md`
- `文档/README-D盘旧版阶段三交付.md`
- `证据/`、`SOP/`、`故障记录/`、`问题记录/`、`待办/`
- `问题记录/INC-S3-001-阶段三本地完整记录缺失.md`

> 已移除的入口（2026-10-03）：`文档/02-ELK按需启动与访问.md`（纯操作 SOP，栈已删）、
> 以及 `服务器文件快照/` 下反映已不存在文件的四项。详见第 2 节。
