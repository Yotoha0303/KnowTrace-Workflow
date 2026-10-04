# KnowTrace-Workflow Prometheus 容器监控与企业实践

## 1. 直接结论

Prometheus 可以运行在 Docker 容器中，并通过 Docker Compose 的内部网络抓取 KnowTrace-Workflow 各服务的指标。

但“Prometheus 能看到容器”与“Prometheus 能理解业务”是两件事：

- cAdvisor 能看到容器 CPU、内存、网络和文件系统使用。
- Node Exporter 能看到 Ubuntu 主机 CPU、内存、磁盘、inode 和网络。
- 数据库 exporter 能看到 PostgreSQL、MySQL、Redis 的运行状态。
- Blackbox Exporter 能从用户视角探测 HTTPS 和健康接口。
- 只有应用自身埋点并暴露 `/metrics`，Prometheus 才能看到请求量、错误率、延迟、AI 任务和保存失败等业务/应用指标。

因此，Prometheus 不是自动进入容器读取所有业务状态；它主要通过 HTTP 定时拉取各 target 暴露的指标。

参考：[Prometheus 配置和服务发现](https://prometheus.io/docs/prometheus/latest/configuration/configuration/)、[Exporters and integrations](https://prometheus.io/docs/instrumenting/exporters/)。

## 2. 当前 KnowTrace-Workflow 的真实状态

根据 2026-09-07 本地仓库检查：

### 已具备

认证服务 `auth` 已暴露：

```text
http://auth:8082/metrics
```

已有指标包括：

- `go_user_system_http_requests_total`
- `go_user_system_http_request_duration_seconds`
- `go_user_system_http_requests_in_flight`
- `go_user_system_readiness`
- `go_user_system_build_info`
- Go Runtime 和进程指标

已有告警规则包括：

- 指标 target 不可达。
- 认证服务未就绪。
- 5xx 比例超过 5%。
- p95 延迟超过 1 秒。

### 尚未具备

- Next.js 主应用 `app:3000` 没有 Prometheus `/metrics` 路由。
- 根级生产 Compose 没有 Prometheus、Grafana、Alertmanager 或 exporter 服务。
- PostgreSQL、MySQL、Redis 还没有接入专用 exporter。
- VPS 还没有 Node Exporter 主机指标。
- 当前告警规则没有 Alertmanager 通知链路。
- 当前 VPS 阶段三监控部署尚未执行和验证。

### 一个容易踩坑的配置边界

仓库中的：

```text
services/go-user-system/compose.observability.yaml
```

是认证子项目的独立监控 overlay，其中 Prometheus 抓取的是 `app:8082`。根级 KnowTrace-Workflow Compose 中：

- `app` 是 Next.js，端口为 3000。
- `auth` 才是 Go 认证服务，端口为 8082。

所以不能把这个 overlay 原样拼到根级 Compose。根级监控配置应将认证 target 改为：

```yaml
static_configs:
  - targets:
      - auth:8082
```

### 线上暴露检查

2026-09-07 从公网检查：

- `/api/health/live`：HTTP 200。
- `/api/health/ready`：HTTP 200。
- `/metrics`：HTTP 307，跳转到 `/login?next=%2Fmetrics`。

这说明当前没有把内部 Prometheus 指标直接公开到公网。企业环境通常也不应让 `/metrics` 经过公网 Ingress 暴露，而应只允许监控网络或监控命名空间访问。

## 3. 当前单 VPS 的推荐架构

```text
Windows 浏览器
      │ SSH 隧道或 VPN
      ▼
Grafana :3001 ───────► Prometheus :9090
                          │
                          ├── auth:8082/metrics
                          ├── Next app:3000/metrics     当前缺失
                          ├── postgres-exporter
                          ├── mysqld-exporter
                          ├── redis-exporter
                          ├── cadvisor:8080/metrics
                          ├── node-exporter:9100/metrics
                          └── blackbox-exporter:9115

Alert rules ─────────► Alertmanager ─────────► 邮件/聊天/值班渠道
```

对于当前学习环境：

- Prometheus、Grafana 和 exporters 可以使用 Docker Compose。
- Prometheus/Grafana 端口只绑定 `127.0.0.1`。
- Windows 使用 SSH 隧道访问 Grafana。
- 外部可用性探测最好来自另一台机器或外部监控，否则 VPS 整机宕机时，本机 Prometheus 也会一起消失。

如果把 Prometheus 放在 Windows Docker Desktop，它可以抓取 VPS，但 Windows 睡眠、关机或网络中断都会造成采样缺口。因此它适合实验，不适合作为持续生产监控服务器。

## 4. 监控必须分四层

### 4.1 用户体验层

使用 Blackbox Exporter 从外部探测：

- `https://knowtrace.duckdns.org/login`
- `/api/health/live`
- `/api/health/ready`
- HTTPS 证书有效期。

这一层回答：“用户现在能不能访问？”

`up=1` 只代表 Prometheus 成功抓取了 Blackbox Exporter；实际目标是否成功要看 `probe_success`。

### 4.2 应用层

在线 HTTP 服务首先关注 RED：

- Rate：请求量。
- Errors：错误数量或错误比例。
- Duration：请求延迟。

还应关注 in-flight 请求。Prometheus 官方也将请求量、错误和延迟列为在线服务的关键指标。参考：[Instrumentation practices](https://prometheus.io/docs/practices/instrumentation/)。

KnowTrace-Workflow Next.js 主应用建议补充：

```text
knowtrace_http_requests_total{method,route,status}
knowtrace_http_request_duration_seconds{method,route}
knowtrace_http_requests_in_flight{method}
knowtrace_readiness
knowtrace_build_info{version,commit,build_time}
knowtrace_ai_runs_total{provider,status,error_code}
knowtrace_ai_run_duration_seconds{provider,status}
knowtrace_save_operations_total{operation,status}
knowtrace_backup_last_success_timestamp_seconds
knowtrace_backup_duration_seconds
knowtrace_backup_size_bytes
```

不得把用户名、邮箱、Token、记录标题、知识内容或原始 URL 放进 label。每一种 label 组合都会形成新的时间序列，高基数会显著增加 Prometheus 成本。参考：[Metric and label naming](https://prometheus.io/docs/practices/naming/)。

### 4.3 依赖与容器层

| 对象 | 采集方式 | 关注内容 |
|---|---|---|
| PostgreSQL | postgres exporter | 连接数、事务、锁、慢查询趋势、数据库大小 |
| MySQL | mysqld exporter | 连接、查询、锁、Buffer Pool、复制状态（若有） |
| Redis | redis exporter | 内存、命中率、连接、淘汰、AOF/RDB 状态 |
| Docker 容器 | cAdvisor | CPU、内存、网络、文件系统、节流 |
| Ubuntu | Node Exporter | CPU、内存、磁盘、inode、网络、系统负载 |

cAdvisor 会在 `/metrics` 暴露容器和主机统计。参考：[Prometheus cAdvisor 指南](https://prometheus.io/docs/guides/cadvisor/)、[cAdvisor Prometheus metrics](https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md)。

Node Exporter 负责 Linux 硬件和内核相关指标。参考：[Prometheus Node Exporter 指南](https://prometheus.io/docs/guides/node-exporter/)。

### 4.4 数据与恢复层

“数据库在线”不代表“数据可恢复”。Prometheus 还应监控：

- 距离上次成功备份过去了多久。
- 最新备份文件大小是否异常。
- 备份任务持续时间和退出状态。
- 异机复制是否成功。
- 最近一次恢复演练时间。

可以让 Bash 备份脚本写出 Prometheus textfile：

```text
knowtrace_backup_last_success_timestamp_seconds 1788750000
knowtrace_backup_duration_seconds 42
knowtrace_backup_size_bytes 104857600
```

再由 Node Exporter textfile collector 读取。监控只能证明任务报告了成功；每月空环境恢复和业务验证仍不可替代。

## 5. Docker Compose 中如何抓取

同一个 Compose project 默认会创建内部网络，服务可以通过服务名通信。例如 Prometheus target 可以写成：

```yaml
scrape_configs:
  - job_name: knowtrace-auth
    metrics_path: /metrics
    static_configs:
      - targets:
          - auth:8082

  - job_name: cadvisor
    static_configs:
      - targets:
          - cadvisor:8080

  - job_name: node
    static_configs:
      - targets:
          - node-exporter:9100
```

Prometheus 服务本身可以使用容器：

```yaml
services:
  prometheus:
    image: quay.io/prometheus/prometheus:固定版本
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=7d
    ports:
      - "127.0.0.1:9090:9090"
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    restart: unless-stopped
```

正式实施时必须固定经过测试的镜像版本或 digest，不能照抄 `固定版本`。修改配置后先运行 `promtool check config` 和 `promtool check rules`。

## 6. 企业团队通常怎么做

企业里不是“运维装个 Grafana 就结束”，而是开发、平台和 SRE 共同完成可观测性：

### 开发人员

- 在代码中埋点并暴露 `/metrics`。
- 为关键请求和后台任务设置稳定、有限的 label。
- 让日志包含 `request_id`/`trace_id`，但不泄露敏感数据。
- 为新增指标写单元测试。
- 在发布说明中列出指标和告警变化。

### SRE/平台团队

- 维护 Prometheus、Grafana、Alertmanager 和长期存储。
- 通过服务发现自动发现实例。
- 维护告警规则、值班路由、静默和升级策略。
- 用 SLO/错误预算决定哪些问题需要告警。
- 为每条可执行告警关联 runbook。
- 控制 retention、指标基数、资源和权限。

### CI/CD

- `promtool check config` 验证配置。
- `promtool check rules` 验证告警和 recording rules。
- 自动测试 `/metrics` 是否包含约定指标。
- 在测试/预发布环境验证 dashboard 与告警。
- 发布后观察错误率、p95 和就绪状态，再决定继续或回滚。

### Kubernetes

常见做法是 Prometheus Operator 或基于它的监控发行包：

- `ServiceMonitor`/`PodMonitor` 选择要抓取的服务或 Pod。
- `PrometheusRule` 管理告警规则。
- `Alertmanager` 管理通知和聚合。
- Node Exporter、kube-state-metrics 和 kubelet/cAdvisor 提供节点、Kubernetes 对象和容器指标。
- `/metrics` 仅对监控命名空间开放，通过 NetworkPolicy 控制访问，不创建公网 Ingress。

Prometheus Operator 用 Kubernetes CRD 管理 Prometheus、Alertmanager、ServiceMonitor、PodMonitor 和 PrometheusRule。参考：[Prometheus Operator introduction](https://prometheus-operator.dev/docs/getting-started/introduction/)。

规模增大后，企业可能使用两套 Prometheus、远程写入和 Thanos/Mimir 一类长期存储；这是解决高可用、跨集群和长期保留的后续方案，不是当前单 VPS 必须先做的内容。

## 7. 告警设计原则

告警应从用户影响开始，而不是看到任何资源波动都通知：

| 告警 | 条件示例 | 首要动作 |
|---|---|---|
| KnowTracePublicDown | 外部 `probe_success=0` 持续 2 分钟 | 判断 DNS、Caddy、Nginx、应用哪层失败 |
| KnowTraceHigh5xx | 5xx 比例超过基线并持续 | 查看版本、路由和应用日志 |
| KnowTraceHighP95 | p95 超过目标并持续 | 检查 DB、AI 调用和资源饱和 |
| KnowTraceAuthNotReady | auth readiness 为 0 | 区分 MySQL 与 Redis |
| KnowTraceDiskLow | 可用空间低于阈值 | 查明增长来源，不直接删除 volume |
| KnowTraceBackupStale | 上次成功备份超过 26 小时 | 查看 systemd timer 和备份日志 |

每条告警至少包含：服务、环境、严重级别、简短现象、runbook 地址和责任团队。第一次告警阈值只是起点，应根据实际基线和误报情况调整。

## 8. 推荐实施顺序

### 阶段 A：先让链路跑通

1. 在独立 `compose.monitoring.yaml` 中加入 Prometheus 和 Grafana。
2. 将 target 配为 `auth:8082`。
3. 验证 Prometheus Targets 页面显示 `UP`。
4. 查询 `go_user_system_http_requests_total`。
5. 建一个最小 Grafana 面板。

完成标准：不是 Grafana 页面能打开，而是发起登录请求后，计数器和延迟图发生符合预期的变化。

### 阶段 B：补基础设施和外部探测

1. 加入 Node Exporter。
2. 加入 cAdvisor。
3. 加入 Blackbox Exporter。
4. 加入 PostgreSQL、MySQL 和 Redis exporters。
5. 建立主机、容器、依赖和公网四类 dashboard。

### 阶段 C：补 KnowTrace-Workflow 主应用指标

1. 为 Next.js 主应用设计低基数 RED 指标。
2. 增加 AI 运行和保存操作指标。
3. 增加备份新鲜度指标。
4. 添加单元测试、PrometheusRule 和 runbook。

### 阶段 D：故障演练

依次制造：

1. 停止 Grafana，确认外部探测发现并能恢复。
2. 停止 auth，确认 target 与 readiness 告警。
3. 停止 PostgreSQL，区分 live 与 ready。
4. 制造过期 Token 保存失败，确认不会误报数据库故障。
5. 让测试备份任务失败，确认备份过期告警。

每次均记录：现象、告警时间、日志证据、根因、恢复命令、业务验证和恢复耗时。

## 9. 可以用于面试的准确表述

完成 Docker 阶段并留下证据后，可以表述为：

> 在 Ubuntu 单机 Docker Compose 环境中为 KnowTrace-Workflow 接入 Prometheus、Grafana、Node Exporter、cAdvisor、Blackbox Exporter及数据库 exporters；基于应用 RED、主机、容器、依赖和备份新鲜度构建监控与告警，并通过可控故障演练验证发现和恢复流程。

不要表述为“建设企业级高可用监控平台”，除非已经真实完成多副本、独立故障域、通知值班、长期存储、容量验证和持续运行。
