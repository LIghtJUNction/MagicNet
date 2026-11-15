# MagicNet Build CI 启动故障修复

## 结果

修复已提交到 MagicNet 主分支：[fdf064f9](https://github.com/LIghtJUNction/MagicNet/commit/fdf064f9ae40065e0e1f2c8ac11ed024fa44cf30)。推送后的 [Recipe checks 43726001521](https://github.com/LIghtJUNction/MagicNet/actions/runs/43726001521) 已成功，本地 78 项发布与固定值回归全部通过。

## 原因与修复

[失败运行 43706037821](https://github.com/LIghtJUNction/MagicNet/actions/runs/43706037821) 在启动阶段结束，未创建构建任务。GitHub 的原始错误指向 `.github/workflows/release.yml` 调用的 `exec.yml@4b02897dffd6acd455c0e25849b46398ca1465b6`：`workflow was not found`。

[源码 PR #10](https://github.com/LIghtJUNction/magicnet-android/pull/10) squash 合并后，主分支中的提交是 `af72e0435c56bdebc724f2c93c2f775624f010f3`。旧 PR head `4b02897dffd6acd455c0e25849b46398ca1465b6` 未进入 main 历史，原工作分支已删除；主仓仍将两个可复用工作流固定到旧 head，导致 Actions 在执行 planner 前解析失败。

修复统一更新子模块 gitlink、Build 和 Android 两个可复用工作流、三语 README、BUILD_PROMPT、DEPENDENCIES 与当前验证索引。两个源码提交的 Git tree 均为 `ced91db63d6e301dbcda75d7220a6fb829b8e132`，源码文件内容完全相同。历史 CI 和产物继续保留其实际 `4b02897` 来源身份。

后续源码 PR 使用 squash 合并时，应在主仓更新 gitlink 的同一提交中，将两个可复用工作流和活动文档固定值一起改为源码主线中的合并 SHA。

## 验证证据

| 检查 | 结果 |
| --- | --- |
| 配方与源码全部工作流的 actionlint 1.7.12 校验 | 通过 |
| 配方 check、pack、归档 check、完整 build 提示词 | 通过：8 个包、62 个 Markdown 文件 |
| `scripts/test-release.py` | 18/18 通过 |
| `scripts/test-release-plan.py` | 41/41 通过 |
| `scripts/test-check-recipes.py` | 19/19 通过 |
| 主仓修复提交的 Recipe checks | [43726001521](https://github.com/LIghtJUNction/MagicNet/actions/runs/43726001521)，成功 |
| 新固定源码 `af72e043` 的既有 Build | [43704717207](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43704717207)，成功 |
| 新固定源码 `af72e043` 的既有 Code Quality | [43704717198](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43704717198)，成功 |
| 新固定源码 `af72e043` 的既有 Android KernelSU Acceptance | [43704717178](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43704717178)，成功 |

源码主分支同一提交的 Network regression、Rules Release Integration、Install Onboarding 和 Network Regression Evidence 也已核验为成功。这些是源码仓库的运行结果；主仓修复后的完整 Build 仍需新建一次运行。

## 新建 Build 运行

当前 GitHub 连接提供代码写入与运行读取，但未提供 workflow_dispatch 接口；命令行无 GitHub 登录凭据，浏览器也未登录，因此本次未自动发起主仓的新 Build。

在 [Build and release MagicNet](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml) 页面选择 `Run workflow`，分支选 `main`，模式选 `build`，即可使用修复后的工作流创建新运行。版本参数按本次构建目标选择。GitHub 的旧运行重试会继续使用原始 `GITHUB_SHA` 与 `GITHUB_REF`，因此验证本次修复应新建运行；相关行为见 [GitHub 官方说明](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs?tool=webui)。

此次修改完成 CI 引用修复，稳定发行索引仍为 v1.8.7 / 10615。
