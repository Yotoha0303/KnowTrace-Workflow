# 阶段三执行记录（VPS 实测）

## 当前结论

- 执行日期：2026-09-08。
- 状态：Prometheus、Grafana、Alertmanager、主机指标、应用指标和公网探测已完成远端实测；Blackbox 故障演练已闭环；ELK 已完成一次端到端验证并按设计停止。
- 唯一未关闭项：外部 SMTP 邮件告警。163 的 465 TLS 握手已验证，但当前 `ALERT_EMAIL_ENABLED=false`；必须确认发件/收件地址、用新授权码安全配置，并由收件箱实际收到测试邮件后才能标记完成。
- 当前部署分支：`codex/stage3-observability`。
- 当前部署 commit：`31f49641d310c693d829ce8ca6b7a24078a196ed`，已与远端同名分支一致，但尚未合并 `main`。
- 线上域名：`https://knowtrace.duckdns.org`；ready=200，首页 307 跳转 `/login`，公网 `/api/metrics`=404，TLS 校验通过。
- 管理入口：SSH 别名 `knowtrace-vps`，端口 22345，仅密钥登录。

## 状态矩阵

| 工作项 | 状态 | 实测证据 | 剩余条件 |
| --- | --- | --- | --- |
| 应用指标 | 已完成 | Bearer 保护的 `/api/metrics` 返回 200；公网经 Nginx 返回 404 | 持续观察指标基数 |
| Prometheus | 已完成 | 12/12 targets UP；5 条关键 PromQL 有样本 | 持续运行观察告警噪声 |
| Grafana | 已完成 | 数据源和 `knowtrace-vps-overview` dashboard 经 API 验证 | 用户可通过 SSH 隧道做视觉查看 |
| Alertmanager | 核心链路完成 | Prometheus 发现 1 个 active Alertmanager；故障告警实际送达 | SMTP 邮件送达待用户配置 |
| 主机状态 | 已完成 | Node Exporter 覆盖 CPU、内存、Swap、磁盘和备份新鲜度 | 持续观察阈值 |
| 故障演练 | 已完成 | target down → firing → Alertmanager → 恢复 → 清除 | 可后续增加应用/磁盘演练 |
| ELK | 已完成按需验证 | Logstash 事件写入 Elasticsearch 命中 1；ILM 和 Kibana data view 存在 | 不在 1.8 GiB VPS 常驻 |
| 邮件告警 | 处理中 | 163:465 TLS/证书已验证；当前仍为 local-only | 安全写入新授权码并由收件箱确认 |

## 架构

```text
Internet -> Caddy :443 -> Nginx 127.0.0.1:8080 -> KnowTrace-Workflow :3000

Prometheus -> KnowTrace-Workflow /api/metrics（Bearer）
           -> auth /metrics、Node Exporter、Blackbox Exporter
           -> Alertmanager -> SMTP（待配置）
Grafana    -> Prometheus

Caddy / Nginx / Docker JSON logs -> Logstash -> Elasticsearch -> Kibana
                                      仅按需启动，验证后停止
```

## 访问入口与密钥位置

- SSH 私钥：`C:\Users\Yotoha\.ssh\knowtrace_vps_ed25519`。不要复制、上传或写入本目录。
- SSH 配置：`C:\Users\Yotoha\.ssh\config`；别名已设置 `IdentitiesOnly yes`、`PasswordAuthentication no`。
- Grafana 管理员密码和 metrics token：VPS `/opt/knowtrace/.env.observability`，权限 0600；本目录不保存值。
- Prometheus token 文件：VPS `/opt/knowtrace/runtime/prometheus/metrics.token`，权限 0400。
- Alertmanager 渲染配置：VPS `/opt/knowtrace/runtime/alertmanager/alertmanager.json`，权限 0400。

打开管理界面时，在 Windows 单独运行：

```powershell
ssh -N `
  -L 3001:127.0.0.1:3001 `
  -L 9090:127.0.0.1:9090 `
  -L 9093:127.0.0.1:9093 `
  knowtrace-vps
```

- Grafana：`http://127.0.0.1:3001`
- Prometheus：`http://127.0.0.1:9090`
- Alertmanager：`http://127.0.0.1:9093`

## 目录

- [阶段三执行清单](../SOP/01-阶段三执行清单.md)
- [日志位置与查询](02-日志位置与查询.md)
- [核心监控部署与验收](../证据/2026-09-08-核心监控部署与验收.md)
- [Blackbox 告警故障演练](../证据/2026-09-08-Blackbox告警故障演练.md)
- [ELK 端到端与资源证据](../证据/2026-09-08-ELK端到端与资源证据.md)
- [公网 HTTPS 与最终状态](../证据/2026-09-08-公网HTTPS与最终状态.md)
- [故障演练记录](../故障记录/INC-S3-001-Blackbox-Exporter停止告警演练.md)
- [问题记录目录](../问题记录/)
- [163 端口 465 与 Alertmanager TLS 问题](../问题记录/ISSUE-S3-010-163端口465与Alertmanager-TLS语义冲突.md)
- [SMTP 邮件告警待验收](../待办/SMTP邮件告警待验收.md)

## 证据边界

这是单台 VPS 的个人运维实践证据，可以证明配置、部署、查询和一次可恢复故障演练；不能证明高可用、长期容量、真实生产值班、SLA 或真实用户规模。ELK 在本机运行时可用内存最低约 290～409 MiB，Swap 使用约 2.0 GiB，因此必须按需运行。

项目内的权威配置、脚本和原理文档位于 `C:\Users\Yotoha\Desktop\KnowTrace-Workflow`；本目录只保存学习过程和验收事实，不复制密钥或运行时配置。
