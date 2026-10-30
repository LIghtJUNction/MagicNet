# 跨仓库构建与发布合同

源码维护在 LIghtJUNction/magicnet-android，正式发行与更新入口保留在 LIghtJUNction/MagicNet。源码仓库 CI、Actions artifact 和正式 Release 是不同交付状态。

## 输入与身份

- 主仓库 `.github/workflows/release.yml` 只接受手动请求，默认 `mode=build`；`mode=publish` 才请求正式发行。普通 push 不启动重型打包或发布。
- 软件版本来自固定源码的模块 metadata，不使用 Recipkg 配方版本。kam、module.prop、源码与主仓库 update.json 必须一致；更新 URL 固定为官方仓库本次版本的 magicnet_installer.zip。
- 源码只能取本次主仓库提交的 mode-160000 gitlink，不跟随源码 main 的浮动 tip。工作流代码引用固定完整提交；构建与 Android 验收均显式检出并核对同一实现 SHA。
- 机器可读 build-source.json 使用 schema=1，包含 repository、source_repository、recipe_sha、source_sha、version、version_code。version_code 是十进制字符串；两个 SHA 均是完整提交。build-submodules.txt 记录完整初始化且未偏离 gitlink 的依赖快照。

## 模块目录元数据

主仓库根保留受跟踪的 `module.yaml`，以及其 `description`、`icon` 等字段实际引用的资源。引用必须指向该仓库可解析的安全相对路径和普通文件；迁移成配方仓库、整合分支或更换源码实现时不能丢掉这些入口，也不能仅以源码子模块内存在同名 manifest 视为目录合同满足。

目录 metadata 的模块身份为 `MagicNet`，homepage/support 指向官方 `LIghtJUNction/MagicNet`，架构与真实交付保持一致，release.assetPattern 对应 `MagicNet-full.zip`。构建/目录检查核对 manifest、资源、模块身份和正式发布资产名称，缺失或失效引用给明确失败；发布时再次与完整资产清单核对。配方版本不替代模块软件版本，目录元数据恢复本身不证明安装或设备验收通过。

## 权限与门槛

构建和 Android 验收只有读取权限；只在主仓库 main 的显式 publish 请求中，独立发布 job 获得 contents:write。源码仓库不得创建官方软件 Release 或带发行请求的版本 PR。

正式发行必须同时通过：配方 check/pack/归档检查/完整提示词、发布边界回归、模块构建、安装/升级与组件测试、完整质量门槛、同一源码提交的 Android/KernelSU 模拟器验收、子模块快照复核，以及最终资产校验。模拟器覆盖不可代替 Android arm64 真机与真实网络验收，结果分别记录。任何必需 job 失败、取消或跳过都不公开 Release。

发布前再次核对两个提交、版本、官方更新地址、组件与内嵌 manifest、组件大小与摘要、三个核心别名的字节身份，以及完整资产清单。SHA256SUMS 不得包含路径穿越、重复项或自身摘要；不接受未列入清单的额外附件。既有版本标签不得覆盖；软件版本及 versionCode 必须大于上一稳定发行。

## 发布与失败

标签指向主仓库提交；实现 SHA 由 provenance 和 gitlink 固定。先创建草稿并上传全部附件，再核对服务端附件清单、大小和 SHA-256，全部成功才公开。失败保留草稿，不能把半套附件作为正式发行。已有标签/草稿的重跑必须拒绝替换，维护者检查后单独处理恢复，不自动删除旧版本。

草稿可在标签查询中返回 404；通过 Release 列表定位唯一同版本草稿，并以数字 release ID 读回、校验和公开。不能将 404 当作无草稿后重复创建，也不能在 ID 歧义或任一服务端资产不符时公开。

独立恢复只适用于原 run 的构建、完整质量和 Android 门槛均成功，而发布控制失败的既有草稿。必须验证原官方 main 运行、固定的配方/源码提交、未过期且摘要固定的 artifact，再对原草稿执行同等完整资产校验；只公开该 ID，不创建版本、不换附件、不重写标签。构建或验收失败、取消、跳过仍然禁止恢复发布。原失败与独立恢复的结果分别记录，不能改写成原工作流全绿。

校验和与 GitHub 资产摘要不是独立公钥签名。任何签名能力与真实设备验收都须另记实际证据，不能由工作流文件存在推断。
