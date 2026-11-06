# 跨仓库构建与发布合同

源码维护在 LIghtJUNction/magicnet-android，正式发行与更新入口保留在 LIghtJUNction/MagicNet。源码仓库 CI、Actions artifact 和正式 Release 是不同交付状态。

## 输入与身份

- 主仓库 `.github/workflows/release.yml` 只接受手动请求，默认 `mode=build`；`mode=publish` 才请求正式发行。普通 push 不启动重型打包或发布。
- 软件版本来自固定源码的模块 metadata，不使用 Recipkg 配方版本。kam、module.prop、源码与主仓库 update.json 必须一致；更新 URL 固定为官方仓库本次版本的 magicnet_installer.zip。构建前校验 KAM 的 changelog URL 与 update.json 一致，changelog_file 指向同版本的现存源码发布说明；禁止等构建完成后才发现导出 metadata 漂移。
- 源码只能取本次主仓库提交的 mode-160000 gitlink，不跟随源码 main 的浮动 tip。工作流代码引用固定完整提交；构建与 Android 验收均显式检出并核对同一实现 SHA。
- 机器可读 build-source.json 使用 schema=1，包含 repository、source_repository、recipe_sha、source_sha、version、version_code。version_code 是十进制字符串；两个 SHA 均是完整提交。build-submodules.txt 记录完整初始化且未偏离 gitlink 的依赖快照。

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

构建和 Android 验收只有读取权限；只在主仓库 main 的显式 publish 请求中，独立发布 job 获得 contents:write。源码仓库不得创建官方软件 Release 或带发行请求的版本 PR。

正式发行必须同时通过：配方 check/pack/归档检查/完整提示词、发布边界回归、模块构建、安装/升级与组件测试、完整质量门槛、同一源码提交的 Android/KernelSU 模拟器验收、子模块快照复核，以及最终资产校验。模拟器覆盖不可代替 Android arm64 真机与真实网络验收，结果分别记录。任何必需 job 失败、取消或跳过都不公开 Release。

发布前再次核对两个提交、版本、官方更新地址、组件与内嵌 manifest、组件大小与摘要、三个核心别名的字节身份，以及完整资产清单。SHA256SUMS 不得包含路径穿越、重复项或自身摘要；不接受未列入清单的额外附件。既有版本标签不得覆盖；软件版本及 versionCode 必须大于上一稳定发行。

## 发布与失败

标签指向主仓库提交；实现 SHA 由 provenance 和 gitlink 固定。先创建草稿并上传全部附件，再核对服务端附件清单、大小和 SHA-256，全部成功才公开。失败保留草稿，不能把半套附件作为正式发行。已有标签/草稿的重跑必须拒绝替换，维护者检查后单独处理恢复，不自动删除旧版本。

草稿可在标签查询中返回 404；通过 Release 列表定位唯一同版本草稿，并以数字 release ID 读回、校验和公开。不能将 404 当作无草稿后重复创建，也不能在 ID 歧义或任一服务端资产不符时公开。

独立恢复只适用于原 run 的构建、完整质量和 Android 门槛均成功，而发布控制失败的既有草稿。必须验证原官方 main 运行、固定的配方/源码提交、未过期且摘要固定的 artifact，再对原草稿执行同等完整资产校验；只公开该 ID，不创建版本、不换附件、不重写标签。构建或验收失败、取消、跳过仍然禁止恢复发布。原失败与独立恢复的结果分别记录，不能改写成原工作流全绿。

校验和与 GitHub 资产摘要不是独立公钥签名。任何签名能力与真实设备验收都须另记实际证据，不能由工作流文件存在推断。

## 失败诊断的来源

Android TLS 控制或核心/API/TUN 就绪等待失败仍保存固定 source、run/attempt 与产物摘要，以及 BUILD_PROMPT 规定的有界脱敏诊断；就绪等待失败复用现有支持包，采集失败不得覆盖原失败。保留失败记录，修订后的新提交使用新 run 验证；不同源码或重新构建的二进制按各自身份记录。不得关闭证书/主机名验证、删除负例、把未知就绪状态写为成功或反复重跑来替代缺陷定位；受控反例证明某条夹具边界有缺陷，不等于已确定旧失败的唯一原因。
