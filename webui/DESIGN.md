---
name: "MagicNet — Network Utility"
version: "3.0.0"
status: "proposal"
---

# MagicNet visual direction

This revision is a proposal responding to rejection of the previous two iterations. It has not been approved by the user.

## Composition

The mobile home screen starts with a single, large, observed sing-box state. The recovery explanation follows it; the full-width service control and four maintenance actions follow that explanation. Configured and effective modes remain separately labelled in the transparent-mode disclosure, without repeating them in the overview.

Transparent mode, Wi-Fi policy and hotspot policy use native details/summary disclosures. Their forms remain mounted, keyboard-operable and available without changing navigation. A recent transparent-mode error remains visible outside the disclosure. Node and proxy-group management links to the existing zashboard entry point.

There is no second page title, wall of peer cards, fake speed chart, connection percentage, or invented device state. Missing device access continues to say so. The copy-state action retains the existing redaction logic.

Desktop separates the service controls and network settings into two columns, with a narrow workspace rail. The mobile bottom navigation keeps four labelled destinations. Global operation feedback, root confirmation, application drafts, theme switching and the five-click brand signature stay available. The home screen suppresses only the idle duplicate status strip; tasks, device-side errors and background output keep it visible. A missing execution bridge is already explained beside the home status. Other pages retain the strip.

## Colour and typography

The effective visual tokens live in `src/console.css`, loaded after the shared foundation in `src/styles.css`. The previous console override file is replaced, not appended. Base semantic classes and page primitives still share the same token names.

| Role | Light | Dark |
| --- | --- | --- |
| Canvas | `#F4F4EF` | `#171B16` |
| Text | `#292B27` | `#ECEDE6` |
| Secondary text | `#696E64` | `#A7AFA0` |
| Interaction accent | `#B3462B` | `#F0A181` |
| Service control | `#30392D` | `#E0E7D5` |

The accent identifies interaction. Success, warning and danger retain distinct semantic tokens and visible labels. The service button uses a high-contrast ink surface, without glow or animated decoration.

System fonts and CJK fallbacks stay local. A 34–50px status heading establishes hierarchy; body text, control labels and secondary labels remain smaller. No remote font requests or additional runtime dependencies are introduced.

## Interaction and accessibility

Disclosures use native keyboard behaviour and a rotating chevron. Buttons keep their labels during loading. Destructive actions still call the existing confirmation functions. The primary action remains service start/stop; restart remains a separately labelled action.

Controls wrap at narrow widths and enlarged text sizes. Safe areas, scrollable short-viewport menus, focus trapping, focus restoration, reduced motion and forced-colour selection indicators are retained. Text and primary control token contrast is tested against 4.5:1 in both themes.

The design must be reviewed from the compiled application in both themes. Passing tests is not an aesthetic approval, and a browser preview is not evidence of Android/KernelSU device validation.
