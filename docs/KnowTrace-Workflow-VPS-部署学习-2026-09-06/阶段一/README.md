# 阶段一：上云、域名 HTTPS 与 Docker 部署

## 阶段结果

KnowTrace-Workflow 已部署在 Ubuntu VPS，通过 `https://knowtrace.duckdns.org` 提供服务。公网只承担 80/443 和 SSH 22345；数据库及管理界面没有直接暴露。

## 1. 已有安装证据

VPS 的 APT history 记录了以下实际安装命令：

```bash
apt install curl git nginx
apt-get install -y docker.io docker-compose-v2
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
apt install caddy
```

当前核验版本：Docker 29.1.3、Compose 2.40.3、Nginx 1.24.0、Caddy 2.11.4。

Caddy 仓库的 source list 和 keyring 已保存在：

- `服务器文件快照/系统/etc/apt/sources.list.d/caddy-stable.list`
- `服务器文件快照/系统/usr/share/keyrings/caddy-stable-archive-keyring.gpg`

APT history 只保存了安装命令，没有保存当时添加 Caddy 仓库的完整 shell 命令；不能将后续重建步骤冒充为原始命令历史。

## 2. 新服务器可重复基线流程

以下是根据当前配置整理的复现 SOP，不包含真实密码：

```bash
apt update
apt upgrade -y
apt install -y git curl nginx ufw ca-certificates gnupg
apt-get install -y docker.io docker-compose-v2
systemctl enable --now docker nginx
docker --version
docker compose version
docker run --rm hello-world
```

若在新主机复现 Caddy，可使用本目录保留的 source list/keyring 或重新按 Caddy 官方仓库说明获取当前 key；随后执行：

```bash
apt update
apt install -y caddy
caddy version
systemctl enable --now caddy
```

## 3. SSH 与防火墙安全迁移

正确顺序是先增加新入口，再验证第二个连接，最后移除旧入口：

```bash
ufw allow 22345/tcp
sshd -t
systemctl reload ssh
ss -lntp | grep 22345
```

从 Windows 新开终端验证密钥登录：

```powershell
ssh -p 22345 -i "$env:USERPROFILE\.ssh\knowtrace_vps_ed25519" root@45.64.74.99
```

验证成功后才关闭密码认证并删除 22 端口放行。当前本机已经配置别名：

```powershell
ssh knowtrace-vps
```

当前 SSH 配置快照位于 `服务器文件快照/系统/etc/ssh/sshd_config.d/00-knowtrace-hardening.conf`。本目录没有复制私钥。

## 4. 应用与 Compose

核心文件：

- `服务器文件快照/项目/opt/knowtrace/compose.yaml`
- `服务器文件快照/项目/opt/knowtrace/compose.production.yaml`
- `服务器文件快照/项目/opt/knowtrace/.env.example`

部署流程：

```bash
install -d -m 755 /opt/knowtrace
cd /opt/knowtrace
git status --short --branch
install -m 600 /dev/null .env
```

使用 `.env.example` 了解字段，再通过密码生成器写入真实 `.env`。示例文件中的 `KnowTrace-Workflow@123` 和 `knowtrace` 是开发示例，不是生产安全值。

```bash
docker compose \
  --env-file .env \
  -f compose.yaml \
  -f compose.production.yaml \
  config --quiet

docker compose \
  --env-file .env \
  -f compose.yaml \
  -f compose.production.yaml \
  up -d --build --wait

docker compose \
  --env-file .env \
  -f compose.yaml \
  -f compose.production.yaml \
  ps
```

## 5. Nginx、Caddy 与 HTTPS

当前最终配置快照：

- `服务器文件快照/系统/etc/nginx/sites-available/knowtrace.conf`
- `服务器文件快照/系统/etc/caddy/Caddyfile`

Nginx 安装配置流程：

```bash
install -m 644 /opt/knowtrace/deploy/nginx/knowtrace-vps.conf \
  /etc/nginx/sites-available/knowtrace.conf
ln -sfn /etc/nginx/sites-available/knowtrace.conf \
  /etc/nginx/sites-enabled/knowtrace.conf
nginx -t
systemctl reload nginx
```

Caddy 配置验证与加载：

```bash
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
systemctl status caddy --no-pager
```

流量链路：公网 443 → Caddy → `127.0.0.1:8080` Nginx → `127.0.0.1:3000` app。

## 6. 验收

```bash
curl -fsS http://127.0.0.1:3000/api/health/live
curl -fsS http://127.0.0.1:3000/api/health/ready
curl -fsS http://127.0.0.1:8082/livez
curl -fsS http://127.0.0.1:8082/readyz
curl -I https://knowtrace.duckdns.org/login
```

日志：

```bash
journalctl -u caddy --since today --no-pager
journalctl -u nginx --since today --no-pager
tail -n 100 /var/log/caddy/knowtrace-access.log
tail -n 100 /var/log/nginx/knowtrace.access.log
docker compose -f compose.yaml -f compose.production.yaml logs --tail 100
```

## 7. 本阶段材料

- `文档/`：原始阶段一过程、服务器基线、常用命令与回滚；
- `文档/04-从零部署到当前线上状态-完整实操教程.md`：从D盘旧包吸收的完整操作教程；
- `文档/05-Linux与Shell实战手册.md`：Linux/Shell学习说明；
- `文档/06-Caddy配置与排障详解.md`：Caddy配置、日志和故障处理；
- `脚本/`：阶段一预检、验收和诊断采集脚本；
- `配置样例/`：当时制作的脱敏配置样例；
- `服务器文件快照/`：2026-09-09 从 VPS 复制的最终非敏感配置；
- `证据/`：阶段一验证摘要；
- `问题记录/`：UFW、SSH 密钥、DNS、Caddy 权限和本机网络等问题。

注意：阶段一配置样例反映当时状态，服务器文件快照反映阶段三完成后的当前最终状态；二者不能混称为同一时间点。
