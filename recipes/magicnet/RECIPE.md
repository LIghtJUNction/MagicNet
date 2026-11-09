# MagicNet Android root 透明网络工作台

~~~toml
format = "recipkg/1"

[package]
name = "magicnet"
version = "0.3.20"
kind = "software"
description = "MagicNet Android root 透明网络工作台"
entry = "BUILD_PROMPT.md"

[dependencies.control]
source = "../magicnet-control-plane"

[dependencies.webui]
source = "../magicnet-web-console"

[dependencies.delivery]
source = "../magicnet-module-delivery"

[dependencies.quality]
source = "../software-quality"
~~~

本包描述完整 Android root 网络工作台；行为与 M01–M68 验收分别见 [BUILD_PROMPT.md](BUILD_PROMPT.md) 和 [ACCEPTANCE.md](ACCEPTANCE.md)。四个直接依赖递归组成八包，源码和二进制不进入 Markdown 配方负载。

配方版本与 Android 软件版本独立。当前依赖、源码固定点见 [DEPENDENCIES.md](DEPENDENCIES.md)；已发布安装物以根 `update.json` 为准，实际验证与未完成范围见 [VERIFICATION.md](VERIFICATION.md)。runtime 0.1.10、control 0.2.9、webui 0.2.6 与 delivery 0.2.9 共同定义日常操作恢复、未知状态、TUN 有界恢复和模拟器证据门禁。

初始观察来源为 MagicNet v1.7.2（`96993ea5c851b8d51cc562c3ca0766a2ca571210`）。来源归属和迭代历史保留于 [PROVENANCE.md](PROVENANCE.md)；旧版本说明可查[精简前的固定记录](https://github.com/LIghtJUNction/MagicNet/blob/26c8d0374ce3eecfdf457eee9f3ba14ed744242a/recipes/magicnet/RECIPE.md)。
