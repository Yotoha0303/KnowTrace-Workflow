# INC-S2-001：SSH 管理入口拒绝连接

- 首次发现：2026-09-07，阶段二远端清点开始时。
- 最近复测：2026-09-07T23:06:07+08:00，第四次低频复测仍未恢复。
- 状态：处理中。
- 影响：公网应用仍可用，但服务器管理、备份部署、恢复演练和服务器侧压测被阻断。

## 事实

- 域名 A 记录为 `45.64.74.99`。
- 绕过 Windows 代理直连 HTTPS ready 返回 200，TLS 校验成功。
- ready 响应为 `{"status":"ok","database":"connected"}`。
- SSH 使用现有私钥时，在认证前返回 `banner exchange: Connection to UNKNOWN port -1: Connection refused`，退出码 255。
- 本阶段没有重启 VPS、关闭 UFW、修改 SSH 或部署本地脚本。
- 无服务器端日志，根因未知。
- 23:06 端口复测显示 22/TCP 被主动拒绝，80/TCP 和 443/TCP 可建立连接；HTTPS ready 仍为 200。
- 云厂商管理页自动化读取连续两次超时后已停止；没有执行重启、重装、重置或防火墙面板操作。

## 未证实假设

- ssh 服务异常或监听配置变化。
- systemd socket、主机/云防火墙或连接限制拒绝新连接。
- 资源耗尽使 sshd 无法完成握手。

## 下一步

通过厂商 Console/VNC 读取 `systemctl status ssh`、`ss -ltnp`、`journalctl -u ssh`、UFW、nftables、磁盘和内存。保存证据后再选择最小修复，并从 Windows 重新验证密钥登录。
