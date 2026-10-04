# Caddy 配置与排障详解

## 1. Caddy 在当前架构中的职责

当前阶段一确实使用 Caddy，不是待办项：

```text
Caddy :80/:443 -> Nginx 127.0.0.1:8080 -> app 127.0.0.1:3000
```

Caddy负责：

- 公网 80/443 监听。
- 自动申请、保存和续期 TLS 证书。
- HTTP 自动跳转 HTTPS。
- 安全响应头。
- 边缘访问日志和滚动。

Nginx负责：

- 只在本机 `127.0.0.1:8080` 接收 Caddy 流量。
- 应用级反向代理超时和上传大小限制。
- 第二层 access/error 日志。

单个应用可让 Caddy 直接代理 3000；当前保留 Nginx 是为了学习两层代理。它多一个故障点，不等于更高可用。

## 2. 当前 Caddyfile

```caddyfile
knowtrace.duckdns.org {
    encode zstd gzip

    reverse_proxy 127.0.0.1:8080

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }

    log {
        output file /var/log/caddy/knowtrace-access.log {
            roll_size 10MiB
            roll_keep 5
            roll_keep_for 168h
        }
        format json
    }
}
```

## 3. 逐行解释

### `knowtrace.duckdns.org`

站点地址包含公网域名，因此 Caddy 自动启用 HTTPS。DNS A 记录必须先指向 VPS，公网 80/443 必须到达 Caddy。

### `encode zstd gzip`

客户端支持时压缩响应。压缩改善文本资源传输，不修复慢数据库或慢 AI 请求。

### `reverse_proxy 127.0.0.1:8080`

把原方法和 URI 转发给 Nginx。使用回环地址意味着该中间入口不直接暴露公网。

### `header`

- HSTS：浏览器后续强制使用 HTTPS。配置错误域名时会增加恢复难度，因此只应在 HTTPS 已稳定后启用。
- `nosniff`：禁止浏览器猜测 MIME 类型。
- Referrer Policy：控制跨站请求携带的来源信息。
- `-Server`：删除响应的 Server 头；这不是漏洞修复，只是减少版本暴露。

### `log`

访问日志写入 JSON 文件；达到 10 MiB 滚动，最多保留 5 份，最多保留 168 小时。Caddy 官方文件输出默认支持滚动。

## 4. 安全编辑流程

```bash
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
cp -a /etc/caddy/Caddyfile "/root/knowtrace-ops/backups/Caddyfile.$timestamp"
nano /etc/caddy/Caddyfile
caddy fmt --overwrite /etc/caddy/Caddyfile
sudo -u caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy
systemctl status caddy --no-pager
journalctl -u caddy -n 100 --no-pager
```

配置变更使用 reload，不要先 stop；官方 systemd 服务会把进程日志送进 journal。

## 5. 日志权限故障

已真实发生过：预创建 `/var/log/caddy/knowtrace-access.log` 时属主为 root、权限 600，导致以 `caddy` 用户运行的服务无法写入并启动失败。

检查：

```bash
systemctl status caddy --no-pager
journalctl -u caddy -n 100 --no-pager
namei -l /var/log/caddy/knowtrace-access.log
sudo -u caddy test -w /var/log/caddy && echo writable
```

恢复：

```bash
install -d -o caddy -g caddy -m 0750 /var/log/caddy
test ! -e /var/log/caddy/knowtrace-access.log \
  || chown caddy:caddy /var/log/caddy/knowtrace-access.log
sudo -u caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl restart caddy
```

这里使用 restart 是因为服务已经启动失败；正常配置变更仍使用 reload。

## 6. 证书申请失败

按顺序检查：

```bash
dig +short knowtrace.duckdns.org A
dig @1.1.1.1 +short knowtrace.duckdns.org A
ufw status numbered
ss -lntp | grep -E ':(80|443)\b'
journalctl -u caddy --since '30 minutes ago' --no-pager
```

真实历史故障是 DNS 仍指向旧 IP，Let’s Encrypt 请求旧服务器后连接失败。此时重启 Caddy没有用；先修 DNS，再等待传播并重新验证。

## 7. 502 Bad Gateway

Caddy 能返回 502 说明 DNS、TLS 和 Caddy通常已经工作，问题更靠内层：

```bash
curl -v http://127.0.0.1:8080/nginx-health
curl -v http://127.0.0.1:8080/api/health/ready
systemctl status nginx --no-pager
nginx -t
tail -n 100 /var/log/nginx/knowtrace.error.log
curl -v http://127.0.0.1:3000/api/health/ready
```

如果 Nginx health 成功但应用 ready 失败，再查 Docker app 和数据库。

## 8. Caddy正常但浏览器打不开

比较不同视角：

```bash
# VPS 本机
curl -I http://knowtrace.duckdns.org/login
curl -I https://knowtrace.duckdns.org/login

# Caddy 是否收到请求
tail -f /var/log/caddy/knowtrace-access.log
```

如果 VPS 本机、外部证书验证和其他网络均成功，而某一台 Windows 失败，应检查该电脑的代理、DNS、VPN 和路由，不要因此关闭 VPS 防火墙。

## 9. 配置回滚

先列出明确备份，再选择一个文件，不要对模糊通配符执行覆盖：

```bash
ls -lah /root/knowtrace-ops/backups/Caddyfile.*
cp -a /root/knowtrace-ops/backups/Caddyfile.<明确时间戳> /etc/caddy/Caddyfile
sudo -u caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy
curl -fsS https://knowtrace.duckdns.org/api/health/ready
```

## 10. 验收标准

- [ ] `caddy validate` 成功。
- [ ] `systemctl is-active caddy` 输出 `active`。
- [ ] `ss` 显示 Caddy 监听 80/443。
- [ ] HTTP 返回到 HTTPS 的重定向。
- [ ] HTTPS 登录页和 ready 返回 2xx。
- [ ] 证书域名、签发者、有效期正常。
- [ ] Caddy访问日志持续滚动，不包含主动开启的敏感 Cookie 日志。
- [ ] Nginx 和 app 仍只监听回环或容器网络。

## 11. 官方资料

- <https://caddyserver.com/docs/install>
- <https://caddyserver.com/docs/running>
- <https://caddyserver.com/docs/automatic-https>
- <https://caddyserver.com/docs/caddyfile/directives/reverse_proxy>
- <https://caddyserver.com/docs/caddyfile/directives/log>

