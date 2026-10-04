# BUG-S2-001：Redis BGSAVE 完成判定竞态

- 发现时间：2026-09-07。
- 环境：本地隔离 Compose fixture，Redis 7.4.11。
- 版本：`0064f87` 后的未提交回归修改。
- 严重度：高；可能生成缺失 Redis 组件的备份。
- 状态：已修复并通过本地隔离回归，VPS 待验证。

## 预期与实际

- 预期：新触发的 BGSAVE 完成后再导出 RDB。
- 实际：`BGSAVE SCHEDULE` 后首次轮询读到旧的 `rdb_bgsave_in_progress:0` 和 `rdb_last_bgsave_status:ok`，过早进入复制；新 RDB 几毫秒后才生成。

## 证据

```text
Error response from daemon: Could not find the file /data/dump.rdb
Redis log 随后显示 Background saving started / DB saved on disk / terminated with success
```

## 根因与修复

- 根因：只检查状态值，没有证明该状态属于本次请求。
- 修复：先等旧任务结束，记录 `rdb_saves`，执行 BGSAVE 后要求计数严格递增、任务归零且最后状态为 `ok`。
- 回归：最终备份成功，RDB 在临时 Redis 中加载，2/2 key 恢复。

## VPS 待验证

- [ ] 真实 Redis volume 上运行。
- [ ] 日志中的 `rdb_saves` 与备份时间对应。
- [ ] 隔离恢复 key 数与 TTL 过期差异已解释。
