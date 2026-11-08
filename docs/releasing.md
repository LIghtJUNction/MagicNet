# 发布 MagicNet

统一入口：[Build and release MagicNet](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml)。`magicnet-android`提供构建和Android验收；安装包、组件、Release和稳定更新索引属于`LIghtJUNction/MagicNet`。

## 选择版本并运行

在入口点击 **Run workflow**，选择 **main**。常规发布使用`mode=publish`、`bump=patch`；需要源码最新提交时加`source_ref=main`。精确版本使用`bump=none`和`version=1.9.0`；源码版本尚未公开时，`bump=none`且version留空即可沿用。

| 参数 | 作用 |
| --- | --- |
| `mode=build` | 默认；构建、校验安装包和组件，上传Actions artifacts |
| `mode=verify` | 构建加全部质量与Android/KernelSU验收，不创建Release |
| `mode=publish` | 全部门禁通过后公开Release，再同步稳定索引 |
| `bump` | `none / patch / minor / major`；以源码声明与已公开版本中较新者递增 |
| `version` | `X.Y.Z`或`vX.Y.Z`，要求bump=none；拒绝前导零、版本后缀及更旧源码版本 |
| `version_code` | 可选整数`1..2147483647`；发布时高于已公开版本 |
| `source_ref` | 留空用主仓库gitlink；分支、标签或完整SHA解析一次后固定 |
| `prerelease` | 仅publish；标记预发布并保留稳定update.json和README |

版本不变默认沿用源码code；版本变化默认取源码与已公开code的较大值加一。build/verify使用主仓库稳定索引作预览基线，publish另查GitHub全部已公开版本（含预发布）；已有版本不覆盖。

GitHub CLI登录后可运行同一入口，无需跨仓库PAT：

```bash
# 完整验收下一个补丁版
gh workflow run release.yml --repo LIghtJUNction/MagicNet --ref main \
  -f mode=verify -f bump=patch -f source_ref=main

# 发布下一个补丁版
gh workflow run release.yml --repo LIghtJUNction/MagicNet --ref main \
  -f mode=publish -f bump=patch -f source_ref=main

# 发布精确版本，自动计算versionCode
gh workflow run release.yml --repo LIghtJUNction/MagicNet --ref main \
  -f mode=publish -f bump=none -f version=1.9.0 -f source_ref=main

# 先构建精确版本与code
gh workflow run release.yml --repo LIghtJUNction/MagicNet --ref main \
  -f mode=build -f bump=none -f version=1.9.0 -f version_code=10700
```

## 固定来源与门禁

publish保存`release/run-<run_id>`快照，包含release-plan.json、目标updater、发行说明和源码gitlink；版本标签指向该快照。构建与Android检出同一SHA，用同一脚本注入版本/code/官方URL/KAM说明；build-source.json区分版本注入前的源码基线与目标版本。source_ref只改变本次快照，不移动main的gitlink；原run重跑保留原快照。旧源码必须具备`scripts/stamp-release.py`和新版构建接口。

产物含MagicNet.zip、MagicNet-core.zip、magicnet_installer.zip、MagicNet-full.zip、所有组件、清单、来源、updater和SHA256SUMS。前三者字节相同，full可离线安装；最终ZIP门禁拒绝测试、fixture、benchmark、coverage和node_modules目录。

工作流/发布脚本/源码pin相关PR执行完整发布预览，普通main push运行轻量配方回归；`bash scripts/check-workflows.sh`以固定版本和摘要的actionlint检查全部workflow。plan_read固定contents:read，plan_publish固定contents:write并仅用于显式publish；共用准备action。公开发行要求plan、build、Android及资产核验均成功。模拟器范围与物理ARM64/实网验收分别记录。

## 失败后继续

构建或验收失败阻止公开。上传先用草稿，核对服务端名称、大小和SHA-256，完整后公开；既有版本及内容不符的已上传资产不覆盖。

上传中断时选择原运行的 **Re-run failed jobs**。任务核对原run、artifact ID和固定快照，保留有效资产，仅补缺失项；身份一致的草稿内，零字节starter占位项按资产ID清理。重新构建改变artifact ID后不能接管旧草稿；原artifact保留30天。

Release公开而索引失败时，重跑失败发布job先核对公开资产，再同步最新main的小范围提交。稳定版同时更新updater、三个README的当前发行字段和说明链接，保留历史段落、并发编辑与源码gitlink，拒绝版本/code回退；updater已更新时也修复遗漏README。预发布只同步发行说明。正式写入使用主仓库GITHUB_TOKEN，源码构建与Android任务只读。
