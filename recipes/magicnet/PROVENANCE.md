# 来源、证据与未验证项

## 2026-10-30 / 配方 0.3.3：最终内核与消费固定点

最终采用 [sing-box `ff669d45e6562a790a49ef066340dbed5df46363`](https://github.com/LIghtJUNction/sing-box/commit/ff669d45e6562a790a49ef066340dbed5df46363)，tree `b5e4c5a7559369fa8f46842b0a0fc45c5aa1ca13`，包含上游 testing `e5d91fa79f6319d5de940d6c81d81f0fe53b9476`。fork 主线从 `ef1ac197876a45aee818ee608b15740c10b8fa3b` 继续合并，保留真实 merge 父提交与 fork 功能；消费仓原固定点则是 `871b7a3440cd9c850f1b09ef3b4ada9babb4384b`，两者角色不同。旧消费基础版本为 `1.15.0-alpha.10`，而其 `git describe` 为 `v1.14.2-386-g871b7a34`；保留这一历史差异，以完整提交和产物元数据确认身份。上游完整差异、WireGuard 复制源码来源及最小修复依据见[内核报告](https://github.com/LIghtJUNction/sing-box/blob/ff669d45e6562a790a49ef066340dbed5df46363/SPECS/TASKS/051-UPSTREAM_MERGE_235/IMPLEMENTATION_REPORT.md)。

当前 Android 实现为 [`396d71df3bd98316324e3533e2d2106e7392250e`](https://github.com/LIghtJUNction/magicnet-android/commit/396d71df3bd98316324e3533e2d2106e7392250e)，tree `3c758dfbe38c482d909bb96160ec64bafdea7da5`，父提交为 `0952cb01b001e41e1074c2e5f4a731a4ad42b222`。仅更新 sing-box gitlink、sing-box.version 为 `1.15.0-alpha.13` 和验收材料；原五个其他嵌套 gitlink、订阅修复、生命周期和最新 UI 保留。主仓库 `generated/magicnet-android` 固定该公开提交；配置仓库 MagicSingBox 仍为 `e4ecf47499c35bf25e10d04257a21a4f7975ebad`。

源码测试对象 `9caf2637c42113a40f1302b87ff9525220a0ff54` 与 GitHub canonical `d6316199ef905c8271e58b23dbf52456d2e49dde` 的 tree 同为 `a6b2907483435e507d5090cb5ce00d84899d10f5`。最终内核相对该 tree 只更新 SPECS 报告和文本证据。最终 Linux/Android 二进制从干净 `ff669d45e6562a790a49ef066340dbed5df46363` 重新构建并核对身份，随后用最终 Linux 产物重新运行配置和 loopback DNS 检查，结果与摘要见[消费仓验收](https://github.com/LIghtJUNction/magicnet-android/blob/396d71df3bd98316324e3533e2d2106e7392250e/docs/sing-box-update-2026-10-30.md)及 VERIFICATION.md。

配方先定义 CORE 合同，再实施与测量。普通 merge 保留同期 `MagicNet@48d539315ffd1814d0f394d6d2d83d4365ac629b` 的订阅、恢复和 README 改动；已整合的配方前缀对象为 `81c298443c6264cc0c1afd23fa542611aac1512f`，tree `231df500850dc0d133f1346cb8f9102fc8ce5a42`。根配方为 0.3.3、engine 为 0.2.1，核心验收为 M48；原先 M44–M47 的订阅要求保留。

## 2026-10-30 / 内核同步合同与配方 0.3.3 整合

输入为用户更新 fork sing-box、同步上游、降低内存和规范修复 bug 的要求。配方基线为 `MagicNet@a7a05308aadbbf4d8362780d2773bf963437b1a5`，当时实现为 `magicnet-android@b113f5128549172da6cb1f6e62f0b42d31adb956`，其内核固定 `sing-box@871b7a3440cd9c850f1b09ef3b4ada9babb4384b`。

本轮先定义 engine/CORE_LIFECYCLE.md，目标为 [SagerNet/sing-box testing e5d91fa79f6319d5de940d6c81d81f0fe53b9476](https://github.com/SagerNet/sing-box/commit/e5d91fa79f6319d5de940d6c81d81f0fe53b9476)，保留 1.15 预发布轨道、fork 专属协议和全部生产 tags。内核合同初稿在本地使用根包 0.3.2、engine 0.2.1 与 M44。合并同期主线的订阅配方 0.3.2 后，根包提升为 0.3.3，核心验收顺延为 M48，CORE-A01–A06 保持原名；其他组件合同和历史实测归属保持原版本。合同先行阶段使用上述旧内核 gitlink，最终固定点和实际检查见本文件首节。

## 2026-10-30 / 配方 0.3.2：候选需求整合与主线维护

配方候选 [`8acb763ff50f3626213c94165f4f3e3ae35ef247`](https://github.com/LIghtJUNction/MagicNet/commit/8acb763ff50f3626213c94165f4f3e3ae35ef247) 提供目录晋升、回执重放、完整网络策略基线和 B/C 草稿反例，已通过合并提交 [`25ff00f4d537f1db99d079a3a6ba5de4f7a2adc9`](https://github.com/LIghtJUNction/MagicNet/commit/25ff00f4d537f1db99d079a3a6ba5de4f7a2adc9) 整合到最新主线合同。候选源码 `b22f9f280ddaf729da47078c13838a73e6d89294`、冻结输入和既有验证均作为独立历史证据保留；主线继续基于 `b113f5128549172da6cb1f6e62f0b42d31adb956` 维护，M41–M43、最新 UI 和正式发布合同保留。

本轮新增实际冲突引用、逐源已知计数下界、公共/私密共享只读来源观测，以及根 module.yaml 与引用资源的合同。根 0.3.2、control 0.2.3、runtime 0.1.3 的规格先于源码实施；计数下界不证明完整字段保真，候选测试不证明当前 main 通过。新增验收的实际结果与仍未知项统一记于 VERIFICATION.md。

随后发布的现行源码修复为 [`0952cb01b001e41e1074c2e5f4a731a4ad42b222`](https://github.com/LIghtJUNction/magicnet-android/commit/0952cb01b001e41e1074c2e5f4a731a4ad42b222)，tree `ca1bfbb33779c9fbdf541b3399029269e5f0502d`，父提交为上述 b113f512；主仓库 gitlink 固定此提交。直接证据包括两个旧版失败反例、逐来源与引用的六组回归、共享有界观测的坏输入/零写入/脱敏测试，以及 827 个不同 Rust 测试的最终通过结果。真实转换器和 #426 现场仍未证实，不将数量下界写成完整订阅语义保真。

## 2026-10-30 / 前端留白与边框精修

输入为用户“多点留白、少一点边框”的界面要求，在现有 Vue WebUI 上统一空间、排版、导航与容器层级。实现提交 [`b113f5128549172da6cb1f6e62f0b42d31adb956`](https://github.com/LIghtJUNction/magicnet-android/commit/b113f5128549172da6cb1f6e62f0b42d31adb956)，父提交为 `72b6e8fca99b2bff54e7f59cb4b2b5a28dd111ae`，tree 为 `2e18248622aa946ca88a243915aa5ed015e9ad37`；父提交的服务交接、PID 校验与日志修复完整保留。

整合后重新通过 338 项前端测试、类型检查和生产构建。浏览器预览中的多页面、多尺寸、语言主题、草稿及焦点检查，以及 Android 真机和网络验证范围，见 VERIFICATION.md 本轮记录。

## 2026-10-30 / 配方 0.3.1：生命周期、PID 与日志路径

输入为 MagicNet [#429](https://github.com/LIghtJUNction/MagicNet/issues/429)、[#430](https://github.com/LIghtJUNction/MagicNet/issues/430) 及既有 #426 记录，固定实现基线为 `magicnet-android@a5617d6371fe17494fb4b4a6f655a0c8a0f7461e`。本轮实际修改现有 Rust/shell 实现，提交 [`72b6e8fca99b2bff54e7f59cb4b2b5a28dd111ae`](https://github.com/LIghtJUNction/magicnet-android/commit/72b6e8fca99b2bff54e7f59cb4b2b5a28dd111ae)，tree `1976d9f38b6a2e0520535c7256130ebe1cff114b`。未更换六个嵌套源码依赖，不是从配方独立重写。

直接证据包括：真实 mksh 的整数溢出与生产锁函数复现；真实 Linux 进程组、管道、flock、fd 与控制进程退出实验；旧/新日志函数的输出对照和 allocator 计数。核心网络行为使用受控假进程，不能作为 Android 网络数据面的成功证据。最终门槛、失败夹具修正和未执行项见 VERIFICATION.md；日志基准绑定原始基线与随源码提交的复现工具，见 PERFORMANCE.md。

配方增加 runtime/LIFECYCLE_CONTRACT.md，根包为 0.3.1、control 为 0.2.2、runtime 为 0.1.2，完整闭包仍为八包。当前源码 main 修复不改变已公开 v1.8.1 的标签或安装物，也不证明 #426 的现场因果。历史性能和发行记录保留各自原提交，不移作本轮测量。

## 2026-10-29 / 配方 0.3.0：源码再提取

本节记录首次提取阶段：从配方0.2.1固定提交0a773436c3b21a56931bbfc77b323c42218cf52b继续，实际读取独立源码0dca28dd984d82333707cbf4b222596934b4d847及固定内核871b7a3440cd9c850f1b09ef3b4ada9babb4384b。当时源码与gitlink未修改，也没有发布Android新版本。后续源码修复另见本文件末尾。

MagicNet文件路径相对于固定源码根；以下是本轮读取的关键证据指纹，不是要求重建者复制其内部结构：

| 源码路径 | SHA-256 |
| --- | --- |
| crates/magicnet-cli/src/subscriptions.rs | dc1e81e793225063f55389211755fc5e27bc71ce5b157d97adb0c9dea7ec5900 |
| crates/magicnet-cli/src/webui_payload.rs | dea85238faac5a980770961ca73fbcc3f455afe2f2b488a6331aebea35eb1c4d |
| crates/magicnet-cli/src/machine.rs | ac7caaa540c1fae08e6ff600f1e5b90cbcdc177da3432b6ffaf80a52c0a22600 |
| crates/magicnet-cli/src/machine/subscription.rs | 4848f46dbfc5585fff081dff3e66ef9e9974e7abf2b95dabcda8366b6d3e2c77 |
| crates/magicnet-cli/src/state.rs | 62f55ebece3f29b1d6810c38401ed114d5fa30708f00ba8522e458d5ecaeb99d |
| crates/magicnet-cli/src/mcp_server/rpc.rs | 0b4c574e5a257785a9b77ecf53b9bbcfb3487f0988333be9af8ed2c0d857b4a0 |
| crates/magicnet-cli/src/routing_overlay.rs | 8b9a3287a392c18f24cccb9e1417e05a280944e246c72da51cfdbd6e7bc810da |
| crates/magicnet-cli/src/overrides.rs | d1215e9b839f897a663a443721eddea06f2fe8a9f81159b5e03fd2f914770eb1 |
| src/MagicNet/lib/magicnet/singbox_subscribe/fetch.sh | c1af8da7c889ecc067a90e43dad7cff6fb2efec324c490e33d75ae429d6ac1b9 |
| src/MagicNet/lib/magicnet/singbox_subscribe/common.sh | 3aee9c41a714afee80b498ffb040fc2a29dca56b8106ee4c76e88872a8b97f4e |
| src/MagicNet/lib/magicnet/singbox_subscribe/parse.sh | 4f3186770acbeb0f2fa5e42e6b38ffdc3d58f4a3b9f8f47ab4b2eba33baecaf4 |
| src/MagicNet/lib/magicnet/singbox_subscribe/proxylink.sh | 97c6735201e9567c72e24f610f5f15a73625e30fba36a0801190547d934b91a5 |
| src/MagicNet/lib/magicnet/singbox_subscribe/config.sh | fe5602e3246997f0d961f2eda721324c14818c30c30976b01318bb90624d386b |
| src/MagicNet/lib/magicnet/singbox_subscribe/update.sh | a7d614802acc19498b4223e40b49f375b01ec8a2de5f9d19a4b9b4821fd7c5d3 |
| webui/src/components/pages/SubscriptionsPage.vue | 13a45f91663ea480212f36451d6c91b840d7645ad26cd6aaf2c00c30e8079e1a |
| webui/src/components/pages/subscriptionPreview.ts | 612e4df74b76518fc7668c7341db2cf6221d3061b5b0934c199d7eea782c9bb0 |
| webui/src/composables/subscriptionUsage.ts | 94be3bbee8b16a9049ed5cabd313f1799ce622e43d510fbfc0c7d970533bf020 |
| webui/src/composables/backgroundTasks.ts | 3bd4486ced42aece003e59bc131abc5c0d37a648f4b89912f3265956d10d5f22 |
| webui/src/composables/machineStatus.ts | 4a0879d696e0827cee06382e6006bd2a45d9edb0cecb59d6623e11ea0af1d100 |
| webui/src/components/pages/RoutingEditor.vue | dc7ad4bf8b37c4a4008363819da0c7dc4ea9be10a27444fdf677da8c4e5a5cfd |
| scripts/package-components.py | 5bcdceaeaa8ec5ece4e5412c532272ad7575afee56bab9989d99077d8437533e |

固定sing-box客户端Encryption证据经GitHub读取并校对Git blob身份，本地保存字节的SHA-256如下：

| fork路径 | SHA-256 |
| --- | --- |
| option/vless.go | d3af3ef892d0b178d2d577b8378d7c78d6c0ff2ac353d5f722eba31ed50fc517 |
| protocol/vless/lx_encryption.go | 65830c1dfb57e34d6dd76e26b2052c2df99225f31f210021fd3f0da41fdb6765 |
| protocol/vless/outbound.go | e2d345e830c237f5059673e2588e0392ce5c9e567336b1eb46d9fc919b2d79f6 |
| protocol/vless/encryption/client.go | 0329a8c3bbe8220b6b615ee28a6326ac37f8012c35ba9d476336e4c05e8c1538 |
| protocol/vless/encryption/common.go | 2734a8e34ba265a95a28a4bbfcf26ba224b1c6f7b5dd137afe8db07280ad063d |

首次提取时新要求的地位：统一URL身份、同名不同节点保留、subscription_batch_v1、UI计数修正与Encryption管理链路保真是重建目标；当时的基线源码尚未修复。后续有限源码改动单独列在本文件末尾。#426现场因果仍未知。旧产品性能、构建、浏览器、MCP等历史结果继续绑定各自原提交，不移动到0.3.0新实现名下。

提取方法使用software2prompt@4920378377332c0ca9779ede6062029fb15dacdb与本项目固定software-to-prompt技能；Recipkg CLI来源与标准库检索决策均记录在SOURCE_AUDIT.md。没有更新共享技能gitlink或引入新的源码型配方依赖。


主来源：LIghtJUNction/MagicNet，https://github.com/LIghtJUNction/MagicNet ，完整提交 96993ea5c851b8d51cc562c3ca0766a2ca571210，module.prop v1.7.2。迁移前 main 与 origin/main 一致，工作区干净；保留全部 stash、其他分支与其他 worktree。
迁移阶段只抽取需求/接口/可观察语义，没有独立重建实现。原临时参考目录 generated/android-reference/ 已按用户要求移入系统回收站；Git 历史保留固定来源，不成为 Recipkg 依赖。

## 证据等级

- 直接运行：当前源码 release CLI 编译；空模块3种成功机器读的重复测量、unsupported machine write 的结构化拒绝；生产 WebUI 构建与真实浏览器预览/重复可见性测量；真机 root/metadata/失败机器接口观察。结果/限制见 PERFORMANCE.md。
- 静态提炼：命令登记的公开 argv、machine capabilities 实际结果、MCP 名称目录、文件状态/事务与安全文档、前端页面/locale/style 定义、默认模板和规则标签、锁定构建输入。
- 测试材料：发现原项目 host/Android/Playwright regression 入口，阅读相关文档和部分用例；没有把测试名称当作实测通过，也没有重跑完整原产品套件。
- 推断：在非独占宿主上 helper 启动/等待影响状态响应；必须保留测量边界，不推广成设备性能结论。
- 未知：全产品最低 Android/WebView、其他 OEM 内核与 root 管理器、完整网络/多协议/热点/外部VPN/Tailscale业务验收、重建新设计、稳定性能预算。未覆盖的深层第三方协议规范依赖其合规外部实现/规范，不冒充随包提供。

## 原始文件指纹

以下路径相对来源提交的旧源码根；迁移后它们不再是配方包必需的本地文件。指纹固定观察对象，不要求未来实现复制结构或代码。

| 来源路径 | SHA-256 |
| --- | --- |
| AGENTS.md | 4bdc9f58d2147d34eff765d015d473d9a21859b593d7354182457435e4b69676 |
| ARCHITECTURE.md | 8d563661fe35ebf0e46933db36a65f6c15d6d62869542ffe771ebd14cff386f9 |
| README.md | 467e99e074ed9749777657287902a0832082d7d9f78ca6e7f58c54153f3489c8 |
| Cargo.toml | bb1f248f8897e5907484bf517f0c90f339906d5d31090e0f125c38fb92facfac |
| crates/magicnet-cli/src/commands.rs | 4aa4e8088ca083c5680a86b09230631784c856bc3f60d844d960757181ba08f1 |
| crates/magicnet-cli/src/machine.rs | 9f1310e26fd6288a85e815a59d31fe083e02d3ddfd9f70fb52246d7db2d9b060 |
| crates/magicnet-cli/src/mcp.rs | aaee6486375fde46cc8f55987fffb4aed63442eb9e9b0f20f6534a250ac202ca |
| docs/state-plane.md | 2ad902f716f5270b7e51ea28ae21873963041d6e4673aa67ca85a96bd875d1ba |
| docs/machine-interface.md | 2c81e6e5414d663f5886bfbad138daa034cf61beed8a5d379019bfad9199a64c |
| docs/user-guide.md | 9d28ce2bd4e25a83b540bf0ae0004288bbee9fa716d536c947ff2d78b7ec9080 |
| docs/config-overrides.md | 25fe3538249778f7dcb9b89152afd0c2e3a0a94918ff187e148a4f4c2a4afb23 |
| docs/module-update.md | 878cf4f3c931f4d3aaa7ca382a9e0c3fd1a83bef52d89dc27b664b6e016b1de2 |
| docs/component-packaging.md | 44cfcbd705d3735e3c04914ddf07704cdfe81637ff1da3ba40e55a0ec2809f07 |
| docs/runtime-resource-bounds.md | 6f8568f1ba1355a0a59661cc6674c019e6651152644bc6b969a720e6b9532be8 |
| docs/build.md | 93c095ddfec15a82835aea6bef0499b7390c98f8f896289ddc5fdc7cafd03438 |
| docs/local-simulation.md | dc30c3f649043c41e292c2b8dff6743c376a85c391f75660fd31b864a18f6d2b |
| docs/mcp-control-plane.md | ff6e3602dae02f70da97cb51c8884ddd02e6f6f9561920ab4ed5004bbd5cfd0d |
| docs/maintained-routing.md | eb29e6edfe823559ea38fbff0cf5d5ce3fb35a076f0ea58089e2b1e76d69a18f |
| docs/network-access-recovery.md | de4dc3b476f0ccbbfd676e190daf7e185c3a65ea7f59dc7e3562dfa1ebd47c06 |
| docs/tailscale.md | 3a01459d1d5c9e0627fc1801b3b31e4f795989a1b186701f19c7cfe60aeace06 |
| webui/package.json | c3f7e7729575656cbe0838457056bfd4d976e3c9125ecd5decdde98623a7c096 |
| webui/src/App.vue | 09fa1204aa1794cd3e2c7ecd5e91c4f3aa8145ebe2d6f65b73c5d9441dd24bd5 |
| webui/src/styles.css | 57b1757cf9496c3eeeb7f6ab68911b0e2259ce1a06cfafb94f14c1aecc511423 |
| webui/src/i18n/README.md | fbc59a405019c4b466cacdfa8d2c560f8b2b03d9022ddba714fd5c10be209106 |
| webui/e2e/README.md | ab98cccd3a9ac7c7784cfa54b4e050a421fd6ab4f00ba15fc15025c264466923 |
| sing-box.version | 35b28be4ba7795a5e4a0eff87d3d1e4aab9a4b63ec58a13834e1ec9032de8c33 |

## 子模块固定点

| 路径 | revision |
| --- | --- |
| .kam/bases/hooks | 13cff0dc1f30d8d0842e563008c7e2712233243f |
| .kam/bases/workflows | f21050a31c33f0ebcbf429af3056ec43c1b816ef |
| rules | f3335f9420d07b8c50b26488df2a9492da6bbb44 |
| sing-box | 871b7a3440cd9c850f1b09ef3b4ada9babb4384b |
| src/MagicNet/.config/sing-box | e4ecf47499c35bf25e10d04257a21a4f7975ebad |
| src/MagicNet/lib/kamfw | 35b2284c08446f6e22447a63d7c3331619e2e854 |


## 配方与工具来源

复用 software-quality@0.1.0 是来自 https://github.com/recipkg/recipkg 在 c1300de130b297445c92ebefeebe7817d816b491 的有效 Markdown 配方，已完整放入本地依赖，不指向源码仓库冒充配方。
迁移采用该项目工作树中已更新的英文 migrate-to-recipkg 技能；工作树存在其他用户正在进行的结构迁移，未修改、提交或清理它。实际使用 generated/src 中的本地 Recipkg CLI，支持 --lang/search；不是声称这版技能已发布。
recipkg search "android network" 实际候选为空；不代表不存在相关软件，也不证明自写配方完整。

2026-10-28 按用户要求先合并代码 PR #420、#421、#422、#423，再合并 README PR #416，形成完整源码提交 ae4de1ce4d77f1a2a4c8d9656da8101c472fa3a0。上面的文件指纹和 PERFORMANCE.md 仍固定初始观察版本，不挪作新版本基线。本地参考目录的 26 个变更文件已核对无本地修改后同步；新增的节点与代理组入口、名称安全、锁争用和单一迁移清单要求同步进入所属配方。
组合源码在隔离 detached worktree 本地验证：Rust 808 passed / 1 ignored、fmt 与严格 all-target/all-feature Clippy；前端单元测试/类型检查/生产构建；代理组相关浏览器用例 18 passed；安装器 10 项与网络恢复迁移 3 项及配置刷新合同通过；透明模式安全脚本在 Bash 和本地构建的 mksh R59 上通过。初次因未初始化配置/KAM 子模块失败，补齐固定 revision 后通过；不将其记作产品修复，也没有将主机夹具推广为真机验收。
按用户随后授权，18 个产品 Issue 已在需求迁入配方后关闭，实际设备与业务验收仍待执行。没有创建 MagicNet-recipkg 远程；误建的本地目录已移入回收站，配方在 MagicNet 原仓库维护。

## 许可

参见 LICENSE.md。全部原始实现、数据集和工具仍遵循自身许可证；配方的 MIT 不改变 sing-box 的 GPL-3.0-or-later 或其他第三方义务。归档只包含说明与公开接口材料，不含源码、二进制、生成资产、安装脚本或私密文件。

## MCP 公共目录实际观察

隔离宿主夹具的 initialize/tools/list 成功，完整工具参数 Schema 已提炼；未认证请求被拒绝。未执行业务工具，临时服务/secret/夹具已清理。结果：{"tool_count": 84, "initialize_ok": true, "catalog_ok": true, "unauthenticated_rejected": true}。

## v1.8.0 实现迭代

用户随后授权按新配方开发、提交推送并发布。实现从 ae4de1ce 的完整源码继续，开发时位于本地忽略的 generated/magicnet-android/，使用 Rust、Shell、Vue 以保留既有边界；这不是独立从零重建。当时 main 保留配方，源码通过同一仓库的 v1.8.0 标签固定。该临时布局已由下述源码子模块布局取代。

结构化增量分流、私密应用名 inspector、WebUI 视觉与表单改动有对应接口/验收更新；配方版本 0.2.0 与 Android 软件版本 v1.8.0 分开。初次本地构建因 Go 的持久化 GOPROXY=direct 无法取得五个上游旧提交而失败；核对公共代理中的固定版本与 go.sum 后，构建脚本默认使用 https://proxy.golang.org,direct，未更换依赖版本、未关闭摘要校验。构建继续执行真实内核和包检查，结果见 VERIFICATION。

本轮实现源码固定为 f13ca61b9c3477aee3b1380d71815c84b3a2a6bf（原仓库 v1.8.0 标签）；host release CLI 的 capabilities 已实测，认证 MCP 工具目录为 85 项，未认证与 generic app inspector 请求均被拒绝。

## 2026-10-29 源码子模块布局修正

用户要求按 migrate-to-recipkg 技能执行，保留现有同仓库 recipes/ 布局与主项目 MagicNet。实现复用原干净目录，不复制源码、不改变语言、功能、语种、平台或性能预算；独立源码仓库为 https://github.com/LIghtJUNction/magicnet-android ，通过 generated/magicnet-android/ 的固定 gitlink 公开。

源码提交为 0dca28dd984d82333707cbf4b222596934b4d847，完整 tree 为 bcb709f66bc2eb6a19021bd2f969f7cf2fa2198a，与原 v1.8.0 提交 f13ca61b9c3477aee3b1380d71815c84b3a2a6bf 完全相同，包括六个嵌套子模块。新仓库从当前干净快照开始，不重发原历史中已删除的本地工具数据库。原历史与发布标签保留在 MagicNet；本地 legacy/magicnet-v1.8.0 分支与 upstream 远程保留原来源。

配方根包提升为 0.2.1，修改范围为仓库布局、获取/构建入口、依赖边界和相应验收。已发布的 v1.8.0 与 0.2.0 发布归档保持原样。共享技能复用既有 11 个 canonical 子模块，原自定义技能不替换。材料检查与公开检出结果见 VERIFICATION.md；结构修正不构成重新构建、重新发布 Android 包或真机验收。

## 2026-10-29 订阅源码修复

用户要求继续完善项目后，在独立源码仓库 `main` 提交并推送 `ed01282e8ee4bcfc27ce5f95f37723c34aebf745`（tree `072233c5df4610d3b31f008b70a0b0a01c966bc1`），并将 MagicNet 的 `generated/magicnet-android/` gitlink 更新到该固定提交。改动覆盖订阅节点身份/计数、跨入口 URL 规范化及预检、缺少 metadata 的来源行、VLESS `encryption` 保真和安装恢复调用点。细节与未解决的来源归属、批次观测见 SOURCE_AUDIT.md。

这是源码 `main` 的未发行修复；未创建 Android 包、签名或部署。没有读取/复制根 `.env`，没有设备操作。实际本地检查和未执行项列在 VERIFICATION.md；#426 的现场原因仍未知。
