# ISSUE-S3-011：客户端验收命令误用造成假失败

- 范围：阶段三代码同步后的客户端验收。
- 状态：已关闭。
- 处理时间：2026-09-08 17:59（Asia/Shanghai）。
- 服务器影响：无；没有重启或修改运行中的服务。

## 现象

1. `git pull --ff-only` 已显示 fast-forward 成功，但随后输出
   `unexpected_head`。
2. Windows 公网检查出现 `Cannot overwrite variable HOME`。
3. 对不存在的公网路径 `/api/readyz` 请求得到 401。

这些输出一度看起来像部署或网站异常，但均来自验收命令本身。

## 根因

1. 人工根据短提交号手写完整哈希，写错了期望值；Git 同步本身已成功。
2. PowerShell 变量名不区分大小写，使用了与只读系统变量冲突的名称。
3. 把认证服务的 `/readyz` 路径误套到 KnowTrace-Workflow；正式应用路径是
   `/api/health/ready`。

## 修正与证据

- 分别执行 `git rev-parse HEAD`，本地和 VPS 均为
  `31f49641d310c693d829ce8ca6b7a24078a196ed`。
- 后续 PowerShell 变量均使用任务专用名称。
- 使用项目正式验收脚本，结果为 12/12 targets UP，所有核心检查通过。
- Windows 绕过本地代理后重新验证：

```text
ready_http=200 ssl_verify=0
root_http=307 redirect=https://knowtrace.duckdns.org/login ssl_verify=0
metrics_http=404 ssl_verify=0
tcp_22345=True
tcp_22=False
```

## 学习结论

- 先区分“变更命令失败”和“变更后的验证命令失败”。
- 不人工扩写 Git 哈希；始终从两个端点读取后比较。
- PowerShell 脚本使用任务前缀变量名，不复用系统保留变量。
- 健康路径必须从项目契约或监控配置读取，不能凭记忆猜测。
