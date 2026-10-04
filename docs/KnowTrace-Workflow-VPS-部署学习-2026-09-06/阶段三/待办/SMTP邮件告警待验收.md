# SMTP 邮件告警待验收

> **2026-10-03 重开 + 重新接通**。这份待办不是过期文档 —— 它一度**被系统重装打回原形**：
> 2026-09-28 曾接好 163 并实测收到邮件，但 **2026-10-02 的系统重装**
> 把 `/opt/knowtrace/.env.observability` 一起抹掉，配置退回到占位值
> （`ALERT_EMAIL_ENABLED=false`、`ALERT_SMTP_SMARTHOST=smtp.example.com:587`）。
> **运行时配置不在 Git 里，重装即丢失** —— 这是 `deploy/ansible/` 要解决的根问题。

## 当前状态（2026-10-03 实测）

| 项 | 值 |
| --- | --- |
| `ALERT_EMAIL_ENABLED` | `true`（2026-10-03 重新写入） |
| `ALERT_SMTP_SMARTHOST` | `smtp.163.com:465` |
| 发件 / 收件 | `min2686396546@163.com`（同一地址） |
| 授权码 | 已通过 `configure-163-alert-email.sh` 隐藏输入写入（16 位，未出现在命令参数/聊天/日志） |
| `runtime/alertmanager/alertmanager.json` | 已渲染，`receivers: [local-only, email]`，根 route → `email` |
| Alertmanager | 重启后 healthy，`amtool check-config` 通过（2 receivers） |
| 配置变更备份 | `/root/knowtrace-ops/backups/20261003T100930Z-pre-smtp-email/.env.observability`（0600） |

**已实测通过的环节**：

- 服务器 → `smtp.163.com:465` TLS 1.3 握手成功（证书 `*.163.com` 校验 OK）。
- 用配置里的凭据**直接登录** 163 SMTP 成功（`SMTP 登录 OK`）→ 授权码有效。
- 从服务器直接发信成功（`直接发信成功 -> 已投递到 smtp.163.com 接受`）。
- Alertmanager 已接受测试告警（`TEST_ALERT_ACCEPTED=email-test-20261003T101022Z`）。

**尚未验证的环节**（所以本待办仍然开着）：

- ⚠️ **收件箱是否真的收到**。邮件投递是"已交给 163 服务端"，不等于"已进收件箱" ——
  可能在垃圾邮件目录，也可能被 163 拦截。
- ⚠️ **Alertmanager 自身那条链路是否也发出去**了。注意：Alertmanager 的
  `Notify success` 是 **DEBUG** 级日志，默认 INFO 下**发送成功不会打日志** ——
  所以"`docker logs` 里没有 notify 记录"**不能**作为"没发出去"的证据。

## 完成门禁

- [x] 服务器到 `smtp.163.com:465` 的 TLS 握手成功且证书验证 `OK`。
- [x] 授权码通过隐藏提示写入（未经命令参数 / 管道 / 聊天）。
- [x] `amtool check-config` 成功。
- [x] Alertmanager 健康。
- [x] 测试告警出现在 Alertmanager（`KnowTraceEmailDeliveryTest`，active）。
- [x] 用配置凭据直接 SMTP 登录成功（授权码有效性独立验证）。
- [ ] **收件箱（含垃圾邮件目录）实际收到测试邮件** ← **卡在这一条**
- [ ] 测试告警恢复并清除。
- [ ] 文档只记录提供商、时间和结果，不记录密码、完整邮件头或 token。

**只有第 7 条勾上，才能把外面任何地方写成「外部告警已验证」。**

## 如果收件箱没收到

按可能性从高到低排查：

1. **垃圾邮件目录 / 163 的「广告邮件」分类** —— 先看这两处。
2. **163 的 SMTP 发信限制**：新授权码有时需要先在网页端登录一次才能启用发信。
3. **DNS**：2026-10-01 出过一次 `smtp.163.com` 解析整段失败（systemd-resolved stub 问题），
   见 `docs/2026-10-01-公网探针告警-DNS中断复盘.md`。现在 `getent hosts smtp.163.com` 正常。
4. 服务器上直接发一封已验证可用的自检邮件对比（不经 Alertmanager）：

   ```bash
   cd /opt/knowtrace
   python3 - <<'PY'
   import ssl, smtplib, re, pathlib
   from email.message import EmailMessage
   env = pathlib.Path('.env.observability').read_text(encoding='utf-8')
   g = lambda k: re.search(rf'^{k}=(.*)$', env, re.M).group(1).strip()
   host, port = g('ALERT_SMTP_SMARTHOST').split(':')
   user, code, to = g('ALERT_SMTP_AUTH_USERNAME'), g('ALERT_SMTP_AUTH_PASSWORD'), g('ALERT_EMAIL_TO')
   m = EmailMessage(); m['Subject']='KnowTrace-Workflow SMTP 自检'; m['From']=user; m['To']=to
   m.set_content('自检邮件')
   with smtplib.SMTP_SSL(host, int(port), timeout=25, context=ssl.create_default_context()) as s:
       s.login(user, code); s.send_message(m)
   print('已投递')
   PY
   ```

## 授权码卫生

授权码已在本会话之外的地方出现过（用户的本地文件）。**不要**把授权码写进
命令参数、Shell 历史、聊天、Git 或本地 Markdown。若曾出现在聊天/截图/工单中，
先到 163 后台作废并生成新值，再跑 `scripts/linux/configure-163-alert-email.sh`。

## 应用配置（改完 SMTP 后）

```bash
cd /opt/knowtrace
scripts/linux/init-observability-env.sh          # 渲染 alertmanager.json
docker compose \
  --env-file .env \
  --env-file .env.observability \
  -f compose.yaml -f compose.production.yaml -f compose.observability.yaml \
  up -d --no-deps --force-recreate alertmanager
scripts/linux/test-email-alert.sh
```

`ALERT_SMTP_REQUIRE_TLS=false` 是刻意的：Alertmanager 0.28.1 会先对 465 建立隐式 TLS，
这个 `false` 只跳过随后重复的 STARTTLS 检查，**不会**关闭证书校验或改成明文。
见 [ISSUE-S3-010](../问题记录/ISSUE-S3-010-163端口465与Alertmanager-TLS语义冲突.md)。