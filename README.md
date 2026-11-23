# CodePilot

**Native macOS Notch & Menu Bar Command Center + Smart Keep-Awake for Multi-Agent AI Coding Workflows.**

English | [简体中文](README.zh-CN.md)

[![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6.0%20Strict%20Concurrency-F05138?style=flat-square&logo=swift)](https://swift.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-30D158?style=flat-square)](LICENSE)

---

## Why CodePilot?

When you run multiple AI coding agents in parallel (Antigravity, OpenAI Codex, Claude Code, DeepSeek Harness, Kimi Code, WorkBuddy), two things constantly interrupt your flow:

1. **You miss approval prompts & finished turns** buried in background tabs or windows.
2. **Your Mac goes to sleep mid-generation** during long builds, refactors, or agent loops.

**CodePilot** solves both in a **~4 MB pure native Swift / SwiftUI / AppKit / IOKit** app — zero Electron, zero Node.js runtime, **100% local read-only**, and zero prompt uploads.

---

## Key Features

- **Hardware-Native Notch Interaction (Dynamic Morph)**
  - Seamless concave top shoulders aligned pixel-for-pixel with MacBook hardware notches (gracefully degrades to a sleek floating pill on non-notched displays).
  - Fixed transparent `NSPanel` canvas with precision `hitTest` click-through and two-stage spring Morph animation.
  - Collapsed left ear shows the highest-priority precision vector status glyph (`Waiting` > `Running` > `Completed`); hover expands into 3-tile precision cards + grouped task stream + one-click keep-awake strip.
- **Braun / Teenage Engineering Inspired Menu Bar Console**
  - Warm Ceramic (Light) / Matte Titanium (Dark) chassis with an embedded pure-black OLED screen, 4-slot vector icon filter bar, grouped task stream, and tactile keep-awake keys (`15m` / `30m` / `60m` / `Permanent`).
  - Right-click the Menu Bar icon for an instant native quick-action menu.
- **Amphetamine-Grade Smart Keep-Awake (IOKit Lease Engine)**
  - Priority lease hierarchy: `Permanent Manual > Timed Manual > Process Rules > AI Auto`.
  - Fork-free Darwin `libproc` process scanner (`xcodebuild`, `swiftc`, `pytest`, `cargo`, `docker`, `ffmpeg`, customizable in Settings).
  - Make-before-break assertion upgrades, configurable grace period, low-battery automatic cutoff with +5% hysteresis, and wake-from-sleep assertion rebuild.
- **Zero-Intrusion Local Read-Only Adapters + Open CLI**
  - Out-of-the-box support for **6 AI coding tools** + hardened local Unix Domain Socket (`~/.codepilot/events.sock`) + `CodePilot emit` CLI for Cursor / Windsurf / Shell hooks.
- **Custom Minimal Soundscape & Local Quota Alerts**
  - 4 built-in royalty-free UI sounds (`Radar`, `Chime`, `Thud`, `Pulse`) + Keychain-backed DeepSeek balance & 100% offline Codex local quota with low-quota alerts.

---

## Supported AI Coding Agents

| Tool | Local Read-Only Source | Approval / Waiting Detection | Click-to-Jump |
| :--- | :--- | :---: | :--- |
| **Antigravity** | `~/.gemini/antigravity/brain/*/transcript.jsonl` | `ask_question`, `BypassSandbox`, `RequestFeedback` | Activates Antigravity |
| **OpenAI Codex** | `~/.codex/sessions/**/rollout-*.jsonl` + `state_5.sqlite` | Waiting & rate-limit quota | `codex://threads/<id>` |
| **Claude Code** | `~/.claude/projects/**/*.jsonl` | Waiting & completion | `claude://code/continue` |
| **DeepSeek Harness** | `~/.dsh/storages/session_projcache/sessions/*.json` | Waiting & completion | Activates DSH |
| **Kimi Code** | `~/.kimi-code/session_index.jsonl` + `state.json` | Waiting & completion | Activates Kimi / Terminal |
| **WorkBuddy** | `~/.workbuddy/workbuddy.db` (short read-only WAL snapshot) | Waiting & completion | Activates WorkBuddy |
| **Any Tool / Shell** | `~/.codepilot/events.sock` (`CodePilot emit`) | Full custom status | Activates Terminal |

---

## Quick Start

### Build from Source (macOS 14+ / CommandLineTools or Xcode)

```bash
git clone https://github.com/your-org/CodePilot.git
cd CodePilot

# Run all 33 unit tests
./scripts/test.sh

# Build & ad-hoc sign Release .app
./scripts/bundle_app.sh release

# Install to /Applications and launch
ditto dist/CodePilot.app /Applications/CodePilot.app
open /Applications/CodePilot.app
```

### Community Hook Integration (`CodePilot emit`)

Push events from Cursor, Windsurf, or any shell script directly into CodePilot's Notch & Menu Bar:

```bash
/Applications/CodePilot.app/Contents/MacOS/CodePilot emit \
  --source custom \
  --status waiting_user \
  --title "PR Ready for Review" \
  --message "All CI checks passed"
```

---

## Architecture Overview

```
Local Read-Only Adapters (6 AI Tools) + UnixSocketServer (~/.codepilot/events.sock)
                                │
                                ▼
                    TaskStore (Actor State Machine)
          (Priming 3-Way · Epoch/Seq · 30s Zombie Sweep)
                   │                            │
                   ▼                            ▼
    PowerAssertionManager (IOKit)      DebouncedAlertCoordinator
 (Manual > Timed > Process > AI Auto)  (Notch Morph + Sound + Banner)
```

---

## Privacy & Security

- **100% Local**: No analytics, no telemetry, no conversation content ever leaves your Mac.
- **Zero Intrusion**: Host tool configs and SQLite databases are never modified.
- See [SECURITY.md](SECURITY.md) for details and [CONTRIBUTING.md](CONTRIBUTING.md) for the **80-Line Guide to Adding a New Adapter**.

## License

MIT © 2026 CodePilot Contributors
