# [MagicNet](https://github.com/KernelSU-Modules-Repo/MagicNet) < - 稳定版本/模块
# [MagicMihomo](https://github.com/LIghtJUNction/MagicMihomo) < - 通用/配置

![image](https://github.com/user-attachments/assets/f46c5c92-27df-4edd-851d-cae77ebd8540)

主要功能是在安卓设备,以tun模式运行mihomo/sing-box内核
> 需要root权限
A module that's as streamlined as possible, and easy for everyone to understand.
# 当前状态

> 不稳定！
kamfw框架改造升级中...
可能得等到明年了

## 为什么使用本模块
- 你不需要花哨的UI，因为你不会盯着看吧，你需要的是一个透明的，难以检测的代理服务。而且你要花哨的UI,本模块也提供默认WEBUI和yacd两种选择
- 你需要开箱即用，内置5个自动更新的[免费代理](https://github.com/Barabama/FreeNodes)+3个自己填的付费订阅链接:觉得免费不安全请自行删除，更新模块时候会询问你是否覆盖配置（需要重新配置，默认跳过，然后你手动更新配置文件）
- 大量规则集，自动更新
- 社区联ban规则集，保护隐私
- 同时支持2个内核（mihomo+singbox），按需构建模块, 使用kam build，修改环境变量控制构建流程，请耐心等待，目前最新release版本并不支持。

# 推荐项目
- [yumebox](https://github.com/YumeLira/YumeBox)
[新一代代理协议reality节点部署工具](https://github.com/LIghtJUNction/Mimic-Node)


## 特点 ✨

- **安卓设备使用 tun 模式**
  Use tun mode on Android devices.
- **无 DNS 泄露**
  No DNS leaks.
- **多规则集内置，使用简单**
  Multiple rule sets built-in, easy to use.

## 安装

- 如果你已经通过cargo 安装了kam（>0.5.17）
```bash
kam install LIghtJUNction/MagicNet
```
- 如果你没有安装kam(Termux)

```bash
git clone https://github.com/LIghtJUNction/MagicNet.git && cd MagicNet && git submodule update --init --recursive
chmod +x kam.sh
./kam.sh
```
> 以上方法安装的均为git版本 非 release版本

- 或者直接下载release发布的版本

已经上传至ksu-repo

> kam -S MagicNet # 仅下载

- 安装

> kam install MagicNet.zip

[构建细节](docs/build.md)

## 使用 🛠️

- 填入订阅链接即可开始使用
> /data/adb/modules/MagicNet/.config/mihomo/config.yaml


## 必读

1. 短暂关闭
请在webui界面：配置-关闭tun转发
2. 关闭
运行action.sh或者
pkill -f mihomo
3. 启动
运行action.sh或者直接在终端执行mihomo即可
无需指定配置路径
4. 通过热点共享普通网络
关闭tun转发即可
5. 通过热点共享魔法网络
开启tun转发，开启允许局域网连接
其他在设置设置代理为：你的手机局域网IP:端口

比如要代理http流量，linux执行以下命令：
export http_proxy="局域网IP:7890"
6. 与其他VPN服务共存问题
这里有一些博客，可供参考：

https://blog.openyq.top/posts/26027/

https://blog.ichr.me/post/tailscale-mihomo-quantumult-x/


## 贡献指南 🤝

> **Do one thing && Do it well.** Enjoy! 😎

## 复刻指南 

项目采用kam构建工具，直接运行工作流即可构建
如果需要签名，请在仓库设置中配置KAM_PRIVATE_KEY,内容是kernelsu开发者私钥

## 许可证 📄

This project is licensed under the GNU General Public License v3.0. See the [LICENSE](MyModule/LICENSE) file for details.
此项目采用 GNU General Public License v3.0 许可证。详情请参见 [LICENSE](MyModule/LICENSE) 文件。

## 联系 📬

For further information or queries, you can reach out to [LIghtJUNction](https://github.com/LIghtJUNction).
如需更多信息或有任何疑问，请联系 [LIghtJUNction](https://github.com/LIghtJUNction)。

## 变更 📝

The changelog for this project is available in the [CHANGELOG.md](CHANGELOG.md) file.
此项目的更新日志可在 [CHANGELOG.md](CHANGELOG.md) 文件中查看。

## 引用的项目 
- [Loyalsoldier
clash-rules](https://github.com/Loyalsoldier/clash-rules)

- [Barabama/FreeNodes](https://github.com/Barabama/FreeNodes)

- [DustinWin/ruleset_geodata](https://github.com/DustinWin/ruleset_geodata)
