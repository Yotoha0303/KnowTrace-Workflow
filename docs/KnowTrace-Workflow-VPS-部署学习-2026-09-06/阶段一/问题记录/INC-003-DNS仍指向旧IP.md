# INC-003：DuckDNS 仍指向旧 VPS 地址

- 时间：2026-09-06
- 影响：新 VPS 无法通过目标域名完成 HTTPS 签发；访问域名会到旧主机。
- 现象：`knowtrace.duckdns.org` 的 A 记录为 `172.96.141.83`，目标 VPS 为 `45.64.74.99`。
- 原因：DuckDNS 记录尚未更新。
- 处理：在 DuckDNS 将 A 记录更新为新 VPS IP，等待权威 DNS 与公共解析器一致。
- 验证标准：至少两个独立解析视角返回 `45.64.74.99`，再启动 Caddy 自动签发。
- 证据：Caddy 的 HTTP-01 与 TLS-ALPN-01 验证均访问了旧 IP 并收到连接拒绝；Caddy 会按退避策略自动重试。
- 处理结果：DuckDNS 已更新为 `45.64.74.99`；VPS 与 Cloudflare DNS 视角均解析到新地址。重启 Caddy 后 Let’s Encrypt HTTP-01 验证成功并签发证书。
- 状态：已解决。
