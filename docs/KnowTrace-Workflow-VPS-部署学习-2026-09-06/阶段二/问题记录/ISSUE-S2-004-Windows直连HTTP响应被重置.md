# ISSUE-S2-004：Windows 直连 HTTP 响应被重置

- 发现时间：2026-09-08 09:49～09:52（Asia/Shanghai）。
- 状态：已定位到客户端/网络路径，服务器端无需变更；保留观察。
- 影响：仅本机绕过代理访问 `http://knowtrace.duckdns.org` 时看不到 308；HTTPS 直连正常。

## 现象与对照

同一路径探针 `__stage2_http_probe_20260908_0952`：

- Windows `curl --noproxy '*'`：连到 `45.64.74.99` 后报 `Recv failure: Connection was reset`，HTTP 状态 000。
- Windows 当前代理路径：收到 308，Location 指向同域名 HTTPS。
- Caddy 访问日志：上述两个来源请求都已到达 VPS，两个请求的服务器状态均为 308。
- VPS 本机使用相同 Host 头访问 `127.0.0.1:80`：收到 308。
- Caddy 正在 `*:80` 和 `*:443` 监听，UFW 的 Nginx Full 规则允许 80/443。

## 结论

服务器确实处理并记录了 308；直接客户端没有收到响应，故障位于响应返回的客户端/运营商/中间网络路径，不能归因为 Caddy 配置失败。域名 HTTPS 主链路在同一时刻直连返回 200，TLS 校验结果为 0。

## 后续验证

- 换一条网络（例如手机热点）执行同一条 `curl --noproxy '*'` 命令。
- 若多条网络都复现，再在维护窗口短时抓取 80/TCP 的 FIN/RST 包并对时。
- 不为规避该现象关闭 HTTPS、TLS、UFW 或 Caddy 自动重定向。
