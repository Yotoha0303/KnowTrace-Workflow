# ISSUE-S3-009：UFW 保留未监听的 22/OpenSSH 放行

> ⚠️ **2026-10-03 复现：这条"已关闭"的问题又回来了。**
> 2026-10-03 实测 `ufw status` 里 **`22/tcp ALLOW` 再次存在**，而 sshd 仍只监听 22345。
> 原因：**2026-10-02 的系统重装把 UFW 规则一并重置**，这条放行随之回归。
> 已由 `deploy/ansible/roles/firewall` 重新清除，并加了断言防止复发
> （`ufw_stale_tcp` 里的端口不得再出现在行首）。
>
> **可迁移的教训**：这条问题**不是一次性修复**，而是"只要机器重装就会回来"的状态类问题。
> 手工修一次不够 —— 得有**声明式、幂等**的载体（这正是引入 Ansible 的直接动因之一）。


- 范围：服务器安全硬化。
- 状态：已关闭。
- 处理时间：2026-09-08 13:49（Asia/Shanghai）。
- 处理前影响：低；sshd 只监听 22345，22 端口没有进程监听。

## 证据

UFW 当前包含：

```text
22/tcp    ALLOW
OpenSSH   ALLOW
22345/tcp ALLOW
```

IPv6 也有对应 22/OpenSSH allow。`ss -ltn` 只看到 sshd 监听 `0.0.0.0:22345` 和 `[::]:22345`。

## 风险判断

当前没有 22 listener，所以放行规则本身没有提供可连接的 SSH 服务；但若以后 sshd 配置意外恢复默认端口，22 会重新暴露。反过来，未确认云厂商控制台/救援模式就删除旧规则，会减少误配置时的恢复余地。

## 安全处理流程

1. 先从 Windows 建立一条全新的 22345 密钥会话，确认 `PasswordAuthentication no`。
2. 保持当前 22345 会话，保存 UFW 清单和 `/etc/ufw` 备份。
3. 精确删除 22/tcp 和 OpenSSH 的 IPv4/IPv6 allow 规则，不改变 80/443/22345。
4. 从 Windows 再建立一条全新的 22345 密钥会话。
5. 验证外部 22345 可连接、22 不可连接、HTTPS ready=200。

## 备份与执行证据

```text
backup=/root/knowtrace-ops/backups/20260908T054929Z-pre-remove-ufw-22
etc-ufw.tar.gz SHA-256=ed011006ec1685f6cafe5c25184c94dc3c6fabb53060b631ea4081853f32508e
22/tcp IPv4/IPv6 deleted
OpenSSH IPv4/IPv6 deleted
22345/tcp IPv4/IPv6 ALLOW retained
```

## 回归结果

```text
POST_UFW_FRESH_SSH=PASS
ufw_22345=2
ufw_22_allow=0
tcp_22345=true
tcp_22=false
https_ready=200 ssl_verify=0
sshd -t=PASS
```

## 回滚

若确认必须临时恢复 22，先通过当前 22345 会话执行 `ufw allow 22/tcp`，验证后再按变更流程处理 sshd。完整 UFW 配置可从上述受限备份恢复；不要在没有 22345 会话或带外控制台时批量重置 UFW。
