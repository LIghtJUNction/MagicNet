---
name: "MagicNet Phosphor Grid"
colors:
  background: "#050706"
  surface: "#0A0E0B"
  text: "#E6F7C8"
  primary: "#B7F34A"
---

# MagicNet WebUI — 字形终端设计基线

## Visual Theme & Atmosphere

MagicNet 是 Android root 设备上的实时网络控制台，不是普通 VPN 客户端。界面采用“字形终端 / Phosphor Grid”视觉世界：状态、路径、命令和日志共享一套字符网格，先让用户读懂运行事实，再执行操作。终端语言用于组织信息，不做复古装饰或黑客角色扮演。

- 气质：精确、克制、实时、可追溯；技术准确但不故意晦涩。
- 每个视口只有一个主要状态区域和一个主要操作。其余内容通过分隔线、缩进和密度后退，不使用彩色卡片争夺注意力。
- 结构字符（`[]`、`>`、`/`、`::`、序号和细线）只承担分组、路径和状态含义。
- 中文正文保持自然大小写与标点；英文命令、短标签和机器值可以使用终端式大写。

## Color Palette & Roles

### 暗色主场

- 场地：近黑绿 `#050706`
- 主文字：浅磷光 `#E6F7C8`
- 次文字：灰绿 `#9CB17A`
- 主信号：亮绿 `#B7F34A`
- 结构线：深苔绿 `#34452B`

### 亮色等价面

- 场地：冷纸白 `#F2F5EB`
- 主文字：黑绿 `#121711`
- 次文字：深灰绿 `#4E5D42`
- 主信号：深叶绿 `#2D660D`
- 结构线：浅灰绿 `#B8C3AA`

### 语义色

- 成功、警告、危险、信息各有独立 token，并同时配合文字或图形，不得只靠颜色。
- 主信号色只用于当前路径、焦点和主操作；每个视口的强强调不超过三处。
- 禁止紫蓝渐变、霓虹光晕、彩虹状态卡和低对比透明文字。

## Typography Rules

- UI 采用支持中文的等宽优先栈：`ui-monospace`、系统等宽字体、`Noto Sans Mono CJK SC`，再回退到可靠的中文系统字体。
- 正文在手机上不小于 14px；关键状态 18–24px；导航和可操作文字不小于 12px。
- 机器值、时间、流量和计数使用等宽数字与 `tabular-nums`。
- 不使用超大营销标题；页面标题应在首屏状态之后服务于扫描。

## Layout Principles

- 移动端先设计、先验收。360px、390px 和 430px 宽度均不得出现页面级横向滚动。
- 手机采用四个稳定主入口：运行、路由、配置、诊断。底部导航尊重安全区，触控目标至少 44×44px。
- 每个工作区内部使用可横向滚动但不截断内容的局部标签，不能把十个页面重新塞回主导航。
- 手机内容默认单列；列表、日志与代码块在自身容器内处理长内容。
- 桌面端把同一四区结构扩展为左侧轨道，并允许主内容获得更高密度；不创建另一套信息架构。
- 主要内容最大宽度受控，但诊断日志与数据表可按职责占满可用宽度。

## Shape & Material

- 表面接近平面终端面板：0–4px 小圆角、1px 分隔线、无玻璃模糊、无悬浮大阴影。
- 容器依靠边界、标题行与留白区分；禁止连续嵌套大圆角卡片。
- Pill 只允许用于真实状态或短计数；分类与可移除项使用矩形 Tag。
- Logo 保留原图，不把整个界面变成 Logo 配色。

## Signature Mechanism: Live Route Stack

首屏出现一条可读的运行路径：Android root 入口 → `magicnet0` → sing-box 核心 → 策略/出口。它显示结构与当前运行状态，但不虚构未验证的接口、节点或出口事实。状态变化在同一位置更新，并带最近任务或更新时间；失败直接提供下一步操作。

## Component Stylings

- `StatusLine`：全局运行事实和最近任务，使用 `role="status"` / `aria-live="polite"`。
- `RouteStack`：只读结构图，不伪装成可拖拽接线器。
- `Button`：主操作为实心信号色；次操作为边框；危险操作使用危险语义并确认。
- `Badge`：只表示状态或计数。`Tag` 表示分类、策略项或可移除对象。
- `Card`：职责明确的终端分区，不是默认白卡容器。
- `Dialog`：高风险确认和短阻断任务；移动端工具菜单可以使用底部 sheet，但设置表单不得堆进 Modal。
- `Input` / `Textarea`：固定边界、清晰标签、可见焦点；错误说明靠近字段。
- `LogViewport`：可复制、可折行或容器内横滚，始终保留脱敏边界。

## Motion & Interaction

- 交互动画只使用 `transform` 和 `opacity`，通常 120–220ms；按压反馈立即发生。
- 不使用持续闪烁、扫描线动画或装饰性打字机效果。运行中动画必须解释状态，且在 `prefers-reduced-motion` 下有静态等价表达。
- 小于 300ms 的任务不显示指示；300ms–2s 保持布局的加载占位；更久任务显示正在做什么；超时提供重试或取消。
- 危险操作保留确认、禁用、加载和焦点恢复；异步结果不得仅依赖 toast。

## Accessibility

- 简体中文为当前默认语言，但组件不得依赖固定中文长度。导航、按钮和状态在约 1.5 倍文本扩展时仍可访问。
- 保持语义 HTML、键盘顺序、可见焦点、对话框焦点约束和关闭后的焦点恢复。
- 文字与背景满足 WCAG AA；小号次文字尤其不得通过 opacity 降低到不可读。
- 支持 `prefers-contrast`、`prefers-reduced-motion` 和亮/暗主题。

## Explicit Exclusions

- 普通 VPN 的巨型连接圆钮、速度仪表盘和地图隐喻。
- 玻璃拟态、紫蓝渐变、发光边框、漂浮卡片墙、大面积圆角胶囊。
- 用 ASCII 图案遮挡正文、用终端噱头替代清晰按钮、假装存在命令行输入能力。
- 六等分或十等分移动端底栏、小于 44px 的触控目标、10px 导航标签。
- 改写后端事实、泄露订阅或设备隐私、恢复非 TUN 路径。

## Source Evidence & Confidence

- [observed] path: `PRODUCT.md`
  sha256: `c22912c4e72a4b5f9579b5bb5561f2cb1e39c767abbcc013273a510681bfb140`
  confidence: high
- [observed] path: `.scratch/frontend-redesign-20260823/spec.md`
  sha256: `7ecb87443567793d332ca986192b1a95ca7c6baba346d5a75acfeeae045571ba`
  confidence: high

## Known Gaps & Exceptions

- The runtime implementation still reflects the superseded visual world until this run completes Fill and verification.
- Full English copy is outside this run; layout and component contracts must remain translation-ready.
- Rendered mobile evidence is required before treating contrast, long-text behavior, and safe-area behavior as verified.
