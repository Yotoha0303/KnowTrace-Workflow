# ISSUE-S2-001：Windows bash 解析到不可用 WSL

- 发现时间：2026-09-07。
- 状态：已规避。
- 影响：直接运行 `bash` 不能完成 shell 脚本语法检查，容易误判项目脚本有问题。

## 现象与原因

当前 PowerShell 中的 `bash` 解析到不可用的 WSL 转发路径；失败发生在启动 shell 环境，而不是脚本语法。机器上实际可用的 Git Bash 位于 `D:\Git\bin\bash.exe`。

## 处理与验证

显式使用以下程序执行语法检查：

```powershell
& 'D:\Git\bin\bash.exe' -n scripts/linux/backup-all.sh
```

阶段二相关 shell 脚本均通过 `-n`。没有为了本任务修改全局 PATH、WSL 或系统 shell 关联。

## 后续

若要修复全局命令解析，应另开环境治理任务，先检查 `Get-Command bash -All`、WSL 状态和 PATH 顺序，避免在部署任务中扩大系统变更。
