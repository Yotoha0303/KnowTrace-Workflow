# ISSUE-S3-008：Windows 代理链导致 TLS 握手误判

- 范围：最终公网复测。
- 状态：已关闭，无服务器变更。
- 影响：Windows curl 首次报告 Schannel handshake failure，容易误判网站 HTTPS 故障。

## 交叉证据

- DNS：`knowtrace.duckdns.org -> 45.64.74.99`。
- Windows 443 TCP：成功。
- VPS 自身公网 HTTPS：ready=200，TLS verify=0。
- Prometheus Blackbox：`probe_success=1`。
- Windows `curl --noproxy '*'`：ready=200，首页 307，TLS verify=0。

## 根因

首次 curl 使用了本机代理环境，TLS 在客户端代理链路中失败；请求未证明到达 VPS。绕过代理后同一证书与域名成功。

## 处理

没有重签证书、关闭 TLS 校验、修改 Caddy/Nginx 或开放端口。公网基线命令明确使用 `--noproxy '*' -4` 并保留证书校验。

## 经验

公网故障必须从 DNS、TCP、TLS、HTTP 和服务器日志分层判断，并至少使用两个网络视角。客户端报错不自动等于服务端故障。
