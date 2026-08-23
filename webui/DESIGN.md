---
name: "webui"
colors:
  background: "unresolved"
  surface: "--mn-surface"
  text: "unresolved"
  primary: "--mn-on-accent"
---

# Design System: webui

## Visual Theme & Atmosphere

- [observed] Existing first-party theme, shared component, and page sources define the current visual baseline.
- [inferred confidence=medium] Preserve the observed token vocabulary, density, and component conventions when adding new surfaces.

## Color Palette & Roles

- [observed] `--color-mn-ink: #141413`
- [observed] `--color-mn-ink-soft: #2a2a27`
- [observed] `--color-mn-ink-muted: #3d3d38`
- [observed] `--color-mn-ink-faint: #5a5a54`
- [observed] `--color-mn-ivory: #faf9f5`
- [observed] `--color-mn-carrier: #f0eee6`
- [observed] `--color-mn-carrier-deep: #e4e1d6`
- [observed] `--color-mn-cactus: #bcd1ca`

## Typography Rules

- [observed] `-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display",
    "HarmonyOS Sans SC", "MiSans", system-ui, sans-serif`
- [observed] `ui-monospace, "SFMono-Regular", Consolas, monospace`
- [inferred confidence=medium] Reuse the existing font stack and derive hierarchy from shared components before introducing new sizes.

## Component Stylings

- [observed] `src/components/ConfigCodeEditor.vue`
- [observed] `src/components/IssueReporterDialog.vue`
- [observed] `src/components/OnboardingDialog.vue`
- [observed] `src/components/OpenSourceSupportNote.vue`
- [observed] `src/components/pages/AppsPage.vue`
- [observed] `src/components/pages/BlocklistPage.vue`
- [observed] `src/components/pages/ConfigPage.vue`
- [observed] `src/components/pages/ConnectionsPanel.vue`
- [inferred confidence=medium] Prefer existing primitives and variants over page-local replacements.

## Layout Principles

- [inferred confidence=low] No named spacing tokens were detected; confirm the base spacing rhythm.
- [observed] Representative page: `src/components/pages/AppsPage.vue`
- [observed] Representative page: `src/components/pages/BlocklistPage.vue`
- [observed] Representative page: `src/components/pages/ConfigPage.vue`
- [observed] Representative page: `src/components/pages/ConnectionsPanel.vue`
- [observed] Representative page: `src/components/pages/ControlPage.vue`
- [observed] Representative page: `src/components/pages/DiagnosticsPage.vue`
- [inferred confidence=medium] Match the density and alignment rhythm of representative pages.

## Motion & Interaction

- [observed] `--mn-motion-spring: cubic-bezier(0.22, 1, 0.36, 1)`
- [observed] `--mn-motion-press: 90ms`
- [inferred confidence=medium] Preserve visible hover, focus, pressed, loading, and reduced-motion behavior from existing primitives.

## Accessibility

- [inferred confidence=medium] Preserve semantic controls, keyboard focus visibility, and non-color state cues present in existing primitives.
- [inferred confidence=low] Contrast, touch targets, text scaling, and reduced-motion behavior require runtime verification.

## Source Evidence & Confidence

- [observed] path: `index.html`
  sha256: `137ad9aa727afc8a64c7446d1a36f724f8ecf27df6cfcf40dfea8732e867027d`
  confidence: high
- [observed] path: `src/App.vue`
  sha256: `cdd4cf9745c42e7f85e76ac8551126c1c04ae98228e12cc77d6d02b8e9616afd`
  confidence: high
- [observed] path: `src/styles.css`
  sha256: `86f6b1bbbfaf18834850134903b4c46c6958bae0d12b5c7d31c01820e1fe7397`
  confidence: high
- [observed] path: `src/components/ConfigCodeEditor.vue`
  sha256: `fd79af1fc98c3d2839cd48fd1733373ff1d5685cda532e7fcadabbc21975449d`
  confidence: high
- [observed] path: `src/components/IssueReporterDialog.vue`
  sha256: `6d8e9c207b7b583bb32f78f203affa87e356d153e6db57be725de7aa0a693206`
  confidence: high
- [observed] path: `src/components/OnboardingDialog.vue`
  sha256: `a516f56b85941ac3553f3134fd36e7520620e02a69e476da422dee450dd1fcee`
  confidence: high
- [observed] path: `src/components/OpenSourceSupportNote.vue`
  sha256: `087197f3a97a6c770f343c32a316df67807dbb3551487d0f34d3397fc6b88db6`
  confidence: high
- [observed] path: `src/components/pages/AppsPage.vue`
  sha256: `71660e22b7da7c959b003f0f6dffba619c6a50e167de76b167c6f20b8c21b9b7`
  confidence: high
- [observed] path: `src/components/pages/BlocklistPage.vue`
  sha256: `a91533b4f7d8e8316073ffc18cc1921941e8141f473e359ea11b64557058b12f`
  confidence: high
- [observed] path: `src/components/pages/ConfigPage.vue`
  sha256: `a4d3150cc2f888e46b9ce222ce0877cd5d617a51bb134b149c57dfb711d91f48`
  confidence: high
- [observed] path: `src/components/pages/ConnectionsPanel.vue`
  sha256: `937dc57cf2e701ba35c80da3e8bd9a89f7b033a517fcd8fa823880ba2b44871d`
  confidence: high
- [observed] path: `src/components/pages/ControlPage.vue`
  sha256: `d2b57e7ad1f336f7ffb3134a7e401170aae1dcd255e05713f15499eb6ad8ede6`
  confidence: high
- [observed] path: `src/components/pages/DiagnosticsPage.vue`
  sha256: `37f77826dbf05dcc81b31b0bbe7a23aa370a63ee9f33d22a665e17fb412f5c7e`
  confidence: high
- [observed] path: `src/components/pages/DnsToolsCard.vue`
  sha256: `8951c4377ab3d4e2e550f3218ee1b3b290ac135c1895fd72a8b90deabd30e9d1`
  confidence: high
- [observed] path: `src/components/pages/EcaptureToolsCard.vue`
  sha256: `2ec1d7da7be3283dd7a0d3e79f528701f34227ad0acca1ad9fce67b88fe4ff07`
  confidence: high
- [observed] path: `src/components/pages/McpToolsCard.vue`
  sha256: `a1602ed9877f4ba977d287f3cfdf3b871ec8767e39b03b7560fa410f482b2633`
  confidence: high
- [observed] path: `src/components/pages/NetworkPolicyCard.vue`
  sha256: `c41deb4a8a766dd5c98018d825afc7bc877b2e1d4dd1cf5c52acf17e1e00ac52`
  confidence: high
- [observed] path: `src/components/pages/NetworkSnapshotPanel.vue`
  sha256: `048b419efcec79211895d5445537dd30cf0438db77a0125c94e11e25be18a5c2`
  confidence: high
- [observed] path: `src/components/pages/NodeDelayPanel.vue`
  sha256: `8fd8552376093d92c6782686256bc1632f5614072c50beae15a1b3945d7af2a7`
  confidence: high
- [observed] path: `src/components/pages/OutputPage.vue`
  sha256: `1d8737e8d327dbaa454bc5df91757b24c5ec2c37278494823b3fb429bff40722`
  confidence: high
- [observed] path: `src/components/pages/ProxyChainPage.vue`
  sha256: `516b9436f0d1e75ad5612cab8ffef31333e79729fd6363eaae06882f0ccb48e8`
  confidence: high
- [observed] path: `src/components/pages/ProxyGroupsPanel.vue`
  sha256: `23a014e89d5e1ba66366ea807b882c3b377da01c2f749fc0b833010bdf965245`
  confidence: high
- [observed] path: `src/components/pages/RuntimeLogsPanel.vue`
  sha256: `20dff4b7fec5ba5759d4a6937cd4b967ca4a1286f79f9a0d5f17fb5c1412faf3`
  confidence: high
- [observed] path: `src/components/pages/SubscriptionsPage.vue`
  sha256: `f3c303ecef3b0167bd4654afb71769328eb6fac52004d0b3430d73cd570f78f5`
  confidence: high
- [observed] path: `src/components/pages/ToolActionConfirmCard.vue`
  sha256: `7d7452bec0e223eee08220a26176a51b92f6437a5f82cf3de759a40ce966c8d5`
  confidence: high
- [observed] path: `src/components/pages/ToolsPage.vue`
  sha256: `cc503065513f528a37ea1f97bd5e1712c0302e0e937e86aeec31a696c5ba9648`
  confidence: high
- [observed] path: `src/components/pages/TrafficStatsPanel.vue`
  sha256: `9bec8b09dad208cf3b71aa1e6eb2b73d14ef1e8bc83d1484a68d803a0d301518`
  confidence: high
- [observed] path: `src/components/pages/WarpRouteRulesPanel.vue`
  sha256: `c4bb1fab8200cf8b8748acd0e541f668e264fe32e44ac5cf85ff6229cb75e6d8`
  confidence: high
- [observed] path: `src/components/pages/WebuiPage.vue`
  sha256: `0a0579f8650b1e585311cd260321f7e2167d6d16197c220fc0f6b7067df920b2`
  confidence: high
- [observed] path: `src/components/ui/Badge.vue`
  sha256: `69cf9d5afa1a6570299cd961190c3d8f8dc4ebcdd6aefe29279781f23b126759`
  confidence: high
- [observed] path: `src/components/ui/Button.vue`
  sha256: `49004fd6430d18c7e037b2805c2da72077a5efd2a8a0312050b56dd9490475e7`
  confidence: high
- [observed] path: `src/components/ui/Card.vue`
  sha256: `e8314815d7ffa795bb93588c9f738258c10d8db38871007fcd22f946a2bff13f`
  confidence: high

## Known Gaps & Exceptions

- [inferred confidence=medium] Semantic intent inferred from implementation must be reviewed before this draft becomes project authority.
- [observed] Shape token `--mn-radius-sm: 0.75rem`
- [observed] Shape token `--mn-radius-md: 1rem`
- [observed] Shape token `--mn-radius-lg: 1.375rem`
