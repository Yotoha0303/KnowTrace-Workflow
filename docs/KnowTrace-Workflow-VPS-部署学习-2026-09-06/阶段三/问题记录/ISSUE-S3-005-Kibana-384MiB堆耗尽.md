# ISSUE-S3-005：Kibana 384 MiB Node 堆耗尽

> ⚠️ **已过期（2026-10-03 起）：本文涉及的 ELK 栈已被 PLG（Alloy + Loki）替换并删除。**
> 本文保留为**历史证据 / 可迁移教训**。其中的 ELK 操作步骤、端口 9200/5601、
> `scripts/linux/elk.sh`、`deploy/logstash/` 与两个 `logging-*` 网络**均已不存在**，
> **不要照着执行**。现行口径见 `docs/16-stage3-observability.md`
> 与 `docs/日常运维/运维手册.md`；换栈记录见
> `docs/changes/2026-10-03-ELK换PLG与deploy重构及Ansible引入.md`。


- 范围：按需 ELK 首次启动。
- 状态：已关闭。
- 修复 commit：`d4927e8`。
- 影响：Kibana 退出，ELK 完整验收未通过；脚本自动停止 ELK，业务继续运行。

## 证据

```text
container exit=134
OOMKilled=false
FATAL ERROR: Ineffective mark-compacts near heap limit
Allocation failed - JavaScript heap out of memory
```

## 根因

Kibana 8.19 启动大量内置插件和模板时，显式设置的 384 MiB Node old-space 不足。`OOMKilled=false` 说明不是 Linux OOM Killer。

## 修复

- Kibana Node 堆：384 MiB → 512 MiB。
- Kibana 容器上限：600 MiB → 768 MiB。
- Logstash 容器上限：384 MiB → 512 MiB，为启动和队列留出余量。

## 验证

- Kibana healthy，`/api/status` 200。
- Kibana reported heap size limit 560 MiB 左右，启动完成。
- ELK 端到端验证连续通过。
- 未发生容器 OOM。

## 运行边界

ELK 运行期间可用内存曾降到约 290～409 MiB，Swap 使用约 2.0 GiB。因此它只适合本 VPS 的短时实验，不适合常驻或生产负载。
