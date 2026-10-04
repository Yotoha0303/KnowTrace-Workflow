# INC-S2-001：SSH 管理入口拒绝连接

- 首次发现：2026-09-07，阶段二远端清点开始时。
- 恢复时间：2026-09-08（用户补充真实端口 22345 后立即恢复连接）。
- 状态：已关闭。
- 影响等级：中等；公网应用始终可用，但客户端使用错误端口期间无法开展服务器管理、备份部署和恢复演练。
- 关联证据：[2026-09-07 SSH 与 HTTPS 复测](../证据/2026-09-07-SSH与HTTPS复测.md)。

## 现象

- `knowtrace.duckdns.org` 正确解析到 `45.64.74.99`。
- 通过代理和绕过代理访问 HTTPS ready 均返回 200。
- SSH 使用现有私钥连接时，在认证前返回 `banner exchange ... Connection refused`，退出码 255。
- 2026-09-07 23:06 端口复测：22/TCP 被主动拒绝，80/TCP 与 443/TCP 可建立连接；HTTPS ready 返回 200。
- 云厂商管理页已在 Chrome 中打开，但自动化读取连续两次超时；为避免误操作已停止控制页面，未点击重启、重装、重置或防火墙操作。系统 Console/VNC 状态仍待人工确认。

## 初期已确认事实

1. VPS 并非整机完全离线，因为同一公网 IP 的 443 端口仍能提供正确的 TLS 和 ready 响应。
2. SSH 失败发生在用户名/私钥认证之前，当前没有证据说明私钥损坏。
3. 本次阶段二尚未对 VPS 执行重启、重装、UFW、SSH 或应用配置变更。
4. 初期没有服务器端日志，因此当时没有提前断言根因。
5. 22/TCP 与 443/TCP 的结果不同，说明故障不在整机或域名；后续服务器证据确认 SSH 根本不使用 22。

## 初期假设及排除结果

- `ssh.service` 未运行、崩溃或正在反复启动。
- sshd 仍运行，但监听地址/端口发生变化。
- systemd socket、连接速率限制、主机防火墙或云厂商网络策略拒绝新连接。
- 资源耗尽导致 sshd 无法完成握手。

恢复管理通道后检查发现 ssh 服务自 2026-09-06 起持续 active、重启次数为 0，`sshd -t` 通过；这些初期假设均被排除。

## 根因证据

- `/etc/ssh/sshd_config` 第 23 行配置 `Port 22345`。
- `ss` 显示 sshd 同时监听 `0.0.0.0:22345` 和 `[::]:22345`。
- UFW 允许 22345/TCP。
- `ssh -p 22345 root@45.64.74.99` 使用已有私钥成功，服务器只接受公钥认证。
- 因此，22/TCP 拒绝是预期行为；根因是客户端连接信息仍沿用了默认端口 22，而不是 VPS 或 sshd 故障。

## 安全处置

- 已降低 SSH 重试频率，避免在原因未知时放大连接限制。
- 已确认 HTTPS 服务继续可用，暂不重启整机、不关闭 UFW、不重装系统。
- 用户补充真实端口后，先以批处理公钥模式验证新会话，再继续远端工作；没有重启或重装 sshd。

## 控制台取证顺序

```bash
date -u
uptime
free -h
df -hT /
systemctl status ssh --no-pager -l
systemctl status ssh.socket --no-pager -l
ss -ltnp | grep -E '(:22[[:space:]]|sshd)'
journalctl -u ssh --since '2026-09-07 00:00:00' --no-pager -n 200
journalctl -k --since '2026-09-07 00:00:00' --no-pager -n 200
ufw status verbose
nft list ruleset
```

日志中可能包含来源 IP、用户名等信息；公开分享前脱敏。若磁盘满、OOM、配置语法错误或服务失败，应先保存证据，再做对应的单一最小修复。

## 恢复验收

- [x] `sshd -t` 配置检查通过。
- [x] ssh 服务 active，预期地址/22345 端口监听。
- [x] UFW 允许 22345/TCP。
- [x] Windows 使用 `C:\Users\Yotoha\.ssh\knowtrace_vps_ed25519` 独立登录成功。
- [x] HTTPS、Compose healthy 和日志再次验证。
- [x] 写明根因、恢复方式和预防项。

## 预防与回滚

- Windows `C:\Users\Yotoha\.ssh\config` 已新增别名 `knowtrace-vps`，固定主机、用户、22345、身份文件、`IdentitiesOnly yes`、`PasswordAuthentication no` 和严格主机密钥检查。
- 修改前备份：`C:\Users\Yotoha\.ssh\config.pre-knowtrace-20260908`；写入前后已核对备份哈希。
- 回滚时先保持当前可用 SSH 会话，再恢复该备份文件并执行 `ssh -G knowtrace-vps` 检查；不要同时关闭救援控制台。

## 当前结论

这不是服务器停机，而是客户端连接到错误端口造成的管理通道假故障。修正为 22345 后连接恢复，随后已完成 VPS 备份、隔离恢复、压测、发布和受控重启验证。
