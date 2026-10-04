# 阶段二：备份、压测、Bug、真实故障与迭代

## 阶段结果

服务器侧备份与隔离恢复、加密异地副本、定时保留、低风险健康基线、Bug 修复和一次真实 SSH 事件已经完成。业务账号登录、历史记录和真实附件读取仍待验证。

完整 Runbook：`服务器文件快照/项目/opt/knowtrace/docs/15-stage2-vps-reliability.md`。

## 1. 关键脚本

| 文件 | 作用 |
| --- | --- |
| `scripts/linux/backup-all.sh` | 一致性备份 PostgreSQL、MySQL、Redis、uploads 与配置 |
| `scripts/linux/verify-restore.sh` | 在隔离临时容器恢复并比对数据统计 |
| `scripts/linux/prune-backups.sh` | 14 天且至少保留 7 份 |
| `scripts/linux/load-baseline.py` | 有上限的只读 HTTP 基线工具 |
| `deploy/systemd/knowtrace-backup.*` | 每日定时备份单元 |

本地路径前缀：`服务器文件快照/项目/opt/knowtrace/`。

## 2. 标准备份与恢复

执行备份前会短暂停止 app/auth 写入口，应安排维护窗口：

```bash
cd /opt/knowtrace
free -h
df -h / /var/backups
docker compose -f compose.yaml -f compose.production.yaml ps
curl -fsS http://127.0.0.1:3000/api/health/ready
curl -fsS http://127.0.0.1:8082/readyz

sudo PROJECT_DIR=/opt/knowtrace \
  BACKUP_ROOT=/var/backups/knowtrace \
  QUIESCE_WRITES=1 \
  scripts/linux/backup-all.sh
```

随后验证归档和隔离恢复：

```bash
archive=/var/backups/knowtrace/knowtrace-YYYYmmddTHHMMSSZ-xxxxxxxx.tar.gz
(cd "$(dirname "$archive")" && sha256sum -c "$(basename "$archive").sha256")
sudo scripts/linux/verify-restore.sh "$archive"
```

只有输出 `RESTORE_VERIFY=PASS`，才能说“归档通过隔离恢复验证”。这仍不替代浏览器登录、历史记录和真实附件读取。

## 3. 定时器

```bash
sudo install -m 644 deploy/systemd/knowtrace-backup.service \
  /etc/systemd/system/knowtrace-backup.service
sudo install -m 644 deploy/systemd/knowtrace-backup.timer \
  /etc/systemd/system/knowtrace-backup.timer
sudo systemctl daemon-reload
sudo systemctl enable --now knowtrace-backup.timer
systemctl list-timers knowtrace-backup.timer --all
journalctl -u knowtrace-backup.service --since today --no-pager
```

本地同时保存了仓库版本和 `/etc/systemd/system` 的已安装版本，可以比较是否发生漂移。

## 4. 压测基线

```bash
python3 scripts/linux/load-baseline.py \
  http://127.0.0.1:8080/api/health/ready \
  --requests 200 \
  --concurrency 5 \
  --output /tmp/knowtrace-health-c5.json
```

已记录结果：内部 Nginx 177.349 RPS、P95 47.065 ms；公网 HTTPS 11.744 RPS、P95 1085.687 ms；两组均 200 请求、并发 5、零失败。这只是健康端点的短时基线，不是业务容量或“支持 5 个并发用户”的证明。

## 5. Bug、真实故障和迭代

- 隔离 fixture 中修复了 Redis 快照完成判定、MySQL 就绪误判、Compose stdin 消耗和 Redis RDB 导出等问题；
- SSH 事件最终确认是客户端仍使用旧端口，不是 sshd 宕机；
- 发布流程保留独立分支、测试门禁、发布前备份、VPS commit 和回滚点；
- 受控重启后约 23 秒恢复 HTTPS，不能把一次结果当作长期 SLA。

## 6. 材料入口

- `文档/07-备份巡检与故障处理SOP.md`
- `文档/01-阶段二执行清单.md`
- `文档/2026-09-08-阶段二远端执行结果.md`
- `文档/2026-09-07-本地备份恢复与Bug演练.md`
- `文档/INC-S2-001-SSH管理入口拒绝连接.md`
- `SOP/`、`Bug记录/`、`故障记录/`、`问题记录/`：从D盘旧包吸收的完整分类记录；
- `证据/`：真实备份、压测、发布和受控重启的脱敏证据；
- `异地备份/`：仅保留说明和哈希，不包含加密归档本体；
- `服务器文件快照/`

真实备份归档、数据库 dump、Redis RDB、`.env` 和上传内容没有复制进学习包。
