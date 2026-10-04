# 阶段三远端执行摘要

> ⚠️ **已过期（2026-10-03 起）**：本文的 ELK 部分已作废（ELK 被 Alloy + Loki 替换并删除），
> 其中的 `scripts/linux/elk.sh` 与原「ELK 按需启动」文档均已不存在。
> 现行口径见 [`../../../16-stage3-observability.md`](../../../16-stage3-observability.md)
> 与 [`../../../日常运维/运维手册.md`](../../../日常运维/运维手册.md)。

本工作区现有的阶段三材料包括本摘要、日志位置与查询，以及问题记录。

2026-09-09 复核发现，原记录中声明的桌面完整目录
`C:\Users\Yotoha\Desktop\KnowTrace-Workflow-VPS-部署学习-2026-09-06\阶段三`
实际不存在。完整实现文件当前位于 VPS `/opt/knowtrace`，并已推送到远端分支
`codex/stage3-observability`。详见：

- [阶段三日志位置与查询](02-日志位置与查询.md)
- [INC-S3-001：阶段三本地完整记录缺失](../问题记录/INC-S3-001-阶段三本地完整记录缺失.md)

## 结果

- 部署分支：`codex/stage3-observability`
- 最终 commit：`c6dc9548cfe2ee8c6a71ba1a62b49228a988e297`
- 核心监控：12/12 Prometheus targets UP，Grafana/Alertmanager/应用与主机指标已验证。
- 故障演练：Blackbox target down 已经历 firing、Alertmanager 接收、恢复和清除。
- ~~ELK：Logstash→Elasticsearch 查询命中 1，ILM 与 Kibana data view 已验证；当前已停止并保留卷。~~
  **已作废**：ELK 已于 2026-10-03 删除。当前日志栈是常驻的 Alloy + Loki，
  验收由 `verify-observability.py --logs` 承担。
- 公网：DNS 指向 `45.64.74.99`，ready=200，首页 307→`/login`，公网 metrics=404，TLS 校验通过。
- 未完成：外部 SMTP 邮件送达；当前为 local-only。

  > **这条到 2026-10-03 仍然成立，而且中间还退回过一次**：2026-09-28 曾接好 163 并实测收到邮件，
  > 但 **2026-10-02 的系统重装把配置一并抹掉**（`ALERT_EMAIL_ENABLED` 回到 `false`、
  > SMARTHOST 回到 `smtp.example.com:587` 占位值）。2026-10-03 才重新接上。
  > **教训：服务器上的运行时配置不在 Git 里，重装即丢失** —— 这正是 `deploy/ansible/` 存在的理由。
  > 见 [`../../../changes/2026-10-03-P4-Ansible宿主机阶段与P5文档收尾.md`](../../../changes/2026-10-03-P4-Ansible宿主机阶段与P5文档收尾.md)。

## 证据入口

- VPS 演练日志：`/var/log/knowtrace-observability-drill-20260908T044604Z.log`
- VPS 项目 Runbook：`/opt/knowtrace/docs/16-stage3-observability.md`
- VPS Compose overlay：`/opt/knowtrace/compose.observability.yaml`
- Git 分支：`origin/codex/stage3-observability`
- 本地问题记录：`阶段三\问题记录`

> 已移除：`VPS ELK 脚本：/opt/knowtrace/scripts/linux/elk.sh` 这一条 —— 该文件已删除。

本摘要不保存任何密码、token、私钥或 `.env` 内容。
