# ActionFlow

A native macOS automation app. Connect shortcuts, mouse input, scrolling, application events or timers to action chains, then create, preview and manage your rules in one workspace.

[Download](https://github.com/pinguarmy/action-flow/releases) · [MIT License](LICENSE) · [Privacy and security](SECURITY.md)

## Features

- Trigger rules with shortcuts, double-press shortcuts, mouse buttons, scrolling, app activation, launch or exit, and timers.
- Combine window layouts, keyboard shortcuts, text insertion, application menu commands, app and URL opening, delays, notifications and optional shell scripts.
- Organize rules with search, groups, templates, conflict warnings, action previews, execution progress, pause and cancellation.
- Store rules as local JSON, with import, export, backups and snapshot recovery. Imported rules start disabled.
- Use English or Simplified Chinese, following your system language.

Input observation is passive: original keyboard and mouse events still reach the active app. The gesture lab recognizes swipes, magnification and rotation inside the app only; it does not provide global multi-finger gesture triggers.

## Install

Requires macOS 14 or later. Choose the Apple Silicon or Intel package from [Releases](https://github.com/pinguarmy/action-flow/releases), then drag `ActionFlow.app` into Applications.

This is an Alpha prerelease with an ad-hoc signature, not Apple notarization. Verify the checksum and use the normal macOS open process. Do not disable Gatekeeper or SIP.

## Get started

1. Create a rule and choose its trigger, conditions and actions.
2. Review the action preview and required capabilities. Grant only the permissions you need.
3. Enable the rule, then resume automation from the menu bar.
4. Use the menu bar to pause automation or stop the current chain at any time.

Global automation and shell scripts start off. Input Monitoring and Accessibility must be granted by you in System Settings; the app cannot grant them itself. Pausing or cancelling does not undo completed actions.

## Local and under your control

No telemetry, accounts, remote control service or cloud sync. Rules and backups stay in `~/Library/Application Support/ActionFlow/`; recent execution status stays in memory. Links and scripts can access the network when you run a rule, and scripts can modify files. Do not enable untrusted rules.

Window, menu and text actions depend on the target app's Accessibility support. Apps may reject operations, and focus checks cannot eliminate every timing race. Start with low-risk actions.

## Build

Requires Swift 6 and Xcode Command Line Tools. No third-party package dependencies.

```bash
swift build
swift run ActionFlowChecks
bash scripts/check-cli.sh
bash scripts/check-runtime.sh
bash scripts/build-app.sh release
open dist/ActionFlow.app
```

Run `swift test` with a full Xcode environment. To build for Intel, use `ARCH=x86_64 bash scripts/build-app.sh release`.

## Offline CLI

`actionflow-cli` inspects configuration files without executing rules.

```bash
swift run actionflow-cli validate examples/window-basics.json
swift run actionflow-cli summarize examples/window-basics.json
swift run actionflow-cli plan examples/window-basics.json
```

Configurations may contain private text, links or scripts. Review them before sharing. See [privacy](PRIVACY.md) and [security](SECURITY.md).
