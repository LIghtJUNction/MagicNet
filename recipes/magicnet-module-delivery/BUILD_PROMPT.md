# 安装、组件与安全更新

交付 Magisk/KernelSU/APatch 可安装的 MagicNet Android arm64 模块。根名保持 MagicNet，安装位置 /data/adb/modules/MagicNet。参考版依赖 KAM/KamHooks/KamModuleX 和 kamfw；实现可替换构建语言，模块入口、生命周期和恢复兼容必须保留。

## 模块布局与安装

bin/ 保存运行程序，cli -> bin/magicnet-cli 是兼容入口；默认完整包包含 sing-box、受控默认配置和真实规则。service.sh/boot-completed.sh 进入真实生命周期；不加无作用 post-fs-data.sh/uninstall.sh 占位。卸载有真实清理时调用受控框架钩子。
首次/升级先校验组件，再迁移配置/权限/订阅引导；用户配置和有效订阅保留，不能先卸载再“升级”。历史缓存清理是有界一次迁移，不做开机全盘扫描。
备份与恢复由同一迁移清单派生，新增状态路径不需要维护两份列表。旧完整 config 只作节点恢复及私密回滚材料，活动配置由新模板重建并独立验证；此类备份专用项必须显式声明。复制/权限/恢复错误非零退出并保留恢复证据，不得静默成功。
核心/完整包、组件、manifest、摘要在最终字节确定后生成。保留：
MagicNet-core.zip、兼容 MagicNet.zip 与 magicnet_installer.zip、MagicNet-full.zip、MagicNet-component-<id>-<sha256>.zip、components.json、package-sizes.json、SHA256SUMS。组件 ZIP 不是独立 root 模块。
MagicNet-core.zip、MagicNet.zip、magicnet_installer.zip 是完全相同核心包字节的三个发布名，SHA-256 相同，模块 ID 均为 MagicNet。管理器先于安装脚本选择 ID，不能创建另一个 magicnet_installer 模块再嵌套安装，也不能借别名重复下载核心包。
components.json 固定架构、实际路径、模式、大小和 SHA-256。组件 identity 由规范化内容决定，版本号/时间戳/顺序不迫使不变 sing-box 重新下载。不可用随机“最新”资产替代锁定输入。

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
有 pending modules_update/MagicNet、update/disable/remove marker 或 recovery_required 时拒绝新 install及过期成功重放；不删外部 pending。
manager exit 0 后还要验证 staged 身份/版本与 update marker，才 reboot_required。保存重启前 effective baseline；不同 boot 后 staged 消失、安装 metadata、manifest 和实际 CLI hash 一致才承认新版本生效。无自动重启。
manager 开始后 partial/interrupted failure 由 manager 拥有，不以删除新出现目录伪装 rollback；保留证据并 recovery_required。

## 本地与发布质量

构建/包检查覆盖运行布局、权限、组件、with_ebpf 元数据、配置 check、敏感资产排除。正式发布在全部本地/官方质量门槛成功、子模块快照一致、最终摘要验证后才公开 Release；上传先草稿，缺资产不得公开。
日常迁移不触发重型 CI，不发布新版本。本配方包自身只含 Markdown；不能把安装脚本/ZIP/二进制塞进文字配方。

## 本包补充材料

- [EXTERNAL_ASSETS.md](EXTERNAL_ASSETS.md)

构建器必须尊重绝对或相对 CARGO_TARGET_DIR，Android Rust 构建使用 --locked。配置检查使用命名的模块路径变量，不覆盖调用者 HOME。正式发布同时固定源码标签、组件摘要、模块版本/单调递增 versionCode 与兼容更新入口。
