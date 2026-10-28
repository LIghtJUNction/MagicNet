# 审核过的外部资产

本表是来源版本的输入，不是已打包的配方依赖。升级须审核并固定摘要；本轮未重新下载核验第三方可获取性。

| 组件 | 仓库 | tag | asset | SHA-256 |
| --- | --- | --- | --- | --- |
| yq | mikefarah/yq | v4.53.3 | yq_linux_arm64 | 578648e463a11c1b6db6010cbf41eafed6bee79466fcffa1bb446672cf7945ea |
| jq | jqlang/jq | jq-1.8.2 | jq-linux-arm64 | 8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309 |
| ecapture | gojue/ecapture | v2.5.2 | ecapture-v2.5.2-android-arm64.tar.gz | 3531f47f60a45c02662188fb151fa8bbf9c40e5c245ff293e5a50477b99df2d1 |
| zashboard | Zephyruso/zashboard | v3.16.0 | dist-no-fonts.zip | 1d8c7aca69e6ddead5e4fe6e92ceda23a499105f675d053362f7c9b53a9730f9 |

Go 固定模块可从 https://proxy.golang.org 的不可变版本缓存获取，仍需 go.sum 校验；直接 Git 获取旧 revision 失败不能通过浮动升级或关闭校验绕过。构建脚本的默认 GOPROXY 为 https://proxy.golang.org,direct，可由显式环境配置覆盖。
