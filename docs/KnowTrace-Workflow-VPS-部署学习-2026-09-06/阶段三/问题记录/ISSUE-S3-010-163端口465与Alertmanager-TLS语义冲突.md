# ISSUE-S3-010：163 端口 465 与 Alertmanager TLS 语义冲突

- 范围：第三阶段邮件告警。
- 状态：处理中；尚未配置邮箱账户，尚未发送测试邮件。
- 发现时间：2026-09-08（Asia/Shanghai）。

## 现象与证据

- VPS 到 `smtp.163.com:465` 的 TLS 1.3 握手成功，服务端证书为
  `*.163.com`，OpenSSL 验证结果为 `OK`。
- 465、587 的 TCP 连接都可建立；TCP 可达不能证明 SMTP 鉴权或邮件送达。
- 当前镜像为 Alertmanager 0.28.1。该版本对 465 先执行隐式 TLS；若
  `require_tls=true`，随后还会要求服务端声明 STARTTLS，存在重复升级并失败的风险。
- 当前外部邮件仍为 `ALERT_EMAIL_ENABLED=false`，所以没有把配置准备完成误写为送达成功。

## 根因

`require_tls` 在 Alertmanager 0.28.1 的 465 路径中控制的是后续 STARTTLS
检查，不是最初的隐式 TLS 握手。直接套用 587 的配置会把已经加密的连接
再次当作需要升级的明文 SMTP 连接。

## 处理方案

1. 固定 `smtp.163.com:465`。
2. 设置 `ALERT_SMTP_REQUIRE_TLS=false`，仅跳过重复 STARTTLS；465 仍由
   Alertmanager 在建立 SMTP 会话前完成 TLS 和证书校验。
3. 配置脚本对“465 + true”直接报错，避免带病重启。
4. 使用交互式隐藏输入写入新的 163 SMTP 授权码；授权码不进入参数、历史、
   Git、聊天或本文。
5. 配置校验通过后只重建 Alertmanager，不重启应用、数据库或 Prometheus。

## 安全事件边界

已有授权码曾出现在聊天内容中，应先在 163 邮箱后台作废并重新生成。本文不
保存该值，也不使用该值进行部署。新授权码只应直接输入 VPS 的隐藏交互提示。

## 待验收

- [ ] 确认完整发件邮箱和收件邮箱。
- [ ] 作废聊天中出现过的授权码，并通过隐藏提示写入新授权码。
- [ ] `amtool check-config` 通过。
- [ ] 仅重建 Alertmanager 后 health 为 healthy。
- [ ] 测试告警被 Alertmanager 接收，日志无发送错误。
- [ ] 用户确认收件箱或垃圾邮件目录实际收到 firing 与 resolved 邮件。

只有最后两项真实送达证据成立，才能关闭问题并写“外部邮件告警已验证”。
