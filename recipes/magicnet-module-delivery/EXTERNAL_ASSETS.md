# 审核过的外部资产

本表是实现构建的外部输入，不是已打包的Markdown配方依赖。升级须审核并固定摘要；下表原有四项保留历史来源，正式curl组件的新增来源与实测状态另列。

| 组件 | 仓库 | tag | asset | SHA-256 |
| --- | --- | --- | --- | --- |
| yq | mikefarah/yq | v4.53.3 | yq_linux_arm64 | 578648e463a11c1b6db6010cbf41eafed6bee79466fcffa1bb446672cf7945ea |
| jq | jqlang/jq | jq-1.8.2 | jq-linux-arm64 | 8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309 |
| ecapture | gojue/ecapture | v2.5.2 | ecapture-v2.5.2-android-arm64.tar.gz | 3531f47f60a45c02662188fb151fa8bbf9c40e5c245ff293e5a50477b99df2d1 |
| zashboard | Zephyruso/zashboard | v3.16.0 | dist-no-fonts.zip | 1d8c7aca69e6ddead5e4fe6e92ceda23a499105f675d053362f7c9b53a9730f9 |

[#447](https://github.com/LIghtJUNction/MagicNet/issues/447) 与 [#449](https://github.com/LIghtJUNction/MagicNet/issues/449) 申请内置 zashboard。上表锁定的 `v3.16.0` `dist-no-fonts.zip` 已是审核过的默认 sing-box 本地面板；对同一资产再次申请不适配新产品。更换面板须重新审核并更新本表与源码 `hooks/lib/release_locks.sh`。

## 正式HTTPS执行器输入

delivery 0.2.6要求从同一锁定来源构建Android API21的arm64-v8a生产版与x86_64模拟器版。OpenSSL与zlib静态链接，CA内嵌；最终`bin-curl`组件包含`bin/curl`以及固定`licenses/curl/`下的构建来源和四份许可/通知。源码压缩包、测试、开发目录和独立证书测试副本不进入模块。两种ABI的实际编译与运行结果必须绑定相同源码提交，不能用构建参数代替设备执行证据。

| 输入 | 固定官方来源 | SHA-256 | 随包许可记录 |
| --- | --- | --- | --- |
| curl 8.22.0 | https://github.com/curl/curl/releases/download/curl-8_22_0/curl-8.22.0.tar.xz | f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7 | curl-COPYING.txt |
| OpenSSL 3.5.8 | https://github.com/openssl/openssl/releases/download/openssl-3.5.8/openssl-3.5.8.tar.gz | a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2 | OpenSSL-LICENSE.txt |
| zlib 1.3.2 | https://zlib.net/fossils/zlib-1.3.2.tar.gz | bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16 | zlib-README.txt |
| Mozilla CA 2026-09-25 | https://curl.se/ca/cacert-2026-09-25.pem | a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505 | Mozilla-CA-NOTICE.txt |

CA原文件188900字节、121张证书。curl与OpenSSL摘要已与官方GitHub Release资产API核对；构建器必须重新验证四份输入摘要，来源不可获取或摘要不符就失败。原生验收还须从实际curl导出内嵌CA后核对摘要与数量，并用本地证书成功/拒绝对照证明TLS校验生效。当前具体验收状态见根VERIFICATION.md，配方要求本身不代表已通过。

Go 固定模块可从 https://proxy.golang.org 的不可变版本缓存获取，仍需 go.sum 校验；直接 Git 获取旧 revision 失败不能通过浮动升级或关闭校验绕过。构建脚本的默认 GOPROXY 为 https://proxy.golang.org,direct，可由显式环境配置覆盖。
