# ChatGPT 语音排障

## 本次修复的范围

OpenAI 的[网络建议](https://help.openai.com/en/articles/9247338)列出 UDP 3478
以及 UDP 不可用时的 TCP 443 回退。这两条规则共同引用 `sukka-chatgpt-voice`，
TCP 规则紧邻 UDP 规则，均指向 `ai-chatgpt`，配置不再内嵌业务 IP 清单。
不会代理所有 443 连接，也不会将 UDP 443 或 TCP 3478 当作这条语音规则。
构建从 [SukkaLab 的规则集](https://github.com/SukkaLab/ruleset.skk.moe/blob/master/sing-box/ip/ai.json)
获取数据；[生成源码](https://github.com/SukkaW/Surge/blob/master/Build/build-ai-cidr.ts)
从 OpenAI 官方清单更新。下载按不可变提交读取，校验后原子替换本地规则文件。
下载失败、非法地址或空集合使构建失败，保留上次规则文件。

这是构建时更新，规则随安装包分发，启动不依赖 GitHub 可达性。
普通订阅刷新不会更新该文件；安装新构建获取新的上游规则。
Telegram IP 分流复用已有的 `lyc-geoip-telegram` 规则集。
内网及保留地址规则仍保留。不要覆盖自定义规则来排障。

内核的连接链按连接协议读取 URLTest 选择，避免将 UDP 节点显示成 TCP 节点。
该记录仍是路由时的选择快照；发生并发切组时不能用它证明最终发包路径。
HTTP 延迟测试只证明该次请求收到了响应，403/503 也可能有延迟值；不代表语音可用。

## 可比较的复现

保持网络、TUN 模式、DNS 和 MTU 不变，记录原有设置。规则模式下检查 ChatGPT
没有显式直连或绕过配置，将 `proxy` 和 `ai-chatgpt` 手动固定到同一个具体节点，
避开自动组和链式代理，重新建立语音会话。对照结束后恢复原设置。
应用“代理”会优先使用普通 `proxy`；应用“直连”会优先使用 `direct`。
模板的 ChatGPT 包名规则早于全局模式规则，切换全局模式不能单独排除分流影响。

失败发生时可以在本机读取：

```sh
su -c '/data/adb/modules/MagicNet/cli api conns'
su -c '/data/adb/modules/MagicNet/cli service logs sing-box 160'
```

活动连接快照会漏掉已经关闭的短连接；默认 error 日志也不会记录完整的成功路径。
记录尝试时间、协议、命中规则和回退结果；分享前去除源 IP、节点名和无关访问目标。
只给出错误条数、HTTP 延迟或一次 UDP 超时，均不足以确认故障原因。
此修复不包含真机语音验收，不能据此关闭 #173。
