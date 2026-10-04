# ISSUE-S3-002：Prometheus 只读父挂载与嵌套 Secret 冲突

- 范围：首次 VPS 部署。
- 状态：已关闭。
- 修复 commit：`7ce26f7`。
- 影响：部署在修改应用前安全失败；旧业务继续运行。

## 现象

Prometheus 校验容器把整个 `/etc/prometheus` 作为只读目录挂载，同时又尝试把 metrics token 文件挂到其子路径。Docker 无法正确建立这种父目录只读、子路径另挂载的组合。

## 根因

配置校验命令复用了运行时目录布局，但忽略了 bind mount 的嵌套约束。

## 修复

将 `prometheus.yml`、rules 目录和 secret 文件分别挂载到互不覆盖的独立路径，不再只读挂载整个父目录。

## 验证

- `promtool check config` 通过。
- 1 个规则文件、15 条规则通过校验。
- Prometheus 容器 healthy。
- 12/12 targets UP。

## 预防

部署前用与生产等价的只读挂载执行校验；父目录与其子路径不要重复 bind mount。
