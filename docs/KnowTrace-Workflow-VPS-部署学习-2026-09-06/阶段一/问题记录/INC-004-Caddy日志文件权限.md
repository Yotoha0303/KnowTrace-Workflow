# INC-004：Caddy 因访问日志文件属主错误启动失败

- 时间：2026-09-06
- 影响：Caddy 配置语法通过，但服务无法启动，80/443 暂时无人监听。
- 现象：systemd 报告打开 `/var/log/caddy/knowtrace-access.log` 时 `permission denied`。
- 根因：以 root 运行配置校验时预先创建了权限为 `600`、属主为 root 的日志文件；systemd 中的 Caddy 进程以 `caddy` 用户运行。
- 处理：将日志文件属主改为 `caddy:caddy`，权限设为 `0640`，随后重启 Caddy。
- 验证：Caddy 为 active，监听 80/443；本机 HTTP 请求返回 308 HTTPS 跳转，日志文件可写。
- 教训：静态配置校验只证明语法和适配成功，不证明运行用户具备文件访问权限；启动后必须检查服务状态和 journal。
