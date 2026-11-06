# 跨仓库构建与发布合同

源码维护在 LIghtJUNction/magicnet-android，正式发行与更新入口保留在 LIghtJUNction/MagicNet。源码仓库 CI、Actions artifact 和正式 Release 是不同交付状态。

## 输入与身份

- 主仓库 `.github/workflows/release.yml` 提供手动 `build / verify / publish`，默认 `build`。`verify` 执行完整发布门禁；仅显式 `publish` 可创建发行。工作流、发布脚本和源码指针 PR 执行下一补丁版的完整验收预览，普通 main push 执行轻量配方和发布脚本检查。
- 版本可选择 `none / patch / minor / major`，或指定 `X.Y.Z / vX.Y.Z`；自定义版本与非 none bump 互斥。递增以源码与已公开版本中较新者为基准；改变版本时默认 code 为两者较大 code 加一，也可显式指定合法整数。发行时版本和 code 均须高于已公开版本，包括已经公开的预发布。
- 主仓库 `main/update.json` 表示已发布稳定版，允许落后于源码声明版本。源码 kam、module.prop、update.json 仍须内部一致；发布前统一写入目标版本/code、官方版本化安装器 URL、KAM changelog URL 与同版说明，再执行实际构建验证。
- 默认使用主仓库的 mode-160000 gitlink；可通过 `source_ref` 明确选择源码分支、标签或 SHA，解析后固定完整提交。reusable workflow 代码固定完整 SHA；构建与 Android 验收检出同一源码并调用相同的版本注入脚本。
- `publish` 在主仓库创建 `release/run-<run_id>` 固定快照，其父提交为触发 main 提交，包含所选源码 gitlink、release-plan.json、目标 update.json 和发行说明。重跑同一 run 复用并验证原快照及输入，不移动快照分支。build/verify 不写远端。
- `release-plan.json` schema=1 记录 base_sha、source_sha、目标 version/code、run_id、prerelease 和输入；`build-source.json` schema=1 保留 repository、source_repository、recipe_sha、source_sha、version、version_code。recipe_sha 为发布快照（预览时为触发提交），source_sha 为版本注入前的源码基线，version_code 为十进制字符串。目标版本与固定基线共同定义构建，不能称作未经修改的源码提交。build-submodules.txt 记录完整且未偏离的嵌套依赖快照。

## 模块目录元数据

主仓库根保留受跟踪的 `module.yaml`，以及其 `description`、`icon` 等字段实际引用的资源。引用必须指向该仓库可解析的安全相对路径和普通文件；迁移成配方仓库、整合分支或更换源码实现时不能丢掉这些入口，也不能仅以源码子模块内存在同名 manifest 视为目录合同满足。

目录 metadata 的模块身份为 `MagicNet`，homepage/support 指向官方 `LIghtJUNction/MagicNet`，架构与真实交付保持一致，release.assetPattern 对应 `MagicNet-full.zip`。构建/目录检查核对 manifest、资源、模块身份和正式发布资产名称，缺失或失效引用给明确失败；发布时再次与完整资产清单核对。配方版本不替代模块软件版本，目录元数据恢复本身不证明安装或设备验收通过。

## 启动器接口与来源

现行安装、卸载入口共用固定 `MemDeco-WG/kamfw` 子模块中的 `lib/kamfw/launcher.sh`。安装时使用 `import launcher`；卸载临时会话复制该文件，使模块目录删除后仍能完成已启动的告别流程。源码、发布包和工作流只维护这一启动器来源，移除 `lib/kamfw-web/` 目录及其覆盖加载逻辑。

`launch browser <http(s)-url>` 在 Android 当前用户中打开页面：先查询该用户的浏览器角色，依次尝试指定浏览器、通用 BROWSABLE intent 和 Binder activity 入口。每次系统命令有界等待；ActivityManager 输出错误时继续按失败处理，即使命令退出码为零。保留 `launch url|link`、`launch app|pkg` 和直接 URL 调用；导入无副作用，调用保留失败退出码，不污染调用者变量。

源码子模块提交必须可获取；安装、卸载和浏览器回归工作流初始化同一个固定 `kamfw` 依赖后再执行。单独修改该 gitlink 也须触发对应检查。

## 最终 ZIP 内容门禁

归档清理在组件拆分、内嵌 manifest 与最终摘要生成之前完成。开发目录规则适用于 `MagicNet-core.zip`、`MagicNet.zip`、`magicnet_installer.zip`、`MagicNet-full.zip` 和每个 `MagicNet-component-*.zip`，覆盖模块源码、配置子模块和框架依赖的任意嵌套层级。

禁止的完整目录段为 `test`、`tests`、`__tests__`、`fixture`、`fixtures`、`__fixtures__`、`__snapshots__`、`bench`、`benches`、`benchmark`、`benchmarks`、`coverage`、`htmlcov`、`node_modules`；空目录也必须删除。Git 元数据、开发缓存和本地私密数据继续遵守既有排除规则。源码仓库中的测试不删除；运行文件 `bin/test`、`rules/test.srs` 等同名或近似名称不触发目录排除，运行代码、配置和许可证保持原始内容。

KAM 清理失败、组件打包器发现未清理目录，或发布验证器在任意最终 ZIP 中发现禁用目录时，均以非零结果阻断后续交付。清理后重新打包的核心别名、组件清单与 SHA256SUMS 必须与最终字节一致。归档检查需实际列出 ZIP 成员；清理脚本存在、目录清单正确或完整包单独通过均不能替代所有资产检查。

主机门禁以合成载荷运行实际 KAM 清理钩子与组件打包器，检查核心包、完整包、两个别名和五个组件，共九个 ZIP；同时检查 CRC、88 个条目的目录边界、组件清单和保留文件字节。注入未清理核心包、完整包与组件的反例必须由最终发布验证器拒绝。该门禁验证归档转换与交付内容，安装执行、Android 设备和真实网络的结果分别记录。

## 权限与门槛

构建和 Android 验收只有读取权限。主仓库计划 job 在 main 的显式 publish 请求中使用 contents:write 创建固定快照，独立发布 job 使用同一主仓库令牌上传和公开发行、同步稳定索引；不需要跨仓库 PAT。源码仓库只负责构建和测试，不创建官方软件 Release 或发行请求版本 PR。

正式发行必须同时通过：配方 check/pack/归档检查/完整提示词、发布边界回归、模块构建、安装/升级与组件测试、完整质量门槛、同一源码提交的 Android/KernelSU 模拟器验收、子模块快照复核，以及最终资产校验。模拟器覆盖不可代替 Android arm64 真机与真实网络验收，结果分别记录。任何必需 job 失败、取消或跳过都不公开 Release。

发布前再次核对两个提交、版本、官方更新地址、组件与内嵌 manifest、组件大小与摘要、三个核心别名的字节身份，以及完整资产清单。SHA256SUMS 不得包含路径穿越、重复项或自身摘要；不接受未列入清单的额外附件。既有版本标签不得覆盖；软件版本及 versionCode 必须大于已公开发行基线。

## 发布与失败

标签指向主仓库本次固定发行快照；实现 SHA 由计划、provenance 与快照 gitlink 固定。先创建草稿并上传全部附件，再核对服务端附件清单、大小和 SHA-256，全部成功才公开。任何必需门槛失败、取消或跳过都不公开 Release。

草稿通过 Release 列表定位唯一同版本记录，以数字 release ID 查询、上传和公开，兼容草稿标签查询返回 404。Release 正文记录原 run、不可变 artifact ID 与快照；已有身份不符、歧义、非法 ID、已上传资产不符时拒绝恢复。上传中断后，原 run 的 failed-jobs 重跑保留原 artifact，仅补齐缺失文件。服务端 502 留下的 state=starter 且 size=0 空资产，仅在同身份草稿中按合法数字 asset ID 清理后补传；已 uploaded 内容永不覆盖。

完整重建产生了不同 artifact ID 时，禁止用它覆盖原草稿。已公开发行在同身份、同资产校验通过后视为发布步骤幂等成功；公开资产缺失或变动仍失败。只在确认公开、非预发布、tag 指向正确快照且资产一致后更新 main 的稳定 updater；更新使用最新 main 的小提交，保留用户同时提交的文件和 gitlink，不回退更高版本或 code。预发布只补入发行说明，保留稳定 update.json 与源码指针。

公开成功但 main 同步失败须明确区分“Release 已发布、索引同步失败”；原失败 job 可继续同步，不重新发行。构建或验收失败仍先修复和重新验证，不用上传重试代替质量门槛。历史独立恢复按其真实执行证据记录，当前自动恢复只使用原运行与原 artifact。

校验和与 GitHub 资产摘要不是独立公钥签名。任何签名能力与真实设备验收都须另记实际证据，不能由工作流文件存在推断。

## 失败诊断的来源

Android TLS 控制或核心/API/TUN 就绪等待失败仍保存固定 source、run/attempt 与产物摘要，以及 BUILD_PROMPT 规定的有界脱敏诊断；就绪等待失败复用现有支持包，采集失败不得覆盖原失败。保留失败记录，修订后的新提交使用新 run 验证；不同源码或重新构建的二进制按各自身份记录。不得关闭证书/主机名验证、删除负例、把未知就绪状态写为成功或反复重跑来替代缺陷定位；受控反例证明某条夹具边界有缺陷，不等于已确定旧失败的唯一原因。
