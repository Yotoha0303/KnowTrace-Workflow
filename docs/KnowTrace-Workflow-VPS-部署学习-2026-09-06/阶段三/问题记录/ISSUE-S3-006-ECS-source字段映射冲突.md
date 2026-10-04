# ISSUE-S3-006：验证事件与 ECS source 字段映射冲突

> ⚠️ **已过期（2026-10-03 起）：本文涉及的 ELK 栈已被 PLG（Alloy + Loki）替换并删除。**
> 本文保留为**历史证据 / 可迁移教训**。其中的 ELK 操作步骤、端口 9200/5601、
> `scripts/linux/elk.sh`、`deploy/logstash/` 与两个 `logging-*` 网络**均已不存在**，
> **不要照着执行**。现行口径见 `docs/16-stage3-observability.md`
> 与 `docs/日常运维/运维手册.md`；换栈记录见
> `docs/changes/2026-10-03-ELK换PLG与deploy重构及Ansible引入.md`。


- 范围：Logstash → Elasticsearch 端到端验收。
- 状态：已关闭。
- 修复 commit：`2bd564b`。
- 影响：验证事件进入 Logstash，但 Elasticsearch 以 400 拒绝并写入 DLQ。

## 证据

当时索引已经有 809 条真实日志，说明管道并非整体失效。Logstash 报错：

```text
document_parsing_exception
object mapping for [source] tried to parse field [source] as object,
but found a concrete value
```

## 根因

ECS 日志已把 `source` 建成对象；验证事件把它作为脚本路径字符串，产生同一索引内的类型冲突。

## 修复

把验证事件字段从通用 `source` 改为项目专用 `verification_source`。没有删除索引、强改 mapping 或绕过 Logstash。

## 验证

```text
Logstash TCP input accepted
Elasticsearch event search: hits=1
```

## 经验

向共享日志索引加入字段前先遵循 ECS 命名；出现 mapping 冲突时优先改事件模型，不要删除有证据价值的索引。
