# 订阅解析边界

远程内容只能提供节点。JSON/YAML、分享链接和单层 Base64 统一进入结构化导入，不能覆盖路由、监听器或引用本机文件。Clash 转换器、分享链接解析器和 SIP003 插件校验分别实现，最终共用节点校验及稳定标识。

分享链接覆盖 SS（SIP002 和旧整串 Base64）、VMess、VLESS、Trojan、Hysteria2、TUIC、AnyTLS。支持的传输包含 TCP、WS、gRPC，以及分享链接的 HTTPUpgrade 和 Clash 的 H2。TLS/Reality、SNI、uTLS、ALPN 和密码转义必须保留。尚未实现 XHTTP、VLESS 加密扩展、SSR 等格式；不能笼统宣称任意格式都支持。

SIP003 只允许内置 obfs-local/v2ray-plugin 和白名单选项。原生 JSON 的 plugin_opts 同样校验，禁止通过 cert 等字符串选项引用本机证书文件。未知安全字段拒绝该节点，不退回裸 TCP；界面显示成功导入数和拒绝数。全部失败不替换已有节点；多 URL 刷新全部解析成功才提交一份事务。

解析通过不代表网络可用。应用前仍须通过实际内核的配置检查，真实服务端兼容性及 Android 应用联网另行验证。宿主机执行证据为 Rust 50 项、CLI/worker/安装/打包 39 项、前端协议 8 项、浏览器集成 12 项；这些计数不替代提交对应的 CI 记录。

字段核对依据：仓库固定 sing-box 的 option/*.go 和 transport/sip003/*.go；另参考 Mihomo 官方 VLESS、Shadowsocks、transport 文档：
https://wiki.metacubex.one/en/config/proxies/vless/
https://wiki.metacubex.one/en/config/proxies/ss/
https://wiki.metacubex.one/en/config/proxies/transport/
