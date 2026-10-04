# INC-001：UFW 规则存在但防火墙未启用

- 时间：2026-09-06
- 影响：服务器入站流量不受 UFW 规则保护，服务一旦监听公网就可能直接暴露。
- 现象：`ufw status verbose` 返回 `Status: inactive`。
- 原因：执行“允许 22”只创建规则，不等于启用 UFW。
- 处理：先允许 OpenSSH 和 Nginx Full，再执行 `ufw --force enable`。
- 验证：UFW 为 active，默认 deny incoming；现有 SSH 会话保持，22/80/443 放行规则存在。
- 后续：检查到两条功能重复的 22/tcp 规则；不影响安全，后续维护窗口再清理。
