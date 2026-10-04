# BUG-S2-005：Python 默认 CA 导致公网压测 TLS 失败

- 发现时间：2026-09-07 23:34（Asia/Shanghai）左右。
- 环境与版本：Windows Python 客户端；修复分支 `codex/stage2-backup-recovery`。
- 严重度：中。
- 状态：已关闭。
- 修复 commit：`fcadab5edb63ed940a9b3d891842bbfd39e5a9d7`。
- 关联证据：[压测与资源证据](../证据/2026-09-08-压测与资源证据.md)。

## 预期行为

对 `https://knowtrace.duckdns.org/api/health/ready` 执行受限 GET 压测时，使用可信 CA 验证服务器证书并得到 HTTP 200。

## 实际行为

首次 200 请求、并发 5 的公网运行全部记为 `network_error`。同一时间 Caddy 和 Nginx 均没有新增访问行，说明请求在客户端 TLS 阶段失败，没有到达 VPS。

Windows 原生 curl 和 .NET 证书策略验证均通过；服务器证书有效。Python/OpenSSL 报错指向其默认 CA 文件路径不可用，不能据此宣称网站 TLS 故障。

## 最小复现

1. 在该 Windows Python 环境中，不指定 CA 运行原版 `load-baseline.py`。
2. 请求全部失败，服务器侧无对应访问日志。
3. 使用 certifi CA 创建 SSL context 后，同一 URL 成功。

## 根因与修复

根因是工具隐式依赖运行环境默认 CA，而默认路径在该 Windows 环境中缺失或不可用；工具也没有把 CA 来源和代理条件写入结果，容易把客户端问题误判为服务问题。

修复内容：

- 增加 `--ca-file`，显式加载 PEM CA bundle；
- 增加 `--no-proxy`，允许验证真正公网直连链路；
- 每个工作线程使用独立 opener；
- 结果记录 TLS CA 来源和代理模式；
- 不提供 `--insecure`，不能关闭证书校验。

## 回归验证

- [x] Python 编译通过。
- [x] 指定不存在 CA 文件时以退出码 2 拒绝运行。
- [x] certifi CA + `--no-proxy` 的 20 请求/并发 2 回归全部成功。
- [x] 200 请求/并发 5 公网基线全部 200，Caddy 和 Nginx 各记录 200 行。
- [x] 测试后公网 ready 和 5 个容器继续健康。

## 回滚风险

回退此提交会重新引入环境依赖和误诊风险。若必须回滚，应继续通过显式可信 SSL context 包装脚本，不能用关闭 TLS 校验作为规避方案。
