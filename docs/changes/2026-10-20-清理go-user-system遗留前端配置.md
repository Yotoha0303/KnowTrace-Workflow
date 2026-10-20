# 2026-10-20 · 清理 go-user-system 遗留前端配置与脚本

> **状态：先写后填（§5.2② / §2 02 环）。** 本文件先落「要改什么、判据是什么」，
> 实测结果在实施后回填；**未回填前不得宣布完成**。
> 依据：PR #50 物理删除 `services/go-user-system/frontend/`，M4 (PR #55) 清理 k8s 前端清单；
> 收口清理 `services/go-user-system/` 内已失效的前端编译、检查、发布目标与 CI 配置。

## 1. 变动范围

| 文件 | 改动 | 判据 |
| --- | --- | --- |
| `services/go-user-system/Makefile` | 移除 `K8S_FRONTEND_IMAGE` 变量；移除 `frontend-check` 目标与 help；移除 `k8s-build` 前端构建、`k8s-deploy` 前端清单应用、`k8s-status` 前端 Pod 检查 | `make -n` 不触发已删除的 frontend 目录 |
| `services/go-user-system/.github/dependabot.yml` | 移除 `/frontend` 依赖扫描配置 | 无 `/frontend` 块 |
| `services/go-user-system/.github/workflows/ci.yml` | 移除 `frontend:` job；`e2e` job 去除对 `frontend` 的 needs 依赖与安装步骤 | 工作流语法正常 |
| `services/go-user-system/.github/workflows/release.yml` | 移除 `Check frontend` 步骤；移除组件矩阵中的 `frontend` 项；移除打包 `frontend/dist` 逻辑 | 仅构建和发布后端产物 |
| `services/go-user-system/.golangci.yml` | 移除 `- frontend/node_modules` 忽略 | 无死路径引用 |
| `services/go-user-system/.dockerignore` | 移除 `frontend` 这一行 | 无死路径引用 |
| `services/go-user-system/README.md` · `CONTRIBUTING.md` | 说明独立 React 前端已废弃由外层 Next.js 接管；移除失效的命令指引 | 指引准确无死链接 |

## 2. 依据与背景

- **PR #50**：已全量移除 `services/go-user-system/frontend/` 目录。
- **M4 (PR #55)**：已从 k8s 清单中物理删除 `frontend-deployment.yaml` 与 `frontend-service.yaml`。
- **现状缺陷**：`Makefile` 仍包含 `cd frontend && npm ...` 与 `kubectl apply -f k8s/frontend-*.yaml`，CI 仍尝试调度 `frontend` job 并因目录不存在而报错或空转。必须彻底闭环收口。

## 3. 验收（可判定）

1. **静态脚本语法门**：`powershell -File tests/ci/static-script-gate.ps1` 全绿（exit 0）。
2. **死命令检索**：`git grep -in "frontend" -- services/go-user-system/` 除历史变更文档外，无未处理的死目标或死配置。
3. **Makefile 目标可解析**：`make help`、`make security` 在 `services/go-user-system/` 下无错误。

## 4. 回滚

若需回滚，通过 `git revert` 对应提交即可。不涉及线上数据状态变化。

## 5. 执行结果（回填区）

- 待实施后填入真实命令与输出。
