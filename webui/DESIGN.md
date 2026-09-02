---
name: "MagicNet Quiet Console"
version: "2.0.0"
status: "approved"
approved_direction: "B — 安静控制台"
approved_by: "user"
approved_at: "2026-09-01"
colors:
  background: "#0B0D12"
  surface: "#151A23"
  text: "#F2F4F7"
  primary: "#60A5FA"
---

# MagicNet Quiet Console

Quiet Console is a compact, high-trust control surface for Android root users. It behaves like a careful native settings tool with an IDE-grade editor—not a terminal costume and not a generic card dashboard.

## Product character

- Calm under failure: failures are local, specific, and recoverable.
- Dense without clutter: one dominant task per page; supporting facts recede.
- Direct Chinese: labels name the user outcome; implementation detail appears only where it changes a decision.
- Precise: state colors, numbers, paths, and editor locations mean exactly one thing.
- Frontend only: visuals and copy never invent backend capability.

## Visual world

### Color

| Role | Light | Dark |
| --- | --- | --- |
| background | `#F6F7F9` | `#0B0D12` |
| raised surface | `#FFFFFF` | `#151A23` |
| sunken surface | `#F0F2F5` | `#0F131A` |
| primary | `#2563EB` | `#60A5FA` |
| text | `#172033` | `#F2F4F7` |
| muted text | `#667085` | `#98A2B3` |
| border | `#D7DCE3` | `#293140` |
| success | `#15803D` | `#4ADE80` |
| warning | `#A16207` | `#FBBF24` |
| danger | `#C2414B` | `#FB7185` |

Primary: "#60A5FA"

Blue is interactive emphasis, never decoration. Green, amber, and red are reserved for observed state. Neutral surfaces carry hierarchy. Do not use gradients, glass blur, phosphor glow, or monochrome neon fields.

### Type

- UI: system sans with CJK fallbacks; sentence case; no decorative all-caps English.
- Code/data: system monospace only for JSON, paths, addresses, identifiers, and values users copy.
- Page title: 24–32px, semibold, tight tracking.
- Body/helper: 13–14px, regular, 1.5–1.7 line height.
- Labels: 12–13px, semibold; operational terms stay recognizable.

### Shape and depth

- Radius scale: 6 / 8 / 10px. Pills are reserved for compact status/category semantics.
- One-pixel borders define sections. Shadows only separate sticky/floating layers.
- Nested cards use a sunken surface and no shadow. Prefer grouped lists and split workspaces over equal card grids.
- Spacing scale: 4 / 8 / 12 / 16 / 24 / 32px.

## Signature Mechanism: Precision Editor Rail

The configuration editor is the product's memorable mechanism. Its quiet line rail is always aligned with native textarea content, virtualizes large files, highlights current and syntax-error lines, accepts direct line clicks, and turns error location text into a jump action. It should feel like a small IDE embedded in a native control tool.

The mechanism may reappear as precise row indices, step indices, and live state markers elsewhere, but never as decorative terminal syntax.

## Shell and navigation

- Mobile: solid command bar, concise runtime strip, horizontal page tabs, four-item bottom navigation.
- Desktop: compact command bar, runtime strip, 204px task-group rail, page tabs above the surface.
- Navigation labels use outcomes (`运行状态`, `配置文件`, `最近输出`) rather than internal codenames.
- The shell reports global state once. Detailed route diagrams live on their dedicated page.

## Page hierarchy

1. Page identity: one title and at most one short outcome sentence.
2. Primary action/task: editor, list, form, or operation.
3. Current state and result.
4. Secondary context or advanced settings behind natural disclosure.
5. Destructive actions separated by consequence-specific confirmation.

No page should open with a wall of equally loud summary cards.

## Components

- `Button`: label remains visible during loading; blue primary, neutral secondary, red destructive.
- `Card`: quiet section surface; no decorative radius/shadow escalation.
- `PageHeader`: title + concise outcome; no bracketed English kicker.
- `Badge`/`StatusDot`: observed status only.
- `Tag`/`RemovableTag`: categories and removable selections only.
- `ConfirmPanel`: names object and consequence; destructive confirmation is visually distinct.
- `ConfigCodeEditor`: native editing/undo/selection is authoritative; syntax layer is visual only.

## Feedback and copy

- Loading under 300ms remains quiet; longer work names the object being loaded.
- Failure says what failed and what the user can do next. Preserve drafts.
- Empty states distinguish first use, no matches, unavailable data, and permission limits.
- Remove phrases that merely restate architecture, implementation safety, or a sequence the UI already shows.
- Use protocol names only when users must identify, configure, or debug them.

## Responsive and accessibility

- Primary interactive targets are at least 44px; tightly spaced editor line targets use the WCAG 2.2 24px minimum and remain at least 44px wide.
- At 360px, show one task column; actions wrap without covering content.
- At 200% text, navigation and primary flows remain operable.
- Focus is always visible. Selected/current/error states use shape, border, label, or icon as well as color.
- Forced colors preserve borders and selected state.
- Reduced motion removes nonessential transitions.

## Source Evidence & Confidence

- [observed] path: `src/styles.css`
  sha256: `09ea94fbcad925fe5af6cc1744ca2d107a00cd98fad8cb9036fcd53d0bce5dbc`
  confidence: high
- [observed] path: `src/App.vue`
  sha256: `08f38023230313dcf7127925fa778f9a7a6c71b10874241b53ab5fa709fc09b6`
  confidence: high
- [observed] path: `src/components/ConfigCodeEditor.vue`
  sha256: `bdeb5bdaded41eb5d32fb8db7089baf2af8a307d2d20b04609e72ea2ad14758d`
  confidence: high
