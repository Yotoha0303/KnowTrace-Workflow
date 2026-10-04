# INC-S2-002：setupfirst 无效单元残留

- 首次发现：2026-09-07，阶段二主机健康清点。
- 恢复时间：2026-09-07。
- 状态：已关闭。
- 影响等级：低；污染 `systemctl --failed`，没有证据表明影响 KnowTrace-Workflow。

## 时间线

| 时间（UTC） | 事实、动作与结果 |
| --- | --- |
| 2026-09-07 | `setupfirst.service` 为 enabled/failed，退出状态 203/EXEC。 |
| 2026-09-07 | 只读检查确认 ExecStart 指向不存在的 `/setupfirst.sh`，且单元节名错误写成小写 `[unit]`。 |
| 2026-09-07 | 先备份单元并核对 SHA-256，再 disable，移到 `.disabled` 路径并 daemon-reload。 |
| 2026-09-08 | 受控重启后该单元为 not-found，没有再次失败；KnowTrace-Workflow 全链路正常。 |

## 根因

这是镜像或供应商初始化留下的不完整 systemd 单元：可执行脚本已经不存在，同时单元文件语法不规范。它不属于 KnowTrace-Workflow 发布物。

## 处置与证据

- 原文件备份：`/root/knowtrace-ops/backups/20260907T154500Z-setupfirst/setupfirst.service`。
- 原值与备份 SHA-256 已核对一致。
- 原单元移至 `/etc/systemd/system/setupfirst.service.disabled`，没有删除备份。
- `systemctl daemon-reload` 后 `setupfirst` 不再进入 failed 集合。
- 重启后复核仍为 not-found。

## 验证

- [x] KnowTrace-Workflow app/auth/Nginx/公网 ready 正常。
- [x] 5 个 Compose 容器 healthy。
- [x] 重启后单元不再加载。
- [x] 原始配置可恢复。

## 回滚

仅在确认 `/setupfirst.sh` 的来源、内容和必要性后，才从备份恢复到 `/etc/systemd/system/setupfirst.service`，修正单元并重新启用。直接恢复当前原件会重新产生 203/EXEC，不能视为有效修复。

## 改进

以后每次系统镜像升级或接管新 VPS，都先保存 `systemctl --failed`、enabled 单元和关键 ExecStart 目标清单，区分供应商初始化服务与业务服务。
