# MagicNet 工作流清理与格式核验

日期：2026-11-15（Asia/Taipei）

## 结果

删除诊断分支中的 4 份一次性工作流，停用 96 个已退出默认分支的历史工作流登记项。当前默认分支的 11 份工作流全部保留并通过 actionlint 1.7.12。完整登记清单和最终状态保存在 [JSON 记录](https://github.com/LIghtJUNction/MagicNet/blob/main/docs/workflow-cleanup-2026-11-15.json)。

| 仓库 | 保留的现行 YAML | 停用的历史入口 | 删除的诊断分支文件 | 保留的动态系统入口 |
| --- | ---: | ---: | ---: | ---: |
| LIghtJUNction/MagicNet | 2 | 93 | 1 | 4 |
| LIghtJUNction/magicnet-android | 9 | 3 | 3 | 0 |
| 合计 | 11 | 96 | 4 | 4 |

停用项目均经过 ID 与路径匹配、默认分支文件缺失、开放 PR 和运行历史核对。工作流状态逐项读回为 `disabled_manually`。历史运行记录与 artifacts 保留，因此旧运行页面仍可用于查证。

## 格式错误的核查结果

Actions 侧栏中的三个异常路径名来自历史工作流。使用它们的原始提交可以复现以下错误；这些文件在本轮开始前已经退出 main，本轮将对应入口退役。

| 历史文件 | 已复现的错误 | 证据 |
| --- | --- | --- |
| `apply-android-sed-fix.yml` | shell 条件语句落在 YAML 字面量块之外，破坏 YAML 结构。 | [失败运行 36725013534](https://github.com/LIghtJUNction/MagicNet/actions/runs/36725013534) |
| `apply-continuation.yml` | 多行提交说明缺少块缩进，YAML 解析失败。 | [失败运行 36475139008](https://github.com/LIghtJUNction/MagicNet/actions/runs/36475139008) |
| `maintenance-kernel-build.yml` | 嵌入字符串中的 `inputs.ksu_variant` 被解析为未定义的 Actions 输入。 | [失败运行 36427047013](https://github.com/LIghtJUNction/MagicNet/actions/runs/36427047013) |

当前 `release.yml` 的两个可复用工作流已固定到合并后的源码提交 `af72e0435c56bdebc724f2c93c2f775624f010f3`。该修复在本轮之前的 [fdf064f9](https://github.com/LIghtJUNction/MagicNet/commit/fdf064f9ae40065e0e1f2c8ac11ed024fa44cf30) 中完成；本轮没有将旧失败记录当作当前文件仍有语法错误。

## 删除的文件

以下删除均已提交到文件所在的诊断分支，没有删除整个分支或重写历史。

| 仓库 | 分支 | 删除文件 | 提交 |
| --- | --- | --- | --- |
| MagicNet | `diagnostic/issue-436-evidence-20261113` | `.github/workflows/issue436-evidence.yml` | [01641f1e](https://github.com/LIghtJUNction/MagicNet/commit/01641f1e003c75cfa889c638ee839ce1c0a0d196) |
| magicnet-android | `diagnostic/issue-436-ethernet-20261113` | `.github/workflows/ethernet-dump-diagnostic.yml` | [d8498e6b](https://github.com/LIghtJUNction/magicnet-android/commit/d8498e6b3bbcc48a81128b4a8b18d4cfd6ce5c2c) |
| magicnet-android | `diagnostic/issue-436-host-20261113` | `.github/workflows/issue-436-host-diagnostic.yml` | [f2b742f4](https://github.com/LIghtJUNction/magicnet-android/commit/f2b742f459c68f4296421b77aef2d21c7eb39c91) |
| magicnet-android | `diagnostic/issue-436-evidence-20261113` | `.github/workflows/issue436-evidence.yml` | [d60a7159](https://github.com/LIghtJUNction/magicnet-android/commit/d60a7159a22a614031831a70c2bfae7012e150fa) |

## 保留的现行入口

MagicNet 保留 `recipes.yml` 和 `release.yml`。Copilot reviewer、Copilot cloud agent、Dependabot Updates 与 Dependency Graph 四个动态入口保留。

源码仓库保留以下 9 份 YAML：

- `exec.yml`
- `android-kernelsu-acceptance.yml`
- `quality.yml`
- `install-onboarding.yml`
- `uninstall-farewell.yml`
- `network-regression.yml`
- `network-regression-evidence.yml`
- `rules-release.yml`
- `webui-preview.yml`

`webui-preview.yml` 是文档和回归测试明确保留的手动导出入口，可生成源码与构建预览制品；它没有被当作废弃工作流删除。

## 验证

| 验证内容 | 结果与证据 |
| --- | --- |
| 当前两库工作流语法与 Actions 表达式 | 2 + 9 份全部通过 actionlint 1.7.12；最终工作流文件恢复为已验证的原始内容。 |
| 主仓库发布与引用回归 | 18 项 release、41 项 release-plan、19 项 recipe/live-pin，共 78 项通过。 |
| 配方与完整提示词 | 8 个包、62 个 Markdown 文件的检查、打包、归档和完整提示词校验通过。 |
| 主仓库停用操作 | [Recipe checks 43726878443](https://github.com/LIghtJUNction/MagicNet/actions/runs/43726878443)。 |
| 源码仓库停用操作 | [专用维护 job 132849674145](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43726566565/job/132849674145) 成功。该链接只用于证明维护操作；同一运行中的其他构建或证据任务是独立任务。 |
| 源码临时任务移除 | [73722038](https://github.com/LIghtJUNction/magicnet-android/commit/73722038ab527c8d9926bc2ab532ba212bfab31e) 已移除临时维护 job；最终 tree `ced91db63d6e301dbcda75d7220a6fb829b8e132` 与本轮开始的 `af72e043` 完全相同。 |

一次性维护任务在执行后移除，没有留下新的常驻维护工作流。最终仅保留原有工作流文件与权限设置。
