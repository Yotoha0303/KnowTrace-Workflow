# 巡检定时任务备忘（6 个 systemd 单元）

最后更新：2026-09-28
状态：**已安装到 `/etc/systemd/system/` 并已 `enable --now`，定时任务在运行。**

| 定时器 | 下次触发 | 说明 |
| --- | --- | --- |
| `knowtrace-workflow-backup.timer` | 每天 19:22 UTC | 原有备份任务（先跑） |
| `knowtrace-workflow-daily-ops.timer` | 每天 19:34 UTC | 日巡检（后跑，能看到当天备份） |
| `knowtrace-workflow-weekly-check.timer` | 周一 20:04 UTC | 周巡检 |
| `knowtrace-workflow-monthly-ops.timer` | 每月 1 日 21:06 UTC | 月巡检（演练模式） |
| `knowtrace-workflow-offsite-backup.timer` | 每天 20:12 UTC | 异地加密上传（**不属本目录**，见 §9） |
| `knowtrace-workflow-alert-drill.timer` | 周一 20:30 UTC | 告警送达演练（**不属本目录**，见 §9） |

（实际触发时间会带 `RandomizedDelaySec` 的随机偏移，所以上面不是整点。
**别把某次读数写死进文档** —— 一律 `systemctl list-timers` 现查。）

> **2026-10-05 补两条与本目录相关的知识**：
>
> 1. **`systemd.failed-units` 判据**：巡检现在会检查 `systemctl --failed`，
>    只对**不在 `SYSTEMD_FAILED_ALLOWLIST` 里**的 failed 单元报 FAIL
>    （白名单**缺省为空** = 任何 failed 都算问题）。本机白名单只有 `repass.service`
>    （`INC-S2-003` 判它是云厂商控制台救援链路，刻意保留）；`setupfirst.service`
>    按 `INC-S2-002` 的处置已清掉，**不在白名单**。
>    ⚠ 本节 §7 的注释「本机另有一个与巡检无关的 repass.service 长期是 failed 状态」
>    现在**过时了**：它不再是「与巡检无关」——巡检会看到它，只是因为它**在白名单里**
>    才不报。若哪天它不在白名单了，日报会 FAIL。这两件事要一起看。
>
> 2. **`alert-drill` 的 `Persistent=false` 是本目录之外的一个刻意例外**（见 §9）：
>    判据要求「由定时器自然触发」，而安装时的 `Persistent=` 补跑**不算自然**
>    （参 `KT-GAP-22` 对 weekly-check 的处理）。本目录的四个单元都是
>    `Persistent=true`，那个不同是**有意**的，不是漏配。

---

## 1. 这 6 个单元是什么

| 单元 | 类型 | 触发时间（UTC） | 做什么 |
| --- | --- | --- | --- |
| `knowtrace-workflow-daily-ops.timer` → `.service` | 每天 | `*-*-* 19:30:00` | 只读日巡检：资源、磁盘、容器、健康端点、监控 Targets、**主机 systemd 单元（含 failed 单元白名单）** |
| `knowtrace-workflow-weekly-check.timer` → `.service` | 每周一 | `Mon *-*-* 20:00:00` | 只读周巡检：备份完整性校验、日志错误聚类、证书有效期、异常登录、**主机 systemd 单元** |
| `knowtrace-workflow-monthly-ops.timer` → `.service` | 每月 1 日 | `*-*-01 21:00:00` | 月巡检：**演练模式**，只出计划不执行写操作 |

三个 `.service` 都是 `Type=oneshot`，三个 `.timer` 都是 `Persistent=true`。

**触发时间不是随便定的**：已有的 `knowtrace-workflow-backup.timer` 在 **19:21 UTC** 跑备份，
所以日巡检排在 19:30（能看到当天的备份）、周巡检排在周一 20:00（校验的是刚生成的归档）。
改时间时别把它们排到备份之前，否则「备份新鲜度」检查会看到昨天的归档。

另：`MONTHLY_WRITE_WINDOW=1-6`（UTC 1~6 点）已设置，服务器时区是 UTC，
换算成本地时间是 **上午 9 点到下午 2 点**。它只约束 `--apply` 的人工执行，不影响定时器的只读巡检。

## 2. 三个单元的关键差异

`ExecStart` 都是同一套参数，只换脚本：

```
/usr/bin/bash /opt/knowtrace-ops/scripts/<脚本>.sh \
    --quiet --record --json /var/lib/knowtrace/reports/ --markdown /var/lib/knowtrace/reports/
```

- `--quiet` 只输出 WARN/FAIL，输出短，适合直接当邮件正文
- `--record` 生成符合 `docs/日常运维/` 格式的记录骨架（**需人工定稿**）
- `--json` / `--markdown` 都传**目录**，脚本自己补时间戳文件名

**唯一的例外**：`monthly-ops.service` 刻意**不带 `--apply`**。定时任务只做只读检查并列出
「将要执行」的动作；写操作永远人工确认后执行：

```bash
sudo bash /opt/knowtrace-ops/scripts/monthly-ops.sh --apply
```

## 3. 安装步骤（已完成，留作重建参考）

> **2026-09-29 起改用脚本**：`systemd/install.sh` 把这套步骤固化了下来，
> 并强制「先 start 验证再 enable」的顺序（见第 6.1 节：`Documentation=` 的坑
> `systemd-analyze verify` 查不出来，只有真 start 一次读 journal 才行）。
> 验证不通过会 `exit 2` 并**中止，不启用定时器**。
>
> ```bash
> bash /opt/knowtrace-ops/systemd/install.sh --dry-run   # 先看计划
> bash /opt/knowtrace-ops/systemd/install.sh             # 真装
> ```
>
> 脚本幂等，重复运行安全。下面的手工步骤保留作为原理参考——

```bash
# 1) 装单元
sudo cp /opt/knowtrace-ops/systemd/*.service /opt/knowtrace-ops/systemd/*.timer /etc/systemd/system/
sudo chmod 644 /etc/systemd/system/knowtrace-*.service /etc/systemd/system/knowtrace-*.timer

# 2) 生效
sudo systemctl daemon-reload

# 3) 先干跑一次，确认能跑通（不依赖定时器）
sudo systemctl start knowtrace-workflow-daily-ops.service
systemctl status knowtrace-workflow-daily-ops.service --no-pager

# 4) 确认无误再启用定时
sudo systemctl enable --now knowtrace-workflow-daily-ops.timer
sudo systemctl enable --now knowtrace-workflow-weekly-check.timer
sudo systemctl enable --now knowtrace-workflow-monthly-ops.timer

# 5) 核对下次触发时间
systemctl list-timers 'knowtrace*' --no-pager
```

**装之前建议先设写时间窗**。`ops.conf` 里 `MONTHLY_WRITE_WINDOW` 目前是**空值 = 不限制**，
建议改成低峰时段，例如 `MONTHLY_WRITE_WINDOW=1-6`（UTC 1~6 点）。
它只影响 `monthly-ops.sh --apply` 的人工执行，不影响定时器的只读巡检。

## 4. 沙箱设置（三个单元一致）

```ini
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/knowtrace /var/log/knowtrace-logs
```

`ProtectSystem=full` 把 `/usr` `/boot` `/etc` 挂成只读，`ReadWritePaths` 再单独放开
报告目录与记录目录。这是「只读脚本收紧一层权限」的落地，**2026-09-28 已用
`systemd-run --property` 复刻同款设置实测通过**：报告与记录都写得进去。

要注意：这套沙箱下脚本**不能**改 `/etc`。以后若给巡检脚本加写 `/etc` 的需求，
必须同步改 `ReadWritePaths`，否则会以「权限不足」的方式静默失败。

## 5. 退出码语义（重要，别误配告警）

三个单元都有：

```ini
SuccessExitStatus=0 1 2
```

因为脚本退出码表达的是**巡检结论**，不是**服务成败**：

| 退出码 | 含义 |
| --- | --- |
| 0 | 未发现异常 |
| 1 | 存在 WARN |
| 2 | 存在 FAIL |
| 3 | 脚本自身错误（参数、依赖、环境） |

`SuccessExitStatus=0 1 2` 让 systemd 不因「检出 WARN/FAIL」而把单元标成 failed ——
否则 `systemctl --failed` 会长期挂着红，反而让人忽略真正的故障。
结论由 JSON 报告与告警链路负责。

**要改行为**：想让 systemd 因 FAIL 报警，删掉那一行即可（这样退出码 2 会让单元变 failed）。
想让退出码恒为 0，设环境变量 `OPS_EXIT_ZERO=1`。

## 6. 三个踩过的坑

### 6.1 `Documentation=` 有两个坑，第二个 `systemd-analyze verify` 查不出来

```ini
# ✗ 坑 1：原始中文路径 —— systemd 只接受可打印 ASCII 的 URI，整条被丢弃
Documentation=file:/opt/knowtrace-ops/运维脚本使用说明.md

# ✗ 坑 2：裸百分号编码 —— URI 里的 % 会被当成「单元说明符」（如 %E）解析，整条被丢弃
Documentation=file:///opt/knowtrace-ops/%E8%BF%90%E7%BB%B4...%E6%98%8E.md

# ✓ 正确：中文文件名 + 百分号编码 + 把每个 % 写成 %%
Documentation=file:///opt/knowtrace-ops/%%E8%%BF%%90%%E7%%BB%%B4%%E8%%84%%9A%%E6%%9C%%AC%%E4%%BD%%BF%%E7%%94%%A8%%E8%%AF%%B4%%E6%%98%%8E.md
```

两种错误的报错不一样，而且**都只是警告，不阻止加载**，所以很容易被忽略：

| 写法 | 报错 | 何时可见 |
| --- | --- | --- |
| 原始中文路径 | `Invalid URL, ignoring: ...` | `systemd-analyze verify` 就能看到 |
| 裸百分号编码 | `Failed to resolve unit specifiers in '...', ignoring: Invalid slot` | **只有真的 start 一次，看 journal 才会出现** |

坑 2 的隐蔽之处：`systemd-analyze verify` 对它**不报任何错**（当时实测 6 个单元全是 `InvalidURL=0`），
必须用下面任意一种方式才能验出来：

```bash
systemctl start <单元>.service && journalctl -u <单元>.service --since "-2min" --output=cat | grep specifier
systemctl show -p Documentation <单元>.service     # 看解析结果是否为空
```

**推荐用 ASCII 路径**（例如把手册同时放在一个英文名下），可以彻底绕开这两个坑。
当前的做法是保留中文名，因为 `Documentation=` 指向 `docs/` 下那一份唯一副本
（不再有根目录的重复件），实测解析与 journal 都干净。

**教训（2026-09-28 踩到）**：部署根目录曾另放一份过时的手册副本，而单元
`Documentation=` 指向它 —— 三份单元都在指向一份没人维护的文件，
`docs/` 那份真正在改的反倒被晾着。**派生路径要指向唯一权威副本**，
不要在部署目录留"看起来更方便"的第二份。

### 6.2 报告目录必须显式传，否则会分裂成两份

脚本不带 `--json` 时，兜底目录是 `<工具包>/reports/`。单元里显式传了
`--json /var/lib/knowtrace/reports/`，与 `ops.conf` 的 `REPORTS_DIR` 一致。
**两边必须保持同一个值** —— 一旦不一致，同一批巡检会出现两份互不可见的报告，
`weekly-check` 的「每日巡检有没有在产出」和 `ops-report.py` 的汇总都会看漏。

（2026-09-28 修过这个缺陷：`ops_write_json` 的兜底现在优先跟随 `REPORTS_DIR`；
`daily-check.sh` 也补了 `export REPORTS_DIR`。）

## 7. 日常运维命令

> 注意 `--no-pager` 是 systemctl 的**全局选项，必须放在动词之前**。
> 写成 `systemctl list-timers ... --no-pager` 会报 `unrecognized option`。

```bash
# 看下次什么时候跑
systemctl --no-pager list-timers 'knowtrace*'

# 手动触发一次（不等到点）
sudo systemctl start knowtrace-workflow-daily-ops.service

# 看最近一次执行
systemctl --no-pager status knowtrace-workflow-daily-ops.service
journalctl -u knowtrace-workflow-daily-ops.service -n 50

# 看有没有失败
#（2026-10-05 更正：这条注释原先写「本机另有一个与巡检无关的 repass.service 长期是
#  failed 状态」—— 现在**不再「与巡检无关」**：巡检的 systemd.failed-units 判据会看它，
#  只是因为它在 SYSTEMD_FAILED_ALLOWLIST 里才不报。若哪天从白名单移走，日报会 FAIL。）
systemctl --failed

# 临时停掉定时（排查时）
sudo systemctl stop knowtrace-workflow-daily-ops.timer

# 确认安装是否被改动过（6 个单元都应存在，Documentation 解析结果都不应为空）
ls -la /etc/systemd/system/knowtrace-*ops* /etc/systemd/system/knowtrace-*check*
systemctl show -p Documentation knowtrace-workflow-daily-ops.service
```

`Persistent=true` 的含义：如果机器在触发时刻是关机的，开机后会补跑一次。
所以停机维护后不会漏掉巡检记录。

**回滚**（要停掉全部巡检定时器）：

```bash
sudo systemctl disable --now knowtrace-workflow-daily-ops.timer knowtrace-workflow-weekly-check.timer knowtrace-workflow-monthly-ops.timer
sudo rm -f /etc/systemd/system/knowtrace-{daily-ops,weekly-check,monthly-ops}.{service,timer}
sudo systemctl daemon-reload
```


## 8. 日志去向

- **systemd 侧**：`journalctl -u knowtrace-<任务>.service`
- **巡检结论**：`/var/lib/knowtrace/reports/*.json` + `*.md`
- **记录骨架 + 月度归档**：`/var/log/knowtrace-logs/<年月>/`
  （`<年月>` 是 `YYYYMM`，如 `202609` —— 记录骨架与 `reports.tar.gz` 都放这一层）

> ✅ **journal 是持久化的（2026-09-28 更正）**：早先笔记里写的「journal 未持久化」是错的。
> 实测 `/var/log/journal/` 目录存在、`journalctl --disk-usage` 显示 346.6M、
> `journalctl --list-boots` 能看到 2024-06-16 以来的多次启动记录。
> `/etc/systemd/journald.conf` 是注释状态（`auto`），而 `/var/log/journal` 存在时
> `auto` 等价于持久化。所以**重启后仍能查到定时任务的执行痕迹**，不必额外配置。
>
> 要查历史执行：
> ```bash
> journalctl -u knowtrace-workflow-daily-ops.service --since "7 days ago" --output=short-iso
> journalctl -u knowtrace-workflow-daily-ops.service --list-boots
> ```

## 9. 相关文件

| 路径 | 说明 |
| --- | --- |
| `knowtrace-{daily-ops,weekly-check,monthly-ops}.timer` | 触发时间定义；改时间改这里，改完 `daemon-reload` |
| `knowtrace-{daily-ops,weekly-check,monthly-ops}.service` | 执行内容、沙箱设置、`SuccessExitStatus` |
| `../ops.conf.example` | 配置模板；阈值、路径、`MONTHLY_*` 开关、`MONTHLY_WRITE_WINDOW` 都在这里 |
| `../docs/运维脚本使用说明.md` | 完整手册：安装、用法、安全模型（四道闸） |
| `../scripts/monthly-ops.sh` | 唯一会写服务器的脚本，四道闸保护 |

服务器上实际生效的副本在 `/etc/systemd/system/knowtrace-{daily-ops,weekly-check,monthly-ops}.{service,timer}`
（由本目录的文件 `cp` 过去）。**改单元要改这里、再 `cp` + `daemon-reload`**，别直接改 `/etc/systemd/system/`，
否则下次同步会被覆盖。
