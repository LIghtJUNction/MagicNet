# 来源、证据与未验证项

主来源：LIghtJUNction/MagicNet，https://github.com/LIghtJUNction/MagicNet ，完整提交 96993ea5c851b8d51cc562c3ca0766a2ca571210，module.prop v1.7.2。迁移前 main 与 origin/main 一致，工作区干净；保留全部 stash、其他分支与其他 worktree。
本轮只抽取需求/接口/可观察语义，没有独立重建实现。旧源码作为 generated/android-reference/ 的临时参考，Git 历史保留固定来源；不成为 Recipkg 依赖。

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
