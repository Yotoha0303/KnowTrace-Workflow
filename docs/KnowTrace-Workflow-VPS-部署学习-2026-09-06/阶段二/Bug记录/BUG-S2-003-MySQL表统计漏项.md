# BUG-S2-003：MySQL 表统计因 stdin 被消费而漏项

- 发现时间：2026-09-07。
- 环境：Git Bash 调用 Docker Compose fixture。
- 严重度：高；恢复验证基线不完整，会形成假阳性风险。
- 状态：已修复并通过本地隔离回归，VPS 待验证。

## 预期与实际

- dump 中存在 `roles` 和 `users` 两张表。
- 初版 `mysql-counts.tsv` 只记录 `roles=2`。
- 恢复后的真实统计包含两张表，因此 `verify-restore.sh` 正确报差异并拒绝通过。

## 根因与修复

- 根因：`while read` 使用 stdin 读取表名；循环内的 `docker compose exec -T` 仍连接 stdin，在第一次查询时消费了剩余表名。
- 修复：每个容器计数查询显式使用 `</dev/null`。
- 回归：新备份基线包含 `roles=2` 和 `users=2`，恢复逐表比较通过。

## 学习结论

`-T` 只是禁用伪终端，不等同于禁用交互 stdin。流式循环中调用外部命令时必须明确其标准输入来源。
