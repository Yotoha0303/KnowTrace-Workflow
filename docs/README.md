# KnowTrace-Workflow 文档索引

`docs/` 下的文档分五层。**先确认你要的是哪一类**，再读对应的那一层——这是本目录唯一的入口规则。

| 层 | 位置 | 回答什么问题 | 什么时候写 |
| --- | --- | --- | --- |
| **契约** | `00`–`08` | 产品**应该**是什么样：范围、需求、流程、领域、库表、接口、架构、AI 规范、验收标准 | 需求或设计变化时 |
| **决策** | [`adr/`](adr/README.md) | 为什么**这样选**而不是那样选 | 做出架构决策时 |
| **状态** | `13`、`19`、`21` | 现在**实际**到哪一步：完成度、缺陷清单、真实进度重估 | 状态变化时 |
| **变更** | [`changes/`](changes/README.md) | 产品侧**每一次改动的变动前记录**：改什么、为什么、验收、回滚 | **变动前** |
| **专题** | `09`–`12`、`14`–`18` | 计划、风险、运维、移动端与阶段推进 | 相关主题推进时 |
| **视角** | `22`、`23` | 同一个项目，**换一个读者身份**重讲：团队怎么接手、用户能不能信 | 有人要"从我的角度快速了解"时 |

> **契约层写「应该」，状态层写「实际」。两者不一致时，以状态层为准。**
> 这是本仓库最容易踩的坑：`docs/13` 报 90 分（建成完成度），
> `docs/21` 指出真实验证只有约 40 分。原因见 `docs/21` 第 0 节。

## 按读者找入口

- **第一次接触这个项目** → [`00-product-brief.md`](00-product-brief.md) → [`06-architecture.md`](06-architecture.md) → [`13-product-completion-audit.md`](13-product-completion-audit.md)
- **想知道系统实际长什么样**（组件/链路/信任边界） → [`24-architecture-diagrams.md`](24-architecture-diagrams.md)
- **想接 `/api/v1` 写客户端** → [`12-mobile-api.md`](12-mobile-api.md)（认证、Workspace 上下文、端点与错误码都在这里）
- **想知道现在有什么是坏的** → [`19-product-defect-inventory.md`](19-product-defect-inventory.md)
- **要动代码/配置** → 先按 [`changes/README.md`](changes/README.md) 的约定在 `changes/` 写变动前记录
- **要上服务器**（日常最常用） → [`日常运维/运维手册.md`](日常运维/运维手册.md) ——
  连接、巡检、日志、备份恢复、部署、故障排查、加固，命令都实测过。
  **想核对「部署算不算完成」** → [`日常运维/部署清单与验收.md`](日常运维/部署清单与验收.md)。
  产品侧的运行说明见 [`11-operations.md`](11-operations.md)；运维工作区在仓库外 `KnowTrace-ops/notes/04-文档索引与任务.md`
- **想做架构决策** → [`adr/README.md`](adr/README.md)
- **要接手这个项目（团队）** → [`22-团队视角-接手与协作.md`](22-团队视角-接手与协作.md)
- **只是想用它（使用者）** → [`23-用户视角-使用与信任边界.md`](23-用户视角-使用与信任边界.md)

## 契约层

| 文档 | 内容 |
| --- | --- |
| [`00-product-brief.md`](00-product-brief.md) | 产品范围、原则与明确不做的部分 |
| [`01-requirements.md`](01-requirements.md) | 业务需求与用户故事 |
| [`02-user-flows.md`](02-user-flows.md) | 用户流程 |
| [`03-domain-model.md`](03-domain-model.md) | 领域模型与状态机 |
| [`04-database-design.md`](04-database-design.md) | 数据库设计与迁移 |
| [`05-api-contract.md`](05-api-contract.md) | 服务端操作契约与错误码 |
| [`06-architecture.md`](06-architecture.md) | 技术架构、依赖方向、部署形态 |
| [`24-architecture-diagrams.md`](24-architecture-diagrams.md) | **技术架构图（10 张）**：部署拓扑、鉴权链路、数据可见性、信任边界、依赖方向、**AI 整理流水线**、**主张证据状态机**、**数据导入导出 v2**、**生态链路**（`06` 回答「为什么这样选」，本文回答「实际长什么样」） |
| [`07-ai-processing.md`](07-ai-processing.md) | AI 处理规范与供应商适配 |
| [`08-test-and-acceptance.md`](08-test-and-acceptance.md) | 测试策略与验收场景 |

> `06-architecture.md` 第 4 节的目录树写于实施之前，是**规划态**，与当前实际目录
> （`src/features/` 下已有 13 个域）不完全一致；读它时应关注分层与依赖方向，而不是逐条核对路径。

## 决策层

[`adr/`](adr/README.md)：ADR-0001 至 ADR-0018，含已被替代的决策及其替代关系。

## 计划与专题

| 文档 | 内容 |
| --- | --- |
| [`09-delivery-plan.md`](09-delivery-plan.md) | 开发计划与阶段划分 |
| [`10-risk-register.md`](10-risk-register.md) | 风险清单 |
| [`11-operations.md`](11-operations.md) | 运行、备份与恢复 |
| [`12-mobile-api.md`](12-mobile-api.md) | `/api/v1` 契约：认证、Workspace、端点、错误码 |
| [`14-deferred-issues.md`](14-deferred-issues.md) | 暂缓问题与后续迭代清单 |
| [`15-stage2-vps-reliability.md`](15-stage2-vps-reliability.md) | VPS 阶段二：备份、恢复、压测与故障迭代 |
| [`16-stage3-observability.md`](16-stage3-observability.md) | VPS 阶段三：指标、可视化、集中日志与邮件告警 |
| [`17-mobile-client-bugs-and-features.md`](17-mobile-client-bugs-and-features.md) | 多平台客户端阶段的待修问题 |
| [`18-mobile-client-plan.md`](18-mobile-client-plan.md) | 多平台应用开发方案 |

## 视角层

同一个项目，换一个读者身份重讲。**不新增事实**，只重新组织与取舍；每条结论都指回契约层或状态层的出处。

| 文档 | 读者 | 回答什么 |
| --- | --- | --- |
| [`22-团队视角-接手与协作.md`](22-团队视角-接手与协作.md) | 接手或加入的团队（2–10 人） | 先信什么、先做什么、先防什么；团队化后缺哪些协作机制 |
| [`23-用户视角-使用与信任边界.md`](23-用户视角-使用与信任边界.md) | 准备使用它的人 | 它能帮你做什么、**你不能指望它做什么**、隐私与隔离的真实情况 |

> 第三个维度（**个人 / 独立开发者视角**）不在本仓库，见
> [`../../KnowTrace-career-assets/独立开发者视角.md`](../../KnowTrace-career-assets/独立开发者视角.md)——
> 它的读者是"未来的我自己"，与职业资产工作区同一批读者。

## 状态层

| 文档 | 内容 |
| --- | --- |
| [`13-product-completion-audit.md`](13-product-completion-audit.md) | 按能力域加权的**建成**完成度（90/100） |
| [`19-product-defect-inventory.md`](19-product-defect-inventory.md) | 缺陷与体验问题清单，按 P0/P1 分级，含实测证据与修复状态 |
| [`20-incident-2026-09-30-causation.md`](20-incident-2026-09-30-causation.md) | 2026-09-30 全站 500 事故的成因 |
| [`21-path-to-100-percent.md`](21-path-to-100-percent.md) | 把「建成」重估为「**被真实验证过**」的进度（约 40 分）与补齐路径 |

## 其他目录

| 目录 | 内容 |
| --- | --- |
| [`changes/`](changes/README.md) | 产品侧变动前记录。**改代码或配置前先来这里** |
| [`日常运维/`](日常运维/README.md) | **运维入口在这里**：[运维手册](日常运维/运维手册.md)（怎么做）、[部署清单与验收](日常运维/部署清单与验收.md)（算不算完成）；另有巡检记录与运维回顾 |
| [`KnowTrace-Workflow-VPS-部署学习-2026-09-06/`](KnowTrace-Workflow-VPS-部署学习-2026-09-06/README.md) | 阶段一至三的真实 VPS 学习档案：部署命令、故障记录、迁移清单。**阶段三的 ELK 部分已于 2026-10-03 作废**（换 PLG），文首有标注 |

> ⚠️ **2026-10-03 仓库更名**：`Yotoha0303/KnowTrace` → `Yotoha0303/KnowTrace-Workflow`。
> 迁移清单见 [`changes/2026-10-03-仓库与运行时改名迁移.md`](changes/2026-10-03-仓库与运行时改名迁移.md)：
> **服务器侧已执行完毕**；**本地那个归档目录名与仓库根目录名尚未改**
> （被进程占用），所以指向它的链接暂时是断的 —— 目录一改名即自动恢复，文档无需再动。
> **明确未改**：域名 `knowtrace.duckdns.org`、服务器绝对路径、Prometheus 指标名、SSH 别名与密钥。

## 仓库外

以下内容不在本目录，但和上面的文档是同一套体系：

| 位置 | 内容 |
| --- | --- |
| `../KnowTrace-ops/notes/` | 运维侧总索引与 VPS 连接说明 |
| `../KnowTrace-ops/docs/` | 运维执行记录与事故复盘 |
| `../CONTRIBUTING.md` | 提交前验证与**部署验证**的权威写法 |
| `../SECURITY.md` | 安全策略与漏洞报告方式 |
