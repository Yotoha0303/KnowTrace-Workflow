# INC-S3-001：Blackbox Exporter 停止告警演练

- 类型：计划内故障演练，不是真实用户故障。
- 时间：2026-09-08 12:46:04～12:48:08（Asia/Shanghai）。
- 严重度：演练级。
- 状态：已关闭。
- 影响：Prometheus 无法抓取 Blackbox Exporter；KnowTrace-Workflow 和认证业务保持在线。
- 服务器日志：`/var/log/knowtrace-observability-drill-20260908T044604Z.log`。

## 正常基线

演练前应用、认证、Prometheus、Alertmanager、Grafana均返回 200，12/12 targets UP，关键 PromQL 有样本。

## 故障注入

```bash
cd /opt/knowtrace
scripts/linux/observability-drill.sh blackbox
```

脚本只执行 `docker compose stop blackbox-exporter`，并注册退出 trap 保证异常时也尝试恢复。

## 监控证据

- Prometheus target 变为 down。
- `KnowTraceMetricsTargetDown{job="blackbox-exporter"}` 进入 firing。
- Alertmanager API 查到同一告警。
- 未使用邮件通知，因为 SMTP 当前未配置。

## 恢复

脚本重新启动 Blackbox Exporter，等待抓取周期后重跑核心验收，并等待告警从 pending/firing 集合消失。

```text
PASS Prometheus targets: total=12 up=12
PASS Prometheus alert recovered and cleared
RESULT=PASS
```

## 根因与预防

本次根因是人为、受控地停止 exporter，不是应用缺陷。预防重点是：故障注入前验基线、只操作单个非业务组件、设置自动恢复 trap、等待告警触发与清除两个方向的证据、保存日志。后续若做真实故障演练，仍应先定义影响边界和终止条件。

## 证据边界

这只能证明一次单节点告警链路闭环，不能宣称真实生产事故响应、自动修复、外部通知或长期稳定性。
