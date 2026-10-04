# ISSUE-S3-007：ELK 默认停止超时导致退出码 137

> ⚠️ **已过期（2026-10-03 起）：本文涉及的 ELK 栈已被 PLG（Alloy + Loki）替换并删除。**
> 本文保留为**历史证据 / 可迁移教训**。其中的 ELK 操作步骤、端口 9200/5601、
> `scripts/linux/elk.sh`、`deploy/logstash/` 与两个 `logging-*` 网络**均已不存在**，
> **不要照着执行**。现行口径见 `docs/16-stage3-observability.md`
> 与 `docs/日常运维/运维手册.md`；换栈记录见
> `docs/changes/2026-10-03-ELK换PLG与deploy重构及Ansible引入.md`。


- 范围：ELK 验证后关停。
- 状态：已关闭。
- 修复 commit：`c6dc954`。
- 影响：Elasticsearch 和 Logstash 在默认 10 秒内未完成优雅关闭，被强制 SIGKILL；数据卷未删除。

## 首次证据

```text
Elasticsearch exit=137 OOMKilled=false
Logstash       exit=137 OOMKilled=false
Kibana         exit=0   OOMKilled=false
```

## 根因

退出码 137 同时可能来自 OOM 或 SIGKILL。这里 `OOMKilled=false`，且发生在 `docker compose stop` 的默认等待期之后，根因是优雅停止时间不足。

## 修复

- 三个 ELK 服务设置 `stop_grace_period: 60s`。
- `elk.sh stop` 和失败清理显式使用 `--timeout 60`。

## 最终回归

```text
start=2026-09-08T05:26:20Z
finish=2026-09-08T05:27:22Z
Elasticsearch exit=143 OOMKilled=false
Logstash       exit=0   OOMKilled=false
Kibana         exit=0   OOMKilled=false
```

Elasticsearch 的 143 是收到 SIGTERM；9200/5000/5601 均停止监听，核心监控仍通过。

## 经验

看到 137 必须同时检查 `OOMKilled`、操作时间线、内核日志和 stop timeout，不能只凭退出码认定 OOM。
