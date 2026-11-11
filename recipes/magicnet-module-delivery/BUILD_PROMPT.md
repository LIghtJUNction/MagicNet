# 安装、组件与安全更新

交付 Magisk/KernelSU/APatch 可安装的 MagicNet Android arm64 模块。根名保持 MagicNet，安装位置 /data/adb/modules/MagicNet。参考版依赖 KAM/KamHooks/KamModuleX 和 kamfw；实现可替换构建语言，模块入口、生命周期和恢复兼容必须保留。

发布前必须核对 KAM changelog URL、同版本源码 changelog_file 与 update.json 一致，旧版本路径或缺失说明应在构建前失败，不能靠构建后覆盖字段掩盖漂移。

## 模块布局与安装

bin/ 保存运行程序，cli -> bin/magicnet-cli 是兼容入口；默认完整包包含 sing-box、受控默认配置、真实规则及受管bin/curl。curl由固定源码构建，连同TLS/压缩支持、嵌入CA、许可和构建证明进入正常组件链；不依赖设备恰有系统curl。生产ARM64与AVD x86_64共用构建器，分别核对ABI和实际运行证据。service.sh/boot-completed.sh 进入真实生命周期；不加无作用 post-fs-data.sh/uninstall.sh 占位。卸载有真实清理时调用受控框架钩子。
安装引导和卸载告别页共用 `kamfw` 的浏览器启动器。现行 Shell 实现直接维护 `MemDeco-WG/kamfw` 的 `launcher.sh`，由固定子模块 `lib/kamfw/` 提供；移除 `lib/kamfw-web/`。安装入口通过 `import launcher` 调用，卸载临时会话从同一文件复制，依赖初始化、构建和测试均覆盖此来源。启动接口及失败语义见 [RELEASE_CONTRACT.md](RELEASE_CONTRACT.md)。
首次/升级先校验组件，再迁移配置/权限/订阅引导；用户配置和有效订阅保留，不能先卸载再“升级”。历史缓存清理是有界一次迁移，不做开机全盘扫描。
备份与恢复由同一迁移清单派生，新增状态路径不需要维护两份列表。旧完整 config 只作节点恢复及私密回滚材料，活动配置由新模板重建并独立验证；此类备份专用项必须显式声明。复制/权限/恢复错误非零退出并保留恢复证据，不得静默成功。
安装验收必须实际把 staging 目录晋升到最终模块目录，再重新解析受控路径。晋升后自有缓存、checkpoint、last-known-good 与恢复 journal 仍可读取；不能留下指向已消失 staging 的绝对路径。仅重定位可证明属于模块的路径，用户显式配置的外部自定义路径保持原意图，不按字符串前缀盲目改写。
核心/完整包、组件、manifest、摘要在最终字节确定后生成。保留：
MagicNet-core.zip、兼容 MagicNet.zip 与 magicnet_installer.zip、MagicNet-full.zip、MagicNet-component-<id>-<sha256>.zip、components.json、package-sizes.json、SHA256SUMS。组件 ZIP 不是独立 root 模块。
MagicNet-core.zip、MagicNet.zip、magicnet_installer.zip 是完全相同核心包字节的三个发布名，SHA-256 相同，模块 ID 均为 MagicNet。管理器先于安装脚本选择 ID，不能创建另一个 magicnet_installer 模块再嵌套安装，也不能借别名重复下载核心包。
components.json 固定架构、实际路径、模式、大小和 SHA-256。组件 identity 由规范化内容决定，版本号/时间戳/顺序不迫使不变 sing-box 重新下载。不可用随机“最新”资产替代锁定输入。

## 模块包内容边界

测试保留在源码仓库供开发和 CI 使用；构建时递归排除模块及各依赖内的测试目录。最终核心包、两个核心别名、完整包和每个组件 ZIP 均不得含有 `test/`、`tests/`、`__tests__/`、`fixture/`、`fixtures/`、`__fixtures__/`、`__snapshots__/`、`bench/`、`benches/`、`benchmark/`、`benchmarks/`、`coverage/`、`htmlcov/` 或 `node_modules/`。同时继续排除 Git 元数据和开发缓存。

按完整目录段判断，包括空目录与任意深度的嵌套目录；不要按文件名包含 test、文件后缀或所有隐藏路径删除。`bin/test`、`.config/sing-box/rules/test.srs`、`lib/kamfw/test-support.sh`、运行配置、依赖运行代码与许可证必须保留原始字节。

先清理原始 KAM ZIP，再校验并拆分组件，最后生成 manifest 和最终摘要。清理失败应中止；重复清理保持字节不变。组件打包器拒绝绕过清理的开发目录，发布验证器逐个检查所有最终 ZIP，不能只检查完整包。以真实 ZIP 转换和归档内容检查验证边界，不依赖排除配置文本存在；完整门禁见 RELEASE_CONTRACT.md 与 ACCEPTANCE.md。

## 组件事务

信任本次模块 ZIP 内的 manifest，不信镜像给的清单。逐项实际校验；复用顺序为当前安装目录→上一版本→full 内载荷→用户明确的只读离线来源→网络。全复用/full 路径零网络。
下载固定本次 Release tag，TLS 与 SHA-256 同时验证；无需代理核心先安装便可公共 DNS bootstrap。GitHub 直连够用则不额外测速，否则有界选择镜像并展示进度。
全部先进入模块私有 .components-install/ 完整校验后替换；普通错误回滚已替换项，中断后先恢复。失败不先删旧文件；只清上一成功清单证明归属的过时组件。临时 .downloads 解压校验后删除，不另建永久 ZIP 缓存，不写 /data/adb/magicnet-components。显式 cache-dir 只读，不清空用户目录。
路径穿越/重复名/头部歧义/链接/不安全模式/数量与总解压大小/模块身份/架构均受校验；唯一允许核心兼容 link 为受校验 CLI 指向。

## WebUI 官方更新

只更新 LIghtJUNction/MagicNet 官方稳定非草稿非预发行；不接受 URL、仓库、执行文件或 shell 参数。schema-1 module-update status/check/install，request-id 8–64 ASCII 字母数字_-，版本 vMAJOR.MINOR.PATCH，install 同时校验 expected installed/latest。
接受到后台执行之间继承已锁 FD，无空窗；并发 busy。同 ID 同意图重放同结果，异意图 conflict；持久 ledger 最近128结果/4096已用ID，过期 ID 不重新执行，耗尽拒绝而非遗忘。ledger 512 KiB；intent、receipt 与 canonical 的多文件事务可恢复。
.config/magicnet/module-update.conf 是意图；.state/machines/module-update.state 是唯一 public 状态。phase idle/checking/available/up_to_date/downloading/verifying/installing/reboot_required/failed，每阶段主动原子发布；crash 不能永远 running。
固定 GitHub API release/asset ID URL，JSON 与 octet-stream Accept 分开；200 与允许主机的302均支持，每跳校验 HTTPS/公网地址/主机/头，禁用不受信 curl 配置/代理/loader 环境。core ZIP 同时匹配 GitHub asset SHA-256 与 SHA256SUMS，但不能称作独立公钥签名。
校验空间、ZIP、module metadata、组件与设备架构，再用固定绝对路径调用真实 manager；不能只靠 ksud 文件存在推断 KernelSU 有内核支持。
有 pending modules_update/MagicNet、update/disable/remove marker 或 recovery_required 时拒绝新 install 及绕过这些阻断的历史成功回执重放；不删外部 pending。命中幂等 ledger 后也必须在同一受控 owner 内先核对当前 marker、pending 及恢复状态，再返回可适用的历史结果；健康状态下同 ID 同意图仍不重复安装。损坏 journal 或另一任务的恢复阻断不能被旧成功绕过，不启动新 worker、不覆盖原 ledger 或恢复证据。
manager exit 0 后还要验证 staged 身份/版本与 update marker，才 reboot_required。保存重启前 effective baseline；不同 boot 后 staged 消失、安装 metadata、manifest 和实际 CLI hash 一致才承认新版本生效。无自动重启。
manager 开始后 partial/interrupted failure 由 manager 拥有，不以删除新出现目录伪装 rollback；保留证据并 recovery_required。

## 本地与发布质量

构建/包检查覆盖运行布局、权限、组件、with_ebpf 元数据、配置 check、敏感资产排除。正式发布在全部本地/官方质量门槛成功、子模块快照一致、最终摘要验证后才公开 Release；上传先草稿，缺资产不得公开。
草稿按服务端 release ID 读回与转为公开；不能依赖尚未公开的标签查询。唯一草稿身份、目标提交及全部服务端资产核对失败时停止。发布控制失败的独立恢复只能复用已通过全部构建/验收的不可变产物，重新核对原草稿，不替换标签或附件。
普通 main push 只执行轻量配方与发布脚本检查；发布工作流、脚本或源码指针 PR 执行完整验收预览。日常改动不自动发布新版本。本配方包自身只含 Markdown；不能把安装脚本/ZIP/二进制塞进文字配方。

实现跨仓库构建与发布时，完整遵守 [RELEASE_CONTRACT.md](RELEASE_CONTRACT.md)：源码 gitlink、发布仓库和标签提交分别明确，默认只构建，正式发布由显式请求及同提交质量/Android 验收共同放行。

## 本包补充材料

- [EXTERNAL_ASSETS.md](EXTERNAL_ASSETS.md)
- [RELEASE_CONTRACT.md](RELEASE_CONTRACT.md)

构建器必须尊重绝对或相对 CARGO_TARGET_DIR，Android Rust 构建使用 --locked。配置检查使用命名的模块路径变量，不覆盖调用者 HOME。正式发布同时固定源码标签、组件摘要、模块版本/单调递增 versionCode 与兼容更新入口。


## 安装清理与突发 UDP 内存（2026-11-03）

更新和安装继续使用唯一、有 ownership 标记的事务目录；失败先恢复再清理，恢复失败保留唯一恢复材料。清理分批遍历，避免文件数量决定瞬时列表内存，不新增时间戳备份。UDP 索引达到 1024 项后，在最后一项释放时丢弃空索引的底层空间；小流量仍复用索引。保留分片锁、共享引用计数和旧连接不能删除新连接的规则。测试覆盖大批连接释放、重建及安装成功/失败/恢复/未知目录保护；记录性能与内存实测，不把微基准当作真机 RSS。接口和运行依赖不变。

## 0.2.3 目录收敛

新装只生成 `.state` 与 `.cache`。升级清单包含旧 `.local/state`、`.tmp` 及私密目录冲突恢复数据，恢复后按固定映射合并；同名差异保留 canonical 目标并私密保存旧值，失败非零且原数据可恢复。成功删除旧空根，不保留别名目录。构建元数据在 .state、下载资产在 .cache/assets，二者不进入发布组件。删除网络卡 SVG；增量/复用 WebUI 构建与升级同样清除旧副本。

## 0.2.7 升级默认文件与验收证据

`.config/magicnet/website-targets.tsv` 是随模块交付的网页探测目标清单。新装和升级在恢复用户配置后，若清单缺失，须从本次受信安装 ZIP 的同名精确条目补入；不能假定 SKIPUNZIP 已解压该文件。已有普通文件逐字节保留，拒绝符号链接或非普通目标，临时解压与发布使用私有权限，失败中止且清理自有暂存文件。核心、完整和安装别名路径遵循同一规则。

订阅历史 `.state/sing-box/subscription-status` 加入唯一迁移清单，恢复后保持私有权限及已记录时间、阶段和结果。本轮不新增 PID、owner 或锁迁移项；已验证当前 `.state/sing-box/subscription-update.lock` 不随该历史恢复。既有旧目录整目录迁移保持，未新增对所有历史布局运行锁的过滤证明。canonical 运行状态仍从当前证据重建。原先没有历史时保持未记录，不补造成功。

Android 验收的临时 TLS 证书仅容忍有限客体时钟落后：notBefore 固定为签发前 300 秒，notAfter 为签发后 86400 秒，不修改系统时间或按观测值任意扩大窗口。可信 CA 成功、错误主机名拒绝、默认信任拒绝三项控制及原有总预算继续执行。失败也将脱敏诊断写入既有 module-curl-controls.json：主机与客体 UTC、实际证书有效期、退出码、固定错误类别、服务端 GET 计数和清理结果。不可读时间为 null/unknown，不记录原始 stderr、URL、请求或私钥。该证书只属于验收夹具，不改变产品信任库。

核心/API/TUN 就绪等待超时时，在失败收尾阶段复用既有 `support export` 的有界脱敏产物，保留 health 的固定原因与路由证据。验证受控路径、文件大小和脱敏合同后才收录；导出或读取失败只记录固定采集状态，不覆盖原阶段错误、不更改就绪条件、不让未知状态通过。失败证据采集不新增公网探测，也不输出原始订阅配置或命令错误正文。

## 0.2.8 拆分仓库的版本与发布

主仓库提供 build/verify/publish、none/patch/minor/major、自定义版本和可选 code；source_ref 显式解析后固定 SHA。源码仓库提供只读可复用构建和 Android 验收，同一版本注入脚本同步所有 metadata。稳定 updater 与开发源码版本分离；正式发行固定主仓库快照，全部门禁通过后上传草稿、核对资产并公开，随后同步稳定索引。预发布只同步说明，不改稳定索引。同 run 重跑复用快照和原 artifact，补齐缺失上传，拒绝替换既有字节、版本标签或更新回退。完整身份、权限和恢复要求见 RELEASE_CONTRACT.md。

模拟器上联故障测试在 wlan0 down/up 后通过 Android Wi-Fi 服务关闭再开启以恢复 supplicant、关联和系统路由，独立延迟恢复 guard 使用相同动作；eth0 只恢复链路。恢复命令成功仅记录动作，最终仍要求该上联实际默认路由、TUN 状态、就绪与同应用 UID TCP 实测通过。报告记录 restore_method，门禁拒绝缺失或与上联不符的方法。
