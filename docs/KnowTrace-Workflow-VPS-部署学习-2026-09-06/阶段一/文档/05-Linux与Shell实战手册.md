# Linux 与 Shell 实战手册

## 1. 学习方式

不要背完整命令表。每次练习都走一遍：

```text
查看现状 -> 预测命令影响 -> 执行 -> 检查退出码 -> 验证业务 -> 记录证据
```

先掌握只读命令，再学习创建文件和修改服务；删除、覆盖、数据库恢复最后学。

## 2. 先判断自己在哪里

```bash
whoami                 # 当前用户
hostname               # 当前主机
pwd                    # 当前目录
echo "$SHELL"          # 当前 Shell
ps -p $$ -o pid,comm=  # 当前 Shell 进程
```

看到 `/app` 且主机名像容器 ID，通常表示你通过 `docker compose exec app sh` 进入了容器。输入 `exit` 返回 VPS；VPS 源码在 `/opt/knowtrace`。

## 3. 文件与目录

```bash
ls -lah /opt/knowtrace
find /opt/knowtrace -maxdepth 2 -type f | sort | less
stat /opt/knowtrace/compose.yaml
du -sh /opt/knowtrace/data/uploads
df -hT /
```

常用写操作：

```bash
mkdir -p /tmp/knowtrace-lab
cp -a source.conf /tmp/knowtrace-lab/source.conf.backup
install -m 0644 source.conf /tmp/knowtrace-lab/source.conf
mv /tmp/knowtrace-lab/source.conf /tmp/knowtrace-lab/renamed.conf
```

`install` 可以同时复制并设置权限，配置部署时比 `cp` 后再 `chmod` 更清晰。

## 4. 阅读和搜索

```bash
less /etc/caddy/Caddyfile
sed -n '1,160p' /etc/caddy/Caddyfile
grep -n 'reverse_proxy' /etc/caddy/Caddyfile
grep -RIn --exclude-dir=.git '127.0.0.1:3000' /opt/knowtrace
```

在 `less` 中：`/词语` 搜索，`n` 下一个，`q` 退出。

## 5. 权限

```bash
ls -ld /opt/knowtrace /var/log/caddy
stat -c '%A %a %U:%G %n' /opt/knowtrace/.env
id caddy
namei -l /var/log/caddy/knowtrace-access.log
```

数字权限：

- `600`：只有所有者可读写，适合 `.env`。
- `640`：所有者读写、组只读，适合 root 管理且 Caddy 组可读的配置。
- `750`：所有者全部权限、组读取和进入，适合日志目录。
- `644`：所有人可读，不能用于秘密。

## 6. 进程、端口和 systemd

```bash
ps aux --sort=-%mem | head
ss -lntup
systemctl status caddy nginx docker --no-pager
systemctl is-active caddy nginx docker
systemctl list-units --failed
journalctl -u caddy --since '30 minutes ago' --no-pager
```

`start` 是从停止状态启动；`reload` 是平滑加载配置；`restart` 会停止再启动。修改 Caddy/Nginx 配置后优先 validate/test 再 reload。

## 7. 网络分层检查

```bash
ip -brief address
ip route
getent ahostsv4 knowtrace.duckdns.org
dig +short knowtrace.duckdns.org A
curl -v http://127.0.0.1:3000/api/health/ready
curl -v http://127.0.0.1:8080/api/health/ready
curl -vkI https://knowtrace.duckdns.org/login
```

不要一上来只测域名。先测 app，再测 Nginx，再测 Caddy，能快速定位是哪一层断开。

## 8. Docker 和 Compose

```bash
docker version
docker info
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker volume ls

cd /opt/knowtrace
docker compose -f compose.yaml -f compose.production.yaml config --quiet
docker compose -f compose.yaml -f compose.production.yaml ps -a
docker compose -f compose.yaml -f compose.production.yaml logs --tail=100 app
docker compose -f compose.yaml -f compose.production.yaml exec app sh
```

容器不是虚拟机：镜像是模板，容器是运行实例，卷保存状态。删除容器通常可以重建；删除数据库卷可能永久丢失数据。

## 9. Git 部署阅读命令

```bash
cd /opt/knowtrace
git status --short --branch
git rev-parse HEAD
git remote -v
git fetch --prune origin
git log --oneline --decorate --max-count=10
git diff --stat HEAD..origin/main
```

这些是只读检查。`git pull`、`merge`、`switch` 会改变工作树；运行前必须知道目标提交和回滚依据。

## 10. Bash 严格模式

脚本开头：

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
```

- `-E`：函数中的错误也能触发 ERR trap。
- `-e`：未处理的失败使脚本退出。
- `-u`：使用未定义变量时报错。
- `pipefail`：管道中任一命令失败，整个管道失败。

配合错误提示：

```bash
trap 'printf "ERROR line=%s status=%s\n" "$LINENO" "$?" >&2' ERR
```

## 11. 变量和引号

```bash
project_dir='/opt/knowtrace'
domain='knowtrace.duckdns.org'
printf 'project=%s domain=%s\n' "$project_dir" "$domain"
cd "$project_dir"
```

变量展开几乎都应写成 `"$variable"`。不加引号会被空格和通配符重新拆分。

不要复用 `HOME`、`PATH` 等系统变量名。使用 `project_dir`、`report_dir` 这类任务专用名称。

## 12. 参数和默认值

```bash
domain="${1:-knowtrace.duckdns.org}"
project_dir="${PROJECT_DIR:-/opt/knowtrace}"
```

- `${1:-值}`：没有第一个参数时使用默认值。
- `${VAR:?说明}`：变量缺失时立即退出并显示说明。

## 13. 条件和函数

```bash
require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing command: %s\n' "$1" >&2
    return 1
  }
}

if systemctl is-active --quiet caddy; then
  printf 'caddy active\n'
else
  printf 'caddy inactive\n' >&2
fi
```

函数应完成一个小任务并通过退出码表达成功/失败。

## 14. 循环

```bash
for url in \
  'http://127.0.0.1:3000/api/health/live' \
  'http://127.0.0.1:3000/api/health/ready'; do
  curl -fsS "$url" >/dev/null
  printf 'PASS %s\n' "$url"
done
```

这比复制多条相似命令更容易维护，也是部署脚本的基础。

## 15. 输入、输出和管道

```bash
command >file.log       # 覆盖标准输出
command >>file.log      # 追加标准输出
command 2>error.log     # 保存标准错误
command >all.log 2>&1   # 合并输出
command | less          # 前一条输出交给后一条
```

不要把 `set -x` 用在包含密码、Token 或 `.env` 的生产脚本中，它会把展开后的命令写进终端和日志。

## 16. 退出码

```bash
curl -fsS http://127.0.0.1:3000/api/health/ready >/dev/null
printf 'status=%s\n' "$?"
```

`0` 表示成功，非 `0` 表示失败。自动化脚本应返回非零，让 CI 或监控知道验收失败。

## 17. 四个渐进练习

### 练习 A：只读盘点

运行 `脚本/00-preflight.sh`，解释每个输出来源。完成标准：能指出系统、资源、端口、DNS和项目目录状态。

### 练习 B：从内到外健康检查

运行 `脚本/01-verify-stage1.sh`。完成标准：能区分 app、Nginx、Caddy 哪一层失败，而不是只说“网站挂了”。

### 练习 C：制造并恢复 Nginx 配置错误

只在实验机进行：先备份配置，故意写一个无效指令，运行 `nginx -t` 看到失败；不 reload；恢复备份，再次 `nginx -t` 成功。完成标准：线上服务在整个练习中未中断。

### 练习 D：收集故障证据

运行 `脚本/02-collect-diagnostics.sh`。完成标准：报告包含主机资源、端口、服务、容器、三层日志和健康检查，但不包含 `.env`、Cookie、Token 或数据库内容。

## 18. 必须掌握、需要理解、可以后置

### 现在必须掌握

- `pwd`、`ls`、`cd`、`cp`、`install`、`less`、`grep`。
- `systemctl`、`journalctl`、`ss`、`curl`、`df`、`free`。
- `docker compose ps/logs/up/down` 的影响。
- 退出码、引号、变量、`set -Eeuo pipefail`。

### 需要理解

- Caddy、Nginx、app、数据库的请求路径。
- 源码、镜像、容器、卷的边界。
- live 与 ready 的区别。
- 备份必须通过恢复验证才成立。

### 可以后置

- `awk`/`sed` 高级文本处理。
- systemd 自定义 unit。
- nftables/iptables 深度规则。
- Kubernetes、ELK、GitOps。

