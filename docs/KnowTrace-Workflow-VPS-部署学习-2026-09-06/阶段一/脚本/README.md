# Shell 脚本说明

这些脚本用于学习和重复检查，不会替代阅读输出。

| 脚本 | 是否修改系统 | 用途 |
|---|---|---|
| `00-preflight.sh` | 否 | 部署前盘点系统、资源、DNS、端口和已有软件 |
| `01-verify-stage1.sh` | 否 | 从 Docker、app、Nginx、Caddy 到公网 HTTPS 的阶段一验收 |
| `02-collect-diagnostics.sh` | 只在 `/tmp` 写私有报告 | 收集故障证据，不读取 `.env` 和数据库内容 |

## 从 Windows 上传

```powershell
$Key = "C:\Users\Yotoha\.ssh\knowtrace_vps_ed25519"
$Target = "root@<VPS_IP>:/root/knowtrace-learning/"

ssh -p <SSH_PORT> -i $Key root@<VPS_IP> "install -d -m 0700 /root/knowtrace-learning"
scp -P <SSH_PORT> -i $Key `
  "C:\Users\Yotoha\Desktop\KnowTrace-Workflow-VPS-部署学习-2026-09-06\脚本\*.sh" `
  $Target
```

## VPS 上检查和运行

```bash
cd /root/knowtrace-learning
chmod 0700 ./*.sh

# 先做 Bash 语法检查
bash -n ./*.sh

./00-preflight.sh knowtrace.duckdns.org /opt/knowtrace
./01-verify-stage1.sh knowtrace.duckdns.org /opt/knowtrace
./02-collect-diagnostics.sh knowtrace.duckdns.org /opt/knowtrace
```

脚本默认域名是 `knowtrace.duckdns.org`，默认项目目录是 `/opt/knowtrace`；传入参数可覆盖。

## 证据边界

- 脚本不读取或打印 `.env`。
- 诊断报告权限为 `600`，仍可能含主机名、端口、容器名和错误上下文；分享前必须人工脱敏。
- 脚本不执行 restart、down、删除卷、Git 更新或数据库写入。
- 本次只完成 Windows 本地 `bash -n` 静态语法验证；还没有在一台新 VPS 上重新完整运行。

