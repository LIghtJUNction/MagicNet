# 常见网站联网测试

## 测试边界

`website_probe.sh` 使用真实 HTTPS GET，内置 25 个低流量检查目标，涵盖国内网站、Google/Play/登录入口、GitHub/npm、YouTube、Telegram/Discord、ChatGPT/Claude 等。多数目标使用 robots.txt，因此通过只说明相应 HTTP 入口可达，不能代替完整网页、账号登录、视频播放、APK 下载或语音通话验收。

**CI 绿灯不等于手机可用。** `scripts/test-website-probe.py` 在本机环回地址搭建 HTTPS 和 SOCKS5 服务，验证实际 curl 的证书校验、远端 DNS 委托、跳转、超时、并发、取消清理与错误判定；部分错误使用固定夹具。它不使用公网、订阅或真实节点，也不模拟 Android 内核。测试已接入 `test-host.sh`，同时被 Code Quality 和发布前的 `quality-gate.sh shell` 执行。

## 在手机上检查

先读取运行状态，不自动修改 DNS、订阅、分流或防火墙：

```sh
su -c '/data/adb/modules/MagicNet/cli health'
su -c '/data/adb/modules/MagicNet/cli transparent status'
su -c '/data/adb/modules/MagicNet/cli network status'
su -c 'sh /data/adb/modules/MagicNet/lib/magicnet/website_probe.sh --path mixed --jobs 4 --repeat 3'
```

`mixed` 使用配置模板的 `127.0.0.1:7892` SOCKS5h 入口，域名交给 sing-box 解析，实际经过它的规则和节点。自定义监听端口时使用 `--proxy-port`。该结果证明的仍只是代理入口上的 HTTP 请求，**不证明 TUN/eBPF 已接管 App**，也不单独证明每条请求选择了预期分组。

`native` 不设置应用层代理，使用执行进程的 UID 和网络策略。默认 TUN 配置排除了 UID 0，因此 root 的 native 成功不能当成普通 App 成功。需要在非 root 的 Termux 会话使用可读的脚本和目录清单副本，并结合运行配置/抓包核对该 UID 确实被接管、未被加入绕过列表：

```sh
# 在保存有两个文件的可读目录中，以 Termux 普通 UID 执行，不能套 su。
sh website_probe.sh --targets website-targets.tsv --path native --family 4 --repeat 3
# 只在当前网络确实支持 IPv6 时单独执行；不支持不应报成已通过。
sh website_probe.sh --targets website-targets.tsv --path native --family 6 --repeat 3
```

脚本需要 curl、awk 和常见 shell 工具；优先使用模块 bin 目录。`MAGICNET_CURL` 可指定 curl 二进制。临时目录使用 `TMPDIR`、已存在的模块 `.state` 或主机 `/tmp`；不写 `/data/local/tmp`。缺工具直接报错，不跳过后伪报通过。

不能用 SOCKS5h 下的 curl `-4/-6` 证明目标的地址族：它只影响客户端到代理的连接。因此 mixed 模式会拒绝强制地址族选项，避免错误的 IPv6 结论。

## 如何读结果

输出为 TSV，每个目标、每轮都有独立结果，并记录 HTTP 状态、curl 退出码、累计 DNS/TCP/TLS/首字节/总时间、字节数和跳转数。时间均从请求开始累计；mixed 的 `dns_s` 不代表代理内部的 DNS 解析耗时。报告不保存响应正文、cookie、订阅或节点凭据。

`PASS` 要求 curl 成功、精确匹配预期 HTTP 状态，并符合空/非空正文约束。204 检测收到 200 不算通过；200 之后发生超时或正文截断同样失败。403/401 标为 `RESTRICTED`，429 为 `RATE_LIMITED`，404/410 为 `ENDPOINT_CHANGED`，不会伪装成成功，也不直接归咎于 DNS。`DATA_LIMIT` 是流量上限，不等于网络故障。

退出码：0 为本次请求全部通过，1 为存在失败，2 为工具/执行错误，64 为参数或目标清单无效。没有自动重试掩盖抖动；`--repeat 3` 保留三轮结果，任意一轮失败仍返回非零。默认并发 4，最多 8；每个请求默认 12 秒、限速 128 KiB/s、最大响应 2 MiB。只在手动执行时联网，不在后台定时消耗流量。

## 发布前的真机验收

以下项目必须另有设备证据，不能用网站检查或 CI 结果代替：

| 场景 | 必须核对的内容 |
|---|---|
| Wi-Fi、移动网络和二者切换 | 相同站点清单、不同 UID 的访问和正确出口 |
| TUN / 显式启用的 eBPF | 分别核对对应接管状态，不能只检查进程存在 |
| DNS | 系统解析、目标规则分组，以及物理出口的 53/853 泄漏情况 |
| Google Play | 实际登录、应用详情、APK 下载和更新，不能只访问商店网页 |
| 国内应用 | 微信消息/图片、哔哩哔哩播放、登录与支付跳转 |
| ChatGPT/Discord 等 | 实际语音、UDP/STUN/TURN、长连接，HTTP 不覆盖这些协议 |
| 生命周期 | 重启、睡眠唤醒、节点切换、订阅更新、组件更新后复测 |

没有连接真实 Android 设备、可用订阅和对应网络时，应记录“未验证”，不得出具“常见网站全部正常”或“所有 App 已修好”的结论。

## 本地回归

```sh
python3 scripts/test-website-probe.py
MAGICNET_TEST_SHELL=bash python3 scripts/test-website-probe.py
```

缺 curl 或 openssl 会失败而不是静默跳过。整个测试只连接本机服务，不受公网网站波动影响。
