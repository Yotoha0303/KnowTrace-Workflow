# BUG-S2-004：Docker cp 无法从 fixture tmpfs 导出 RDB

- 发现时间：2026-09-07。
- 环境：Windows Docker Desktop 29.6.2、Redis tmpfs `/data`。
- 严重度：中；影响脚本的存储后端兼容性。
- 状态：已规避并通过本地隔离回归；普通 Linux volume 行为仍待 VPS 验证。

## 证据

容器内检查：

```text
-rw------- redis redis 164 /data/dump.rdb
test -s /data/dump.rdb: exit=0
```

但 Compose 和 Docker archive API 均返回：

```text
Could not find the file /data/dump.rdb in container ...
```

## 处理

- 不假定固定路径，使用 Redis `CONFIG GET dir` 与 `dbfilename` 获取并校验实际路径。
- 不再依赖 `docker cp` 导出 RDB，改用无 TTY 的容器内 `cat` 将二进制流写入备份文件。
- 对导出文件执行非空检查和 SHA-256，随后在临时 Redis 中用 `redis-check-rdb` 与真实加载验证。

## 回归

最终 RDB 导出成功，隔离 Redis 恢复 2/2 key，整个恢复脚本退出码 0。
