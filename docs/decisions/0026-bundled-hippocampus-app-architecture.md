# ADR-0026 — Bundled Hippocampus.app Architecture

- Status: Accepted (2026-05-21; ratifies the bundled-app architecture decision from the CEO EOD discussion. Documents the architecture already implemented across PRs #88, #90, #112, #125).
- Owners: **Director-Recording** (app shell + child process supervision) + **Director-Brain** (recall WindowGroup)
- Reviewers: CTO (sequencing); CEO (ratification)
- Phase: 7 (already implemented — PR #90 menu-bar shell, PR #112 recall UI v2, PR #88 onboarding scaffold, PR #125 onboarding 5-step). iOS/watchOS targets = Phase 9.
- **Protected-set: no.** App architecture decision. No crypto, sync, or sensitive-capture change. Normal review.

## Context

Earlier design discussions considered whether Recall and Onboarding should be separate app bundles or integrated into a single Hippocampus.app. Separate apps would mean separate Dock icons, separate launch, separate update paths — added complexity for the user and for the build system.

The CEO ratified: single app on Mac, multiple Xcode targets on iOS/Watch. This ADR documents that decision and the architecture already in place.

## Decision

### 1. One app bundle on macOS: Hippocampus.app

Hippocampus.app is a single macOS app bundle containing all user-facing surfaces as SwiftUI WindowGroups:

#### 1.1 WindowGroups

| WindowGroup ID | Purpose | Activation |
|---|---|---|
| `recall` | Recall timeline + search UI | Menu bar "Show Recall" or global hotkey Cmd+Shift+R |
| `onboarding` | First-launch setup (5-step flow per PR #125) | Auto-opens on first launch; "Setup" in menu bar |
| `settings` | Preferences pane (Phase 7 follow-on) | Menu bar "Settings..." or Cmd+, |

Each WindowGroup is a SwiftUI `WindowGroup` with a stable identifier. macOS manages window lifecycle (position restoration, multiple monitors, full-screen).

#### 1.2 Menu bar agent

Hippocampus.app uses the `StatusBarApp` pattern (LSUIElement = YES in Info.plist — no Dock icon). The menu bar status item is the primary UI surface:

```
[H] ▾
├── Show Recall          (Cmd+Shift+R)
├── ─────────────────
├── ● Recording          (or ⏸ Paused, or ○ Off)
├── Last capture: 2s ago
├── Events today: 342
├── ─────────────────
├── Pause Recording      (toggle)
├── Settings...          (Cmd+,)
├── ─────────────────
├── Send Crash Report    (if opted in, PR #126)
├── ─────────────────
└── Quit Hippocampus     (Cmd+Q)
```

State is reflected in the status item icon:
- Recording: filled icon
- Paused: half-filled icon
- Off (permissions missing): outline icon with exclamation

#### 1.3 Child processes

Hippocampus.app supervises two child processes:

| Process | Binary | Role |
|---|---|---|
| MCICaptureHelper | `Contents/Helpers/MCICaptureHelper` | Screen capture (ScreenCaptureKit) + OCR (Vision) + context signals (NSWorkspace/AX/AppleScript). Runs as a separate process for TCC permission isolation. |
| mci-agent | `Contents/Helpers/mci-agent` | Rust binary. Brain pump (events → chunk → embed → store), MCP server, episode segmenter, retention purger, analytics reporter. |

Supervision via `Process` (Foundation):
- Hippocampus.app launches both helpers at startup.
- If a helper crashes, it is restarted after a 2-second delay (max 3 restarts per 5 minutes; after that, show an error notification).
- Pause/Resume: SIGSTOP/SIGCONT to MCICaptureHelper. mci-agent stays running (MCP queries should work even when capture is paused).
- Quit: SIGTERM to both helpers, wait 5 seconds, SIGKILL if still running.

### 2. iOS: separate Xcode target (Phase 9)

HippocampusApp for iOS is a separate Xcode target in the same workspace, sharing Swift packages:

- **Shared packages:** `BrainFFI` (Rust↔Swift bridge), `RecallUI` (recall timeline components), `HippocampusCore` (shared models, formatters, utilities).
- **iOS-specific:** read-only recall + timeline. No capture on iOS in v1 (iOS screen recording API is too restricted).
- **Data source:** CloudKit personal sync (ADR-0023 §1). The iOS app pulls from the same CloudKit private database as the Mac app.

### 3. watchOS: separate Xcode target (Phase 9)

HippocampusWatch is a separate Xcode target:

- **Complications:** "Last event" text complication, "Events today" count complication.
- **Glanceable recall:** voice query via Siri Shortcuts ("What was I working on at 2pm?") → queries the brain via the paired iPhone's CloudKit cache.
- **No direct brain access.** watchOS queries the iPhone app, which queries CloudKit.

### 4. App icon

The current app icon is a placeholder. A real designer pass is owner-blocked (requires the CEO to commission or approve design work). The placeholder is acceptable for development and testing.

### 5. What this ADR does NOT do

- **Does not add new WindowGroups.** Recall, onboarding, and settings are the three surfaces. Future surfaces (e.g., a brief editor for workspace users) are added as new WindowGroups in the same app — no new app bundles.
- **Does not change the helper architecture.** MCICaptureHelper and mci-agent remain as separate binaries for TCC isolation and language-boundary reasons (Swift helper + Rust agent).
- **Does not define the iOS capture strategy.** iOS capture (if ever) is Phase 10+ and requires a separate ADR.

## Consequences

- **Positive:** Single app on Mac = single update path (Sparkle updates one bundle), single Dock presence (none — menu bar only), single install (one drag to /Applications).
- **Positive:** WindowGroups share the same process, so recall can query the brain directly (same address space as the agent supervision code) without IPC overhead for UI operations.
- **Positive:** Separate iOS/watchOS targets allow platform-appropriate UI without bloating the macOS app with UIKit dependencies.
- **Negative / tradeoff:** Single-process macOS app means a crash in the recall UI could take down the menu bar agent. Mitigated by SwiftUI's crash isolation (a WindowGroup crash doesn't bring down the app) and by the helpers being separate processes (capture continues even if the UI crashes).
- **Negative / tradeoff:** Shared Swift packages between macOS and iOS require careful platform-conditional compilation (`#if os(macOS)` / `#if os(iOS)`). Standard practice but adds maintenance burden.

## Alternatives considered

1. **Separate apps (Hippocampus Agent + Hippocampus Recall + Hippocampus Setup).** Rejected: three apps = three update paths, three Dock icons, three install steps. Poor UX for a consumer product.
2. **XPC services instead of child processes.** Rejected for v1: XPC adds launchd complexity, requires separate provisioning profiles per XPC service, and complicates the developer build (need to sign each service). Process supervision is simpler and sufficient. XPC may be revisited for sandboxed App Store distribution (Phase 10+).
3. **Catalyst (single binary for Mac + iPad).** Rejected: Catalyst apps on Mac feel like iPad apps. Native SwiftUI with separate targets produces a better platform-native experience on each device.

## References

- **PR #90** — Hippocampus.app menu-bar shell (StatusBarApp pattern, helper supervision).
- **PR #88** — onboarding scaffold (WindowGroup("onboarding")).
- **PR #112** — recall UI v2 (WindowGroup("recall")).
- **PR #125** — onboarding 5-step flow.
- **PR #99** — Sparkle + LoginItems (single-app update path).
- **PR #97, #114** — DMG installer + codesigning (single bundle signing).
- **ADR-0007** — separate signed helper process (MCICaptureHelper architecture).
- **ADR-0023** — multi-device sync (iOS/watchOS data source = CloudKit personal sync).
