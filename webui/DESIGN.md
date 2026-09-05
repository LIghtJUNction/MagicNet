---
name: "MagicNet Quiet Console"
version: "3.0.0"
status: "implemented"
direction: "简洁、中性、以操作与真实状态为中心"
colors:
  background: "#171717"
  surface: "#1D1D1D"
  text: "#F3F3F3"
  primary: "#E8E8E8"
---

# MagicNet Quiet Console

MagicNet is a compact Android network tool. The interface gives room to subscriptions, configuration, and observed runtime state. Shared styles live in `src/styles.css`; a second stylesheet must not override the same shell and components.

## Visual language

| Role | Light | Dark |
| --- | --- | --- |
| Canvas | `#FFFFFF` | `#171717` |
| Contained surface | `#FFFFFF` | `#1D1D1D` |
| Secondary surface | `#F6F6F6` | `#222222` |
| Main action | `#292929` | `#E8E8E8` |
| Text | `#242424` | `#F3F3F3` |
| Secondary text | `#737373` | `#AAAAAA` |
| Divider | `#E7E7E7` | `#353535` |
| Control border | `#C4C4C4` | `#575757` |

The palette is neutral. Green, amber, and red communicate observed status. No gradients, glass blur, decoration-only English, or colored dashboard backgrounds. Monospace is for code and values that users need to copy.

Page titles are 22–26px at the default text size. Shared navigation and buttons use relative units so system text enlargement works. Dividers and spacing define sections; small radii are for controls and contained subpanels. Floating sheets alone receive shadows.

## Navigation and hierarchy

- On phones, the bottom bar provides `运行`, `路由`, `订阅`, and `诊断`. The subscription entry always opens subscriptions; other workspaces remember their last page. Local tabs expose related pages and remain visible while scrolling.
- On desktop, the left rail exposes every page in four groups. Users can open subscriptions, configuration, or logs with one click; there is no second desktop tab bar.
- A compact header holds the brand and global actions. Theme and refresh remain visible on phones. Help, feedback, GitHub, and the author link remain in the utility sheet.
- Global service state appears once. A task or notice appears when there is something to report; idle placeholder text is omitted.
- Each page has one title, an optional useful description, and visible primary actions. Actions wrap in normal flow.

## Components

- `Card` is a semantic section with a thin top divider. Nested subpanels may use a quiet secondary surface. Explicitly colored state sections retain a side rule and readable content.
- `Button` retains its label while loading. The main action uses graphite in light mode and light ink in dark mode. Secondary actions remain distinguishable. Destructive actions retain red.
- `PageHeader` supports both action slots, keeps the heading and actions in normal flow, and ignores legacy decoration-only overlines.
- Status badges and dots reflect actual state. Missing data has an explicit unavailable label.
- Subscription metadata must come from provider responses. Usage, quota, and dates must remain distinguishable from device traffic and locally recorded update times.

## Signature Mechanism: Precision Editor Rail

The configuration editor retains native editing, undo, and selection, an aligned virtualized line rail, direct error-location jumps, and readable syntax colors for each theme. Large files must not force full-file highlight work on every keystroke.

## Accessibility and operational behavior

- Primary touch targets are at least 44px; bottom navigation targets are at least 56px tall.
- At 360px and 200% text, content and actions wrap without covering one another. Menus scroll in short viewports and respect safe areas.
- Focus is always visible. Selected navigation has a border and label weight in addition to color. Forced colors retains selection boundaries.
- Reduced motion disables nonessential motion. Short press feedback remains available otherwise.
- Navigation preserves form state and browser history. Page loading stays asynchronous.
- Confirmations preserve existing consequence-specific safeguards. UI copy must not claim backend capability that has not been observed.
- Brand tapping retains all existing visitors, including GPT-6, without putting easter-egg text in routine tasks.
