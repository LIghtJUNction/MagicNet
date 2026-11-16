# 审核过的外部资产

本表是实现构建的外部输入，不是已打包的Markdown配方依赖。升级须审核并固定摘要；下表记录当前审核过的固定输入，正式curl组件的源码与实测状态另列。

| 组件 | 仓库 | tag | asset | SHA-256 |
| --- | --- | --- | --- | --- |
| yq | mikefarah/yq | v4.54.3 | yq_linux_arm64 | 89f69310b61b68d1245065a1241d1fc843f7a36cd6103ffd77ad987613bd1b67 |
| jq | jqlang/jq | jq-1.8.2 | jq-linux-arm64 | 8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309 |
| ecapture | gojue/ecapture | v2.11.0 | ecapture-v2.11.0-android-arm64.tar.gz | f962faafc0f715ffb016b86ddb841c6844c27bdb4f177b43c3e72d89c260234a |
| zashboard | Zephyruso/zashboard | v3.30.0 | dist-no-fonts.zip | ec794e7c4daf4c839ecbc0a1292fdaf7bc7a6e3e4a4ce284db2b32379145c278 |

[#447](https://github.com/LIghtJUNction/MagicNet/issues/447) 与 [#449](https://github.com/LIghtJUNction/MagicNet/issues/449) 申请内置 zashboard。上表锁定的 `v3.30.0` `dist-no-fonts.zip` 已是审核过的默认 sing-box 本地面板；对同一资产再次申请不适配新产品。更换面板须重新审核并更新本表与源码 `hooks/lib/release_locks.sh`。

## 正式HTTPS执行器输入

delivery 0.2.6要求从同一锁定来源构建Android API21的arm64-v8a生产版与x86_64模拟器版。OpenSSL与zlib静态链接，CA内嵌；最终`bin-curl`组件包含`bin/curl`以及固定`licenses/curl/`下的构建来源和四份许可/通知。源码压缩包、测试、开发目录和独立证书测试副本不进入模块。两种ABI的实际编译与运行结果必须绑定相同源码提交，不能用构建参数代替设备执行证据。

| 输入 | 固定官方来源 | SHA-256 | 随包许可记录 |
| --- | --- | --- | --- |
| curl 8.23.0 | https://github.com/curl/curl/releases/download/curl-8_23_0/curl-8.23.0.tar.xz | 8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5 | curl-COPYING.txt |
| OpenSSL 3.5.9 | https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz | 603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a | OpenSSL-LICENSE.txt |
| zlib 1.4 | https://github.com/madler/zlib/releases/download/v1.4/zlib-1.4.tar.gz | 02dd159783677a749c04adbdd02b55b8a2bcc7e054f51b76b549199a916ad584 | zlib-README.txt |
| Mozilla CA 2026-11-05 | https://curl.se/ca/cacert-2026-11-05.pem | 427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285 | Mozilla-CA-NOTICE.txt |

CA原文件200116字节、118张证书。curl与OpenSSL摘要已与官方GitHub Release资产API核对；构建器必须重新验证四份输入摘要，来源不可获取或摘要不符就失败。原生验收还须从实际curl导出内嵌CA后核对摘要与数量，并用本地证书成功/拒绝对照证明TLS校验生效。当前具体验收状态见根VERIFICATION.md，配方要求本身不代表已通过。

Go 固定模块可从 https://proxy.golang.org 的不可变版本缓存获取，仍需 go.sum 校验；直接 Git 获取旧 revision 失败不能通过浮动升级或关闭校验绕过。构建脚本的默认 GOPROXY 为 https://proxy.golang.org,direct，可由显式环境配置覆盖。
