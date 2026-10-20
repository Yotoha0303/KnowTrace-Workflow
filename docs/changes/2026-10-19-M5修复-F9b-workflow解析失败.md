# 2026-10-19 · F9b：修 `ci.yml` 的 workflow 解析失败（`job` / `runner` 上下文位置错误）

## 1. 现象（实测，不是推断）

`workflow_dispatch` 与 push 都被 GitHub 拒绝：

```text
$ gh workflow run ci.yml --ref ops/auth-backup-postgres
could not create workflow dispatch event: HTTP 422: Invalid Argument - failed to parse workflow:
(Line: 181, Col: 29): Unrecognized named-value: 'job'. Located at position 1 within expression: job.services.postgres.id,
(Line: 185, Col: 16): Unrecognized named-value: 'runner'. Located at position 1 within expression: runner.temp

$ gh run view 39258541786 --json conclusion,jobs
{"conclusion":"failure","event":"push","headBranch":"ops/auth-backup-postgres","jobs":[],"sha":"04188a4"}
```

## 2. 为什么这是**严重**形态

`jobs` 为空。**不是这一个 job 红，是该 commit 上整个 workflow 一条都不跑。**
若这个提交进了 `main`，此后**所有 push 都没有 CI**——而 `branch protection` 若要求检查项，
表现会是「永远 pending」而不是「失败」，更难归因。

## 3. 根因

`job` 与 `runner` 两个上下文在 **job 级 `env:`** 不可用，只在 **step 级 `env:`** 可用。
原写法把 `PG_SERVICE_CONTAINER: ${{ job.services.postgres.id }}` 与
`WORKDIR: ${{ runner.temp }}/...` 放在 job 级 `env:`。

## 4. 修法

把两者**下沉到需要它们的每个 step 的 `env:`**（`self-check` 不需要 service 容器，只给 `WORKDIR`）。

## 5. 判据

| 判据 | 期望 | 结果 |
| --- | --- | --- |
| 本地 YAML 语法解析 | 6 个 job 可枚举 | **待填** |
| `gh workflow run ci.yml --ref <branch>` | 不再 422 | **待填** |
| 触发后 `jobs` 非空 | 至少 5 个 job（quality / static-script-gate / backup-dump / go / e2e） | **待填** |
| 负向：把 `job.services...` 放回 job 级 env | dispatch 必须再 422 | **待填** |

> **本条修完才有 CI 证据可谈**——在此之前，F9 的「第二层进 CI」只写在文件里，从未被执行过一次。
