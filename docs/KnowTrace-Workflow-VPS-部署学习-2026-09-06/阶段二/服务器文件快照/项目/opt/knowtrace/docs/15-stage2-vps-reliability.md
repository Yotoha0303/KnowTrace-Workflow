# VPS 阶段二：备份、恢复、压测与故障迭代

## 1. 阶段目标与证据边界

阶段二不是“生成了一个 dump 文件”就算完成。验收分为五条相互独立的证据链：

1. 备份：PostgreSQL、认证 MySQL、Redis 会话状态、`data/uploads` 与恢复配置均进入同一备份集，并有 SHA-256 清单。
2. 恢复：备份实际恢复到隔离临时容器，数据库表行数与上传文件统计一致，且没有连接或挂载生产资源。
3. 异地：至少一份备份离开 VPS，并在传输前或落盘时加密；解密私钥/口令不得与密文放在一起。
4. 压测：先测只读健康端点，再测业务读路径；保留请求规模、并发、错误率、P95/P99 与服务器资源证据。
5. 迭代：每次发布都能关联版本、变更、测试、发布前备份、上线验证、Bug/故障记录和回滚点。

这些证据只能证明当前单 VPS、当前样本和当前时间窗口。它们不能证明高可用、长期容量、真实用户体验或多节点扩展能力。

## 2. 备份范围与一致性

| 组件 | 内容 | 备份方式 | 验证方式 |
| --- | --- | --- | --- |
| PostgreSQL | KnowTrace 业务、AI Run、主张与证据链 | `pg_dump` custom format | `pg_restore` 到临时 PostgreSQL，并逐表比对行数 |
| MySQL | 账号、密码哈希、角色与 refresh token | `mysqldump --single-transaction` | 导入临时 MySQL，并逐表比对行数 |
| Redis | 登录会话/限流等短期状态 | RDB 快照 | 临时 Redis 加载、`redis-check-rdb` 与 key 数核对 |
| 上传目录 | 证据图片等文件 | `tar.gz` | 解包并核对文件数和总字节数 |
| 恢复配置 | `.env`、Compose、Caddy、Nginx、SSH 配置 | root-only 文件副本 | SHA-256 清单；人工检查恢复所需字段 |

`scripts/linux/backup-all.sh` 默认设置 `QUIESCE_WRITES=1`，会短暂停止 `app` 和 `auth` 两个写入入口，然后再导出四类数据。反向代理仍会运行，但维护窗口内请求可能暂时返回 502。脚本在成功或失败退出时都会尝试恢复服务，并在最后检查两个 ready 端点。

若显式设置 `QUIESCE_WRITES=0`，各存储只能获得各自一致的快照，不能声称整个业务在同一时点原子一致。

## 3. 标准备份流程

### 3.1 备份前

```bash
cd /opt/knowtrace
git status --short --branch
docker compose -f compose.yaml -f compose.production.yaml ps
df -h / /var/lib/docker /var/backups
free -h
curl -fsS http://127.0.0.1:3000/api/health/ready
curl -fsS http://127.0.0.1:8082/readyz
```

在低流量维护窗口执行，并先向使用者说明会有短暂不可用。不要在磁盘接近写满、数据库不健康或仍有未解释故障时盲目开始。

### 3.2 执行

```bash
sudo install -d -m 700 /var/backups/knowtrace
sudo PROJECT_DIR=/opt/knowtrace \
  BACKUP_ROOT=/var/backups/knowtrace \
  QUIESCE_WRITES=1 \
  /opt/knowtrace/scripts/linux/backup-all.sh \
  | sudo tee /var/log/knowtrace-backup-last.log
```

成功输出必须同时出现 `BACKUP_ARCHIVE=` 与 `BACKUP_SHA256=`。目录名以 `.incomplete-` 开头表示任务失败后的诊断现场，不得当成有效备份使用。

### 3.3 立即验证

```bash
archive=/var/backups/knowtrace/knowtrace-YYYYmmddTHHMMSSZ-xxxxxxxx.tar.gz
(cd "$(dirname "$archive")" && sha256sum -c "$(basename "$archive").sha256")
sudo /opt/knowtrace/scripts/linux/verify-restore.sh "$archive" \
  | sudo tee /var/log/knowtrace-restore-check-last.log
```

只有退出码为 0 且输出 `RESTORE_VERIFY=PASS`，才能记录为“已通过隔离恢复验证”。验证器按 PostgreSQL、MySQL、Redis 顺序启动临时容器，不发布端口、不加入生产网络、不挂载生产卷，并在结束时只删除 `knowtrace-restore-check-*` 前缀的容器。

这项检查验证归档可恢复及数据统计，不等同于完整浏览器业务旅程。灾难恢复演练还需要在隔离环境完成登录、查询一条已知记录和读取一张已知图片。

### 3.4 定时执行与保留策略

仓库提供每日备份单元。它在 Asia/Shanghai 03:20 后的五分钟随机窗口执行一致性备份，因此该时段可能短暂返回 502；默认删除超过 14 天的旧备份集，但无论时间如何至少保留最近 7 份。删除器只接受脚本生成的严格文件名，并同时删除对应目录、校验文件和 VPS 上的加密副本。

```bash
sudo chmod 700 /opt/knowtrace/scripts/linux/backup-all.sh
sudo chmod 700 /opt/knowtrace/scripts/linux/prune-backups.sh
sudo install -m 644 deploy/systemd/knowtrace-backup.service /etc/systemd/system/knowtrace-backup.service
sudo install -m 644 deploy/systemd/knowtrace-backup.timer /etc/systemd/system/knowtrace-backup.timer
sudo systemctl daemon-reload
sudo systemctl enable --now knowtrace-backup.timer
systemctl list-timers knowtrace-backup.timer --all
```

查看最近执行结果与日志：

```bash
systemctl status knowtrace-backup.service --no-pager
journalctl -u knowtrace-backup.service --since today --no-pager
```

回滚定时任务不会删除任何已有备份：

```bash
sudo systemctl disable --now knowtrace-backup.timer
sudo rm -f /etc/systemd/system/knowtrace-backup.timer /etc/systemd/system/knowtrace-backup.service
sudo systemctl daemon-reload
```

## 4. 加密异地副本

备份含账号资料、密码哈希、知识内容、会话状态和 `.env`，不得把明文归档提交 Git、放进公开网盘或复制到项目输出目录。

推荐使用独立的 `age` 密钥：私钥只保存在管理员工作站受限目录，VPS 只保存公钥。VPS 先用公钥生成 `.age`，工作站下载密文并核对 SHA-256；随后执行一次解密到临时受限目录和归档校验。密钥轮换、恢复演练与备份保留策略应分别记录。

在尚未完成“密文已离开 VPS + 可解密 + 可校验”前，状态只能写“本机备份已验证”，不能写“异地备份完成”。

## 5. 低风险压测流程

### 5.1 采集前置状态

```bash
date -u
uptime
free -h
df -h /
docker stats --no-stream
docker compose -f compose.yaml -f compose.production.yaml ps
```

### 5.2 第一档：健康端点基线

```bash
python3 scripts/linux/load-baseline.py \
  http://127.0.0.1:8080/api/health/ready \
  --requests 200 \
  --concurrency 5 \
  --output /tmp/knowtrace-health-c5.json
```

脚本只允许 GET，请求数最多 5000、并发最多 50。第一档通过标准：期望状态码比例 100%、没有网络错误，并保存 P50/P95/P99、RPS 与服务端资源快照。

### 5.3 第二档：公网链路与业务读取

第一档无错误后，才从 VPS 外的工作站测试 HTTPS 健康端点。代理、工作站网络与地理距离都会进入延迟结果，必须一并记录。业务读取测试应使用专门测试账号和只读数据；登录、注册、写入与上传接口不能拿健康端点脚本直接轰击。

Windows Python 的默认 CA 来源可能不同于系统证书存储。若默认校验失败，应先用浏览器、curl/OpenSSL 和证书有效期交叉确认，再通过 `--ca-file <可信 PEM CA 包>` 明确指定 CA；需要直连时同时使用 `--no-proxy`。脚本不提供跳过 TLS 校验的选项，不能用“不验证证书”制造通过结果。

```powershell
$CaFile = python -m certifi
python scripts/linux/load-baseline.py `
  https://knowtrace.duckdns.org/api/health/ready `
  --requests 200 `
  --concurrency 5 `
  --ca-file $CaFile `
  --no-proxy
```

压测后再次采集 `docker stats --no-stream`、ready 端点和相关容器日志。一次 200 请求/并发 5 的结果只是基线，不是“支持 5 并发用户”或“生产容量”的证据。

## 6. Bug 与真实故障流程

Bug 是可复现的软件行为偏差；故障是对可用性、数据、安全或运维能力造成影响的事件。两者可以关联，但不能混写。

每个 Bug 文件至少记录：

- ID、发现时间、环境与版本；
- 预期、实际、最小复现步骤；
- 请求/响应、日志、截图等脱敏证据；
- 影响范围、严重度、临时规避；
- 根因（未知时明确写未知）、修复提交与回归测试。

每个故障文件按以下顺序记录：

1. 发现与影响评估；
2. 时间线和原始证据；
3. 事实、假设和未知项分开；
4. 先止损，再定位，再恢复；
5. ready/业务/日志三类恢复验证；
6. 根因、诱因、改进项、责任人与截止时间；
7. 将可复现的软件缺陷另建 Bug 并互相链接。

不得为了制造学习案例在生产库删除数据、关闭防火墙、停用 TLS 或破坏 SSH。故障演练应在临时容器或明确维护窗口进行。

## 7. 版本迭代与回滚门禁

```text
需求/Bug → 独立分支 → 本地质量门禁 → 发布前备份与隔离恢复
         → 记录旧 commit/镜像 → 部署 → ready + 关键业务验证
         → 观察日志 → 标记发布结果或按旧版本回滚
```

每次迭代至少保留：

- 变更分支和 commit；
- `git diff --check`、单元测试、类型检查、构建结果；
- 发布前备份 ID 与 `RESTORE_VERIFY=PASS` 证据；
- 部署前后的镜像/commit、UTC 时间和操作者；
- HTTPS ready、认证 ready、登录和一条关键业务读取结果；
- 观察窗口内的 Caddy、Nginx、app、auth 与数据库错误摘要；
- 回滚命令和实际回滚点。

数据库迁移向前兼容时可回滚应用镜像；若迁移不可逆，则必须先停止写入，并依据已验证备份恢复。禁止把 `docker compose down --volumes` 当作普通排障或回滚命令。

## 8. 阶段二完成定义

- [ ] 服务器生成全量备份集和 SHA-256 清单。
- [ ] 隔离恢复脚本输出 `RESTORE_VERIFY=PASS`。
- [ ] 对已知业务记录完成读取验证并留证。
- [ ] 加密副本已离开 VPS，且完成解密校验。
- [ ] 每日定时器已启用，下一次执行时间和 journald 日志已验证。
- [ ] 健康端点低并发基线无错误，资源与日志证据齐全。
- [ ] 至少一个 Bug 使用模板完成闭环；没有真实 Bug 时不得虚构。
- [ ] 至少一个真实故障按时间线完成处理与复盘。
- [ ] 至少一个版本按门禁发布或演练回滚，并能定位到 commit。

全部勾选后才能宣布阶段二完成；其中任何单项通过都不能替代其他单项。
