# ISSUE-S3-004：Docker 29 仅 internal 网络时不发布端口

> ⚠️ **已过期（2026-10-03 起）：本文涉及的 ELK 栈已被 PLG（Alloy + Loki）替换并删除。**
> 本文保留为**历史证据 / 可迁移教训**。其中的 ELK 操作步骤、端口 9200/5601、
> `scripts/linux/elk.sh`、`deploy/logstash/` 与两个 `logging-*` 网络**均已不存在**，
> **不要照着执行**。现行口径见 `docs/16-stage3-observability.md`
> 与 `docs/日常运维/运维手册.md`；换栈记录见
> `docs/changes/2026-10-03-ELK换PLG与deploy重构及Ansible引入.md`。


- 环境：Docker Engine 29.1.3、Docker Compose 2.40.3。
- 状态：已关闭。
- 修复 commit：`500d179`。
- 影响：Elasticsearch 容器内 healthy，但宿主机 `127.0.0.1:9200` 不可达，ELK 脚本安全退出。

## 关键证据

```text
HostConfig.PortBindings={9200/tcp -> 127.0.0.1:9200}
NetworkSettings.Ports={9200/tcp:null,9300/tcp:null}
ss: no listener on 127.0.0.1:9200
container curl: cluster status green
OOMKilled=false
```

临时把同一容器连接到第二个普通 bridge 后，端口映射立即出现并可访问，证明不是 Elasticsearch 配置或 UFW 问题。

## 根因

该 Docker 版本对只连接 internal bridge 的容器接受 PortBindings 配置，但没有真正建立宿主机映射，也没有报错。

## 修复

保留 `logging-internal` 用于 ELK 组件通信，并新增 `logging-management` 普通 bridge。9200、5000、5601 仍只绑定 `127.0.0.1`，没有开放 UFW。

## 验证

- 三个端口均显示 `127.0.0.1:<port>->...`。
- Elasticsearch、Logstash、Kibana healthy。
- ELK 端到端验收通过。

## 回滚风险

删除 management bridge 会在 Docker 29 上重现静默未发布。不要用绑定 `0.0.0.0` 或关闭防火墙来规避。
