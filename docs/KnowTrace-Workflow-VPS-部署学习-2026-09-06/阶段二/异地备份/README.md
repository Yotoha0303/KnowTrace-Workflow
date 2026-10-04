# 加密异地备份说明

## 当前文件

- `knowtrace-20260907T151359Z-74b93d1a.tar.gz.age`：age 加密的完整归档，Windows 上只有密文。
- `.age.sha256`：密文 SHA-256。
- `.tar.gz.sha256`：解密后明文归档应匹配的 SHA-256；本目录没有明文 tar.gz。

已验证：

```text
密文 SHA-256 = 23d203eaa1294d9007080fc9d714c6a3217d048a999ddf6927fbb165bd4c1b93
明文 SHA-256 = 5949c04563d0414dc1be9ad3f7e8cffd8b02cfca355fbc52da83a08b8942809b
```

密文从 VPS 复制到 Windows 后哈希一致；解密流哈希与原归档一致，本次校验没有在 Windows 落地明文。

## 恢复前检查

1. 把整个 `异地备份` 目录复制到一个访问受限的工作目录。
2. 确认 age 已安装，并确认私钥文件权限仅当前用户可读。
3. 先核对密文哈希，再解密；不要把 SSH 私钥上传到 VPS、网盘或聊天。

PowerShell 示例：

```powershell
$cipher = 'C:\Users\Yotoha\Desktop\KnowTrace-Workflow-VPS-部署学习-2026-09-06\阶段二\异地备份\knowtrace-20260907T151359Z-74b93d1a.tar.gz.age'
$identity = 'C:\Users\Yotoha\.ssh\knowtrace_vps_ed25519'
$restoreWork = Join-Path $env:TEMP 'knowtrace-restore-review'
New-Item -ItemType Directory -Force -Path $restoreWork
Get-FileHash -Algorithm SHA256 -LiteralPath $cipher
age --decrypt -i $identity -o (Join-Path $restoreWork 'knowtrace.tar.gz') $cipher
Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $restoreWork 'knowtrace.tar.gz')
tar -tzf (Join-Path $restoreWork 'knowtrace.tar.gz')
```

只有在哈希、归档目录和目标主机都确认后，才按项目 `verify-restore.sh` 在隔离环境恢复。检查完成后清理临时明文，并确认删除目标确实是上面的专用临时目录。

## 风险与下一步

- 当前 age 接收者复用了 VPS SSH 公钥，对应同一私钥；这不是理想的用途隔离。
- 桌面副本已离开 VPS，但仍依赖这一台 Windows 电脑，不等于多地域或长期备份。
- 下一步应创建专用离线 age 密钥，将密文再复制到第二个受控存储，并用新密钥做一次完整解密与业务恢复演练。
