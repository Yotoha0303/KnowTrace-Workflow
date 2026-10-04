# KnowTrace-Workflow 备份、巡检与故障处理 SOP

> 适用环境：单台 Ubuntu 24.04 VPS、Docker Compose、Caddy、Nginx、KnowTrace-Workflow、PostgreSQL、MySQL、Redis。
>
> 证据边界：本文是阶段二的执行手册。只有实际完成备份、异机复制、空环境恢复和业务验证后，才能宣称具备经过验证的恢复能力。

## 1. 核心闭环

KnowTrace-Workflow 的运维闭环不是“生成一个备份文件”，而是：

```text
备份成功
  → 校验备份
  → 复制到异机加密存储
  → 在隔离空环境恢复
  → 登录并验证真实业务
  → 记录 RPO、RTO 和问题
```

当前仓库已经有 PostgreSQL、MySQL、上传文件的 PowerShell 备份工具；阶段二分支新增了 VPS Bash 全量备份、Redis 快照和隔离恢复校验脚本，并已通过本地语法检查，但尚未上传 VPS 或执行。生产 VPS 恢复演练和业务验证仍未完成。

## 2. 要保护的资产

| 资产 | 当前位置 | 丢失影响 | 第一阶段策略 |
|---|---|---|---|
| 知识库、记录、证据链 | PostgreSQL Docker volume | 核心业务数据丢失 | 每日 `pg_dump` |
| 用户、角色、密码哈希 | MySQL Docker volume | 无法登录、权限数据丢失 | 每日 `mysqldump` |
| 会话和 Token 撤销状态 | Redis AOF/volume | 用户被迫重新登录，撤销状态可能丢失 | 停止认证写入后生成 RDB |
| 上传附件 | `/opt/knowtrace/data/uploads` | 数据记录存在但附件打不开 | 与数据库同批压缩 |
| 密钥与环境变量 | `/opt/knowtrace/.env` | 服务无法正常启动或认证 | 加密后异机保存 |
| 部署配置 | Compose、Caddy、Nginx | 无法快速重建服务 | Git 加配置归档 |
| 程序版本 | Git 提交 | 无法确定恢复版本 | 每批备份记录 commit |

GitHub 保存的是代码，不是数据库备份；Docker volume 也是运行数据，不是灾难备份，因为 VPS 磁盘损坏时 volume 会一起丢失。

## 3. 第一阶段恢复目标

- RPO：最多允许丢失 24 小时数据。
- RTO：4 小时内从空环境恢复。
- 每日备份一次。
- VPS 保留最近 7 天。
- Windows 加密目录或对象存储保留最近 30 天。
- 每月完成一次隔离恢复。
- 每次数据库结构升级后额外执行一次恢复测试。

这些是学习阶段的目标，不是已经达到的 SLA。需要连续运行记录和恢复演练证据才能将其写成实际成果。

## 4. 第一次手动备份

第一次不要先设置定时任务。安排维护窗口，逐条执行并理解结果。

### 4.1 登录并确认环境

```bash
ssh -i ~/.ssh/你的密钥 root@服务器IP
cd /opt/knowtrace

compose=(docker compose -f compose.yaml -f compose.production.yaml)
"${compose[@]}" ps

date
uptime
free -h
df -hT /
df -ih /

curl -fsS http://127.0.0.1:3000/api/health/live
curl -fsS http://127.0.0.1:3000/api/health/ready
curl -fsS http://127.0.0.1:8082/readyz
```

任一就绪检查失败时，不要开始正常备份流程，先按故障流程记录和定位。

### 4.2 创建受保护的备份目录

```bash
umask 077
backup_time="$(date +%Y%m%d-%H%M%S)"
backup_dir="/var/backups/knowtrace/$backup_time"

mkdir -p "$backup_dir"
git rev-parse HEAD > "$backup_dir/git-commit.txt"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$backup_dir/backup-time.txt"
```

先输出并人工核对 `backup_dir`，确认它位于 `/var/backups/knowtrace/`，再继续。

### 4.3 进入短暂只读窗口

为了让 PostgreSQL、MySQL、Redis 和附件尽量处在同一个业务时间点，第一次演练暂时停止业务入口，但不要停止数据库：

```bash
"${compose[@]}" stop app auth
```

### 4.4 备份 PostgreSQL

```bash
"${compose[@]}" exec -T postgres \
  pg_dump -U knowtrace -d knowtrace \
  -Fc --create --no-owner --no-privileges \
  > "$backup_dir/knowtrace.dump"

"${compose[@]}" exec -T postgres \
  pg_restore --list \
  < "$backup_dir/knowtrace.dump" > /dev/null
```

`-Fc` 生成 PostgreSQL custom-format 归档，可以用 `pg_restore` 检查并选择性恢复。参考：[PostgreSQL pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html)。

### 4.5 备份 MySQL

```bash
"${compose[@]}" exec -T auth-mysql sh -c \
  'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump \
  -uroot \
  --single-transaction \
  --quick \
  --routines \
  --triggers \
  --events \
  --set-gtid-purged=OFF \
  go_user_system' \
  > "$backup_dir/go_user_system.sql"
```

这里显式包含存储过程、触发器和事件。参考：[MySQL mysqldump stored programs](https://dev.mysql.com/doc/refman/8.0/en/mysqldump-stored-programs.html)。

### 4.6 生成 Redis RDB 备份

```bash
"${compose[@]}" exec -T auth-redis redis-cli BGSAVE

while "${compose[@]}" exec -T auth-redis redis-cli INFO persistence \
  | tr -d '\r' \
  | grep -q '^rdb_bgsave_in_progress:1$'
do
  sleep 1
done

"${compose[@]}" exec -T auth-redis redis-cli INFO persistence \
  | grep -E 'rdb_last_bgsave_status|rdb_last_save_time'

"${compose[@]}" exec -T auth-redis redis-check-rdb /data/dump.rdb
"${compose[@]}" cp auth-redis:/data/dump.rdb "$backup_dir/redis-dump.rdb"
```

不要在 AOF 重写期间直接复制 Redis 多段 AOF 文件。参考：[Redis persistence](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)。

### 4.7 备份附件与配置

```bash
tar -C /opt/knowtrace \
  -czf "$backup_dir/uploads.tar.gz" \
  data/uploads

tar -C / \
  -czf "$backup_dir/configs.tar.gz" \
  opt/knowtrace/.env \
  opt/knowtrace/compose.production.yaml \
  etc/caddy/Caddyfile \
  etc/nginx/sites-available/knowtrace.conf

chmod -R go-rwx "$backup_dir"
```

`configs.tar.gz` 包含敏感密钥，不得加入 Git，不得发送到公开网盘。

### 4.8 恢复服务

即使前面的备份步骤失败，也要明确执行本节恢复业务服务，再处理失败原因。

```bash
"${compose[@]}" start auth

until curl -fsS http://127.0.0.1:8082/readyz >/dev/null; do
  sleep 2
done

"${compose[@]}" start app

until curl -fsS http://127.0.0.1:3000/api/health/ready >/dev/null; do
  sleep 2
done
```

### 4.9 生成校验清单

```bash
cd "$backup_dir"

sha256sum \
  knowtrace.dump \
  go_user_system.sql \
  redis-dump.rdb \
  uploads.tar.gz \
  configs.tar.gz \
  git-commit.txt \
  backup-time.txt \
  > manifest.sha256

sha256sum -c manifest.sha256
ls -lh
```

全部文件必须显示 `OK`，并人工检查数据库文件不是 0 字节。

### 4.10 复制到 Windows 异机存储

在 Windows PowerShell 执行：

```powershell
scp -P 你的SSH端口 -i "你的密钥路径" -r `
  root@服务器IP:/var/backups/knowtrace/备份时间 `
  "D:\KnowTrace-Backups\"
```

目标目录应位于 BitLocker 或其他加密存储中。在 Windows 端再次校验 SHA-256。只保存在同一台 VPS 上不能防止整机或磁盘故障。

## 5. 恢复演练

第一次恢复必须使用本地 Docker Desktop、第二台测试 VPS 或隔离的 Compose project，不要覆盖线上数据库。

恢复完成标准：

- PostgreSQL custom dump 能导入空数据库。
- MySQL SQL 能导入空数据库，用户、角色与权限存在。
- Redis RDB 能启动；若选择“不恢复会话”，必须明确执行全员重新登录策略。
- 上传附件数量和 SHA-256 与备份一致。
- 使用备份中记录的 Git commit 构建应用。
- `/api/health/ready` 和认证 `/readyz` 返回成功。
- 已知测试账号能够登录。
- 能查看历史知识记录、证据链和一份历史附件。
- 能创建、修改、保存和删除一条合成测试记录。
- 记录备份数据时间、恢复开始时间和业务恢复时间。
- 计算实际 RPO 和 RTO。

只有容器启动不算恢复成功，必须完成业务验证。

## 6. 日常巡检

### 6.1 每日五分钟巡检

```bash
date
uptime
free -h
df -hT /
df -ih /

systemctl is-active docker nginx caddy

cd /opt/knowtrace
compose=(docker compose -f compose.yaml -f compose.production.yaml)
"${compose[@]}" ps -a

curl -fsS http://127.0.0.1:3000/api/health/live
curl -fsS http://127.0.0.1:3000/api/health/ready
curl -fsS http://127.0.0.1:8082/readyz
curl -fsS http://127.0.0.1:8080/api/health/ready
curl -fsS https://knowtrace.duckdns.org/api/health/ready

"${compose[@]}" logs --since=24h --tail=200 app
"${compose[@]}" logs --since=24h --tail=200 auth
journalctl -u caddy --since "24 hours ago" --no-pager
tail -n 100 /var/log/nginx/knowtrace.error.log

ls -lah /var/backups/knowtrace
```

### 6.2 初始告警阈值

| 检查项 | 警告 | 紧急 |
|---|---:|---:|
| 磁盘使用率 | 大于等于 80% | 大于等于 90% |
| 最新成功备份年龄 | 超过 26 小时 | 超过 48 小时 |
| 容器重启次数 | 大于 0，要求调查 | 持续增加 |
| ready 接口 | 偶发失败 | 连续失败 |
| TLS 证书剩余时间 | 少于 30 天 | 少于 7 天 |
| 备份校验 | — | 任意文件校验失败 |

这些阈值是第一版，应根据一个月的实际基线调整。

### 6.3 每周巡检

- 检查最新备份大小，异常变小必须调查。
- 抽查一批备份的 `sha256sum -c manifest.sha256`。
- 检查 Docker、上传目录和日志磁盘增长。
- 检查公网监听端口、UFW 和 TLS 证书。
- 检查是否出现持续重启或 OOM。

```bash
docker system df
du -sh /opt/knowtrace/data/uploads
du -sh /var/lib/docker
ss -lntup
ufw status verbose
```

不要将 `docker compose down --volumes` 用作普通排障命令，它可能删除业务数据卷和监控历史。

### 6.4 每月巡检

- 在隔离环境恢复最新备份。
- 执行登录、数据读取、附件读取和写入冒烟测试。
- 记录实际恢复耗时。
- 制造一次可控故障，完成发现、告警、取证、恢复和复盘。

## 7. 故障处理流程

统一采用：

```text
判断影响
  → 保留现场证据
  → 分层定位
  → 最小范围恢复
  → 健康检查
  → 业务验证
  → 持续观察
  → 故障记录
```

### 7.1 现象与优先检查层

| 现象 | 优先检查 |
|---|---|
| 域名完全打不开 | DNS、Caddy、UFW、安全组 |
| 公网 502，但本机应用正常 | Caddy/Nginx 代理链 |
| `/live` 成功、`/ready` 失败 | PostgreSQL 或应用依赖 |
| 应用 ready 成功、登录失败 | auth、MySQL、Redis、Token |
| 页面停留一段时间后保存失败 | Token 过期、重定向、错误页误报 |
| 多项服务同时异常 | 磁盘满、内存、Docker、主机网络 |

KnowTrace-Workflow 曾出现访问令牌过期后，保存请求被重定向到登录页，但全局错误页面显示“数据库故障”的情况。如果 ready 正常，不应立即重启 PostgreSQL。

### 7.2 先取证，再重启

```bash
date
uptime
free -h
df -hT /
ss -lntup

cd /opt/knowtrace
compose=(docker compose -f compose.yaml -f compose.production.yaml)

"${compose[@]}" ps -a
"${compose[@]}" logs --since=30m --timestamps app
"${compose[@]}" logs --since=30m --timestamps auth
"${compose[@]}" logs --since=30m --timestamps postgres
"${compose[@]}" logs --since=30m --timestamps auth-mysql
"${compose[@]}" logs --since=30m --timestamps auth-redis

journalctl -u caddy --since "30 minutes ago" --no-pager
tail -n 200 /var/log/nginx/knowtrace.error.log
```

重启会产生新日志并改变现场，所以必须先保存时间、容器状态、健康检查和错误日志。

### 7.3 最小范围恢复

Caddy 配置故障：

```bash
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
```

Nginx 配置故障：

```bash
nginx -t
systemctl reload nginx
```

仅应用进程异常：

```bash
"${compose[@]}" restart app
```

仅认证服务异常：

```bash
"${compose[@]}" restart auth
```

数据库异常时先检查磁盘、连接和日志。不要直接删除容器、重建 volume 或全栈重启。

### 7.4 恢复后的验证

```bash
curl -fsS https://knowtrace.duckdns.org/api/health/live
curl -fsS https://knowtrace.duckdns.org/api/health/ready
curl -fsS http://127.0.0.1:8082/readyz
```

随后人工验证：

- 管理员登录。
- 打开知识库和历史记录。
- 打开一份历史附件。
- 新建并保存一条测试记录。
- 编辑并再次保存。
- 至少观察 15 分钟，确认没有复发。

## 8. 故障记录模板

```markdown
# INC-XXX-故障标题

## 基本信息
- 开始时间：
- 发现方式：
- 恢复时间：
- 影响用户：
- 影响功能：
- 严重等级：

## 用户看到的现象

## 时间线

## 收集到的证据
- 健康检查：
- 容器状态：
- 应用日志：
- 认证日志：
- 数据库日志：
- Caddy/Nginx 日志：
- 磁盘和内存：

## 根因
- 直接原因：
- 深层原因：
- 为什么监控没有提前发现：

## 处理过程

## 恢复验证
- 健康检查：
- 登录：
- 数据读取：
- 附件：
- 创建和保存：

## 改进项
- 代码改进：
- 监控告警：
- 文档：
- 自动化：
```

## 9. 实施顺序与完成标准

1. 手动完成 PostgreSQL、MySQL、Redis、附件和配置备份。
2. 将备份复制到 Windows 加密目录并重新校验。
3. 在隔离环境恢复 PostgreSQL。
4. 增加 MySQL、附件和 Redis 恢复。
5. 写成 Bash 脚本，正确处理失败退出和服务恢复。
6. 使用 systemd timer 每日执行。
7. 通过 Node Exporter textfile collector 或专用 exporter 暴露备份成功时间、大小和耗时。
8. Prometheus 设置备份过期告警，Grafana 展示恢复指标。
9. 每月完成一次恢复和一次可控故障演练。

达到第 4 步并有业务验证证据后，才可以说“具备经过演练的完整备份恢复能力”。
