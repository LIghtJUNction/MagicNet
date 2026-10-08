# 分流规则更新（2026-10-08）

## 规则变化

`lmm.best` 及其所有子域名走 `proxy`，包括 `api.lmm.best`、`msg.lmm.best` 和多级子域名。DNS 查询使用通过 `proxy` 连接的 `doh-cloudflare`。此域名例外优先于 Direct/Global 模式、应用分流、广告和国家规则；原有 DNS 劫持、无效地址及 ICMP 拒绝规则保留。未配置代理节点时保持阻断，不回落直连。相似名称不误匹配，也不将整个目标 IP 或 CDN 设为代理。

海外 AI 和指定社交服务规则优先于泛国内分类。宽泛开发、通信分类放在国内规则之后，避免国内镜像和服务仅因类别重叠而走代理。指定开发服务保留专用规则。中文顶级域名改用 DNS 中实际使用的 ASCII 标签。

国内 DNS、节点启动用的直连 DNS、TUN/eBPF 模式和用户自定义配置保持原有职责。本次修改默认模板及其引用，不覆盖用户自己的完整配置或 JSON 覆盖规则。排除在核心之外的应用不受模板控制。

## 固定版本

- 模板：`LIghtJUNction/MagicSingBox@e4ecf47499c35bf25e10d04257a21a4f7975ebad`，见 https://github.com/LIghtJUNction/MagicSingBox/pull/20 。
- 模板 SHA-256：`eeffe5b7540c6a2f92629ba95a2488efcbcde553d9f70035d3e2ae8ecb65edbf`。
- 规则包：`rules-20261007-5b64697852303979`。
- 运行时 manifest SHA-256：`a55f4dfd6f7cb7be801ff251a2e730af44563f2948225f74824edb62b6fbbf6e`。

子模块、安装脚本、命令行、WebUI 和默认配置仓库文件使用同一模板提交及校验值。历史发布说明不改写。

## 验证

初始化子模块后运行：

```sh
git submodule update --init -- rules src/MagicNet/.config/sing-box
python3 scripts/test-routing-template.py -v
python3 -m unittest discover -s src/MagicNet/.config/sing-box/tests -v
python3 scripts/test-bundled-rules.py -v
bash scripts/test-rule-hash-retry.sh
```

主项目增加 4 项集成测试，检查固定版本一致、模板生成一致，以及规则整理前后 LMM 连接/DNS 的优先级。模板包含 22 项测试。规则发布检查不再只检查四个样例，而是下载固定发布包，验证完整 manifest，并校验模板引用的全部二进制规则文件。

已完成的验证记录：https://github.com/LIghtJUNction/MagicNet/actions/runs/37732351754 。

规则冲突测试使用模拟分类；真实规则包检查覆盖文件完整性和引用完整性，不等于真实网络连通性测试。本次未连接或重启 Android 设备，也未发布安装包。现有用户的自定义模板、固定版本及覆盖配置不会被自动重置；使用新默认配置前应确认没有旧的完整路由覆盖。
