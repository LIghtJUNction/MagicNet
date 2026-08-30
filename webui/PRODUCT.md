# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

首要用户是在国内使用 Magisk、KernelSU 或 APatch 安装 MagicNet 的 Android root 设备用户，其中手机用户占多数。他们通常从 root 管理器内打开模块 WebUI，在手机上完成首次配置、日常启停、策略调整和故障排查；桌面浏览器是需要更大信息密度时的自适应使用场景。产品后续计划面向国际用户开放，因此界面结构、术语组织和文本容器不得只适配中文。

## Product Purpose

MagicNet 让用户在一个可观察、可恢复的控制面中管理 Android 设备上的 sing-box 透明数据面：导入并原子启用订阅、显式选择 TUN 或 eBPF、确认 configured/effective 状态、选择节点、配置应用与网络策略，并在异常时获得明确诊断与下一步操作。成功意味着用户能快速判断“当前是否正常、流量将如何走、下一步该做什么”，而不会因界面操作留下半写入配置或误解绕行边界。

## Positioning

MagicNet 使用 root 管理的单一 sing-box 透明数据面接管和分流设备流量：默认 TUN 使用 `magicnet0`，显式 eBPF 使用 local cgroup 和已确认下游接口上的 shared TC。它不调用应用侧 `VpnService.establish()`，因此不占用 Android 系统 VPN slot；WebUI 直接管理模块后端，而不是模拟一个普通 VPN 客户端。

## Operating Context

- 从 Magisk、KernelSU 或 APatch 的模块页面打开 WebUI。
- 首次成功路径是：关闭系统私人 DNS，导入订阅或本地配置，等待校验与原子激活，然后确认 sing-box 与当前透明数据面。TUN 验证 `magicnet0`；eBPF 验证 cgroup/TC 与 pending/rollback 状态。
- 日常路径包括模块启停、节点/代理组选择、应用策略、Wi-Fi 与热点策略、网络参数和链式代理。
- 排障路径以健康检查、透明状态、运行日志、脱敏支持包和 Issue 草稿为核心。
- 手机触控是首要操作环境，也是本轮验收的第一优先级；不能把桌面布局简单压缩成移动版。桌面端在不改变业务语义的前提下提供更高信息密度。

## Capabilities and Constraints

- 保留现有 WebUI 的全部业务功能、后端 API、数据含义和安全边界；允许重组导航、页面和信息层级。
- 当前主线显式支持 sing-box `tun|ebpf`，默认 `tun`。不得增加 `auto`，不得恢复 TProxy、Redirect 或 netd `ALLOW_MULTI` promote 路径。
- 真机状态统一以 `cli transparent status` 与 `cli health` 为准，不假定 `cli ebpf status` 存在；TUN 才以 `magicnet0` 为准，eBPF 必须区分 capability 与实际 cgroup/TC attachment。
- 订阅 URL、本地导入、token、secret、password、完整节点地址和设备标识不得在报告、日志或 Issue 文案中泄露。
- `Proxy`、`Direct` 与 `Bypass` 的区别必须保持准确：Direct 是已截获流量的 sing-box 直连；Bypass 完全离开 MagicNet 当前数据面与 DNS 捕获，不能与 eBPF `bypass_rule_set` 混为一谈。
- URL 保存和本地导入继续共用校验、原子替换与失败回滚语义。
- 本轮以简体中文为默认语言，不把完整英文翻译扩大进首轮重构；但信息架构、组件 API、布局与文案资源应为后续国际化保留明确边界，不能依赖固定中文长度或只在国内成立的视觉隐喻。
- 不新增前端运行依赖，除非用户另行授权。

## Brand Commitments

保留 `MagicNet` 名称与仓库根目录 `icon.png` Logo。现有米白/仙人掌色、玻璃卡片、大圆角、多层阴影、标签式导航和页面构图不再是视觉约束，可以完整替换。产品语气应直接、技术准确、不过度宣传。

## Evidence on Hand

- 产品与首次运行事实：`../README.md`、`../docs/user-guide.md`、`../src/MagicNet/README.md`
- 当前前端功能与交互：`src/App.vue`、`src/components/pages/`、`src/services/`
- 品牌资产：`../icon.png`、`src/branding.ts`
- 当前视觉实现（仅作反例与功能证据）：`DESIGN.md`、`src/styles.css`、`src/components/ui/`
- 仓库没有可用于宣称客户、性能基准、商业背书或市场规模的证据；后续界面不得虚构此类内容。

## Product Principles

1. 先回答运行状态，再提供操作。
2. 把网络边界讲清楚，不用熟悉但错误的 VPN 隐喻代替事实。
3. 危险操作可预期、可确认，长任务有进度，失败有恢复路径。
4. 移动端先设计、先验证：手机上一只手能完成高频任务，桌面上再扩展为更高效的复杂状态扫描。
5. 诊断信息默认脱敏，并能追溯到真实的 CLI 与 configured/effective 数据面状态。
6. 中文用户先获得完整体验，同时避免让布局和产品概念被单一语言锁死。
