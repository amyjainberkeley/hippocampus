# ADR-0037 — Deep-hook plugins for Calendar / Notes / Reminders (Phase D scaffold)

- Status: **Proposed** (2026-07-13; Director-Recording seat draft; CEO ratification on Phase D wire-up PR merge in cycle 8.60+)
- Owners: **Director-Recording** (scaffold + wire-up implementer); **CSO** (binding veto on the wire-up PR — new Automation TCC per-target surfaces + AppleScript automation of Notes); **Director-Brain** (consumer of plugin-emitted events on the Tier2 pipeline).
- Reviewers: CEO (ratifies on wire-up merge); Director-Context (V2-P10 onboarding UI extension); CRS Telemetry-Gap analyst (per-plugin `plugin_redactions_count` extension).
- Phase: **Phase D** (V2-P13 timeline + deep-hook Calendar/Notes/Reminders + V2-P9 keystroke+clipboard). Scaffold lands cycle 8.5x; wire-up lands cycle 8.60+.
- **Protected-set: yes** for the wire-up PR (AGENT_PROTOCOL §5 — three NEW ingest paths that bypass the pixel-time SCStream cascade entirely). This scaffold PR touches Track A doc + Track B non-protected scaffold code only (no reads wired; no cascade-equivalent authored; no brain-ingest).
- **Launch-blocker: no** for v1.0 (per `docs/research/2026-07-12-state-of-product-baseline.md` — v1.5-eligible).
- **Relationship:** extends ADR-0032 §3(f) with three new plugin sources (Calendar / Notes / Reminders), each of which will get its own §3(f) analogue in the wire-up PR. Does NOT amend ADR-0030 §3, ADR-0013 §1–§7, or ADR-0031 §1 — those govern the OCR path and remain unchanged.

## Context

### FORK 8 = A load-bearing sequencing

`docs/AGENT_QUESTIONS.md` FORK 8 is ratified as **A: Tier2 entity-extraction via V2-P4 + V2-P5 + V2-P6 + episode_edges**. That pipeline needs cross-app entity resolution — a name typed in Notes, a person invited on a Calendar event, a phone number pasted in a Reminder, and a Message from that person must all resolve to the same entity so the AliasResolver + `episode_edges` writer can build a cross-app dot-connection graph.

Today MCI has deep-hook read paths for two of the five load-bearing sources:

| Source | Deep-hook crate | ADR | Cascade-equivalent |
|---|---|---|---|
| Messages.app | `mci-messages-reader` (V2-P7) | ADR-0032 §2 | `core/brain/src/redaction/messages_plugin.rs` |
| Mail.app | `mci-mail-reader` (V2-P8a) + V2-P8b | ADR-0032 + ADR-0030 §3(c)(ii) | V2-P8b (`mail_plugin.rs`) |
| **Calendar.app** | **this ADR — scaffold** | **this ADR §4** | **deferred to wire-up PR** |
| **Notes.app** | **this ADR — scaffold** | **this ADR §4** | **deferred to wire-up PR** |
| **Reminders.app** | **this ADR — scaffold** | **this ADR §4** | **deferred to wire-up PR** |

### Why scaffold now, wire later

Three independent gates hold up the wire-up:

1. **CSO veto-gate on Automation TCC per-target surfaces.** Each of Calendar / Reminders / Notes needs a distinct Automation TCC grant (macOS 13+). The user-facing surface (a per-app permission card in V2-P10 onboarding + a deep-link into System Settings → Privacy & Security → the right pane) has not been designed yet, and CSO must sign off on the per-target grant flow before AppleScript / EventKit calls ship in a signed binary.
2. **AppleScript engine choice for Notes.** Notes.app has no public framework; the only supported path is AppleScript. The wire-up must pick between spawning `osascript` (simple, subprocess overhead, no long-lived state) and linking `objc2-osakit` (in-process, more capable, larger dep surface). This is a per-plugin cascade-equivalent design decision that belongs on the wire-up PR, not the scaffold.
3. **Per-plugin cascade-equivalent under ADR-0032 §3(f).** Each source needs its own decision table (analogous to the V2-P7 Messages §3(f) table). Calendar events with private-event flags, Notes in a "Passwords" folder, Reminders synced from a shared list — each carries a distinct sensitive-content threat model. The tables live in the wire-up PR alongside the cascade-equivalent modules in `core/brain/src/redaction/`.

Scaffolding now buys two things:

- **Locks the wire-format shape.** Consumers on the Tier2 pipeline (Director-Brain's V2-P4 regex extractor + V2-P5 Qwen NER + V2-P6 AliasResolver + `episode_edges` writer) can pattern-match against `CalendarEvent` / `Note` / `Reminder` today. When the wire-up lands, only the reader guts change — the consumer code stays put.
- **Locks the workspace membership.** `cargo build --workspace` includes the three new crates; drift between scaffold and wire-up cannot silently accumulate.

## Decision

### 1. Ship three scaffold crates in Phase D

- `adapters/macos/mci-calendar-reader/`
- `adapters/macos/mci-notes-reader/`
- `adapters/macos/mci-reminders-reader/`

Each crate:

- Gates its lib body on `#![cfg(target_os = "macos")]` (mirrors `mci-messages-reader` / `mci-mail-reader` — Linux CI `cargo build --workspace` stays clean).
- Publishes a `read_events_since(since_unix) -> Result<Vec<T>, ReaderError>` entry point that returns `Ok(Vec::new())` unconditionally.
- Publishes a `watch_*() -> Result<InboxWatcher, ReaderError>` entry point that returns a zero-sized watcher that never emits.
- Publishes a wire-format struct (`CalendarEvent` / `Note` / `Reminder`) with the fields §4 documents.
- Publishes a `*ReaderError` enum carrying an `AccessDenied` variant + a `NotYetWired` variant. The wire-up PR extends this with EventKit / AppleScript failure variants.
- Ships integration tests under `tests/integration.rs` that lock the empty-vec + no-panic behaviour + wire-format constructibility.

### 2. macOS framework choice per source

| Source | Framework | Auth-status API | TCC per-target |
|---|---|---|---|
| Calendar | **EventKit** (`EKEventStore`, `EKEvent`) | `EKEventStore.requestFullAccessToEvents` (macOS 14+) | Automation → Calendars |
| Reminders | **EventKit** (`EKEventStore`, `EKReminder`) | `EKEventStore.requestFullAccessToReminders` (macOS 14+) | Automation → Reminders |
| Notes | **AppleScript** (`com.apple.Notes` scripting suite) via `osascript` or `objc2-osakit` (wire-up decides) | `AEDeterminePermissionToAutomateTarget` | Automation → Notes |

Notes explicitly does NOT use `NoteStore.sqlite` under `~/Group Containers/group.com.apple.notes/`: the schema is undocumented, cross-encrypted with a per-account Keychain key, and Apple can break it at any point release. AppleScript is the only supported path.

### 3. CSO gates required before wire-up PR merges

The wire-up PR (cycle 8.60+) MUST pass CSO review on all of the following before merge:

1. **Info.plist strings.** Add `NSCalendarsFullAccessUsageDescription`, `NSRemindersFullAccessUsageDescription`, and (for Notes) confirm the existing `NSAppleEventsUsageDescription` copy covers the Notes automation use case explicitly.
2. **Per-target Automation TCC probe.** Land a `AEDeterminePermissionToAutomateTarget`-based status probe for Notes (mirrors the browser AppleScript probe already shipped in Phase 2 context join). Land an `EKAuthorizationStatus` probe for Calendar + Reminders.
3. **Per-plugin cascade-equivalents.** Author `core/brain/src/redaction/calendar_plugin.rs`, `notes_plugin.rs`, `reminders_plugin.rs` — each following the ADR-0032 §3(f) decision-table pattern. First-match-wins predicates + a `drop_reason` enum + a `fired_rules: Vec<&'static str>` telemetry surface. CSO signs off on each table.
4. **Default-OFF master switch.** Each config type ships with `plugin_enabled = false`. The V2-P10 onboarding is the only surface that flips it on, and only after the corresponding TCC grant is confirmed present.
5. **AppleScript sandbox posture for Notes.** If the wire-up chooses `osascript`, CSO must approve the subprocess argv shape (avoid injection risk if any user-controlled string reaches the script body — none should, but the review is binding). If the wire-up chooses `objc2-osakit`, CSO must approve the new dep + its transitive graph.
6. **Onboarding UI copy.** The permission card wording for each of Calendar / Notes / Reminders must pass the same review as the existing Messages / Mail cards.

### 4. Wire-format shape (stable now, wired later)

The types below are the contract downstream code (Tier2 pipeline) targets. The wire-up PR MAY add fields but MUST NOT remove or rename any listed field without a follow-up ADR.

#### `CalendarEvent`

```rust
pub struct CalendarEvent {
    pub event_id: String,            // EKEvent.eventIdentifier
    pub calendar_id: String,         // EKEvent.calendar.calendarIdentifier
    pub title: Option<String>,       // EKEvent.title
    pub notes: Option<String>,       // EKEvent.notes — Tier2 target
    pub location: Option<String>,    // EKEvent.location
    pub start_unix: i64,             // EKEvent.startDate → unix-seconds
    pub end_unix: i64,               // EKEvent.endDate → unix-seconds
    pub participants: Vec<ParticipantHandle>, // resolved EKParticipant.URL set
    pub source: EventSource,         // EventKit
}
```

#### `Note`

```rust
pub struct Note {
    pub note_id: String,             // AppleScript `id` (CoreData URI)
    pub folder: NoteFolder,          // per-folder allow/deny key
    pub title: Option<String>,       // AppleScript `name`
    pub body_plain: Option<String>,  // AppleScript `plaintext` (not `body`)
    pub modification_unix: i64,      // AppleScript `modification date`
}
```

#### `Reminder`

```rust
pub struct Reminder {
    pub reminder_id: String,         // EKReminder.calendarItemIdentifier
    pub list: ReminderList,          // per-list allow/deny key
    pub title: Option<String>,       // EKReminder.title
    pub notes: Option<String>,       // EKReminder.notes — Tier2 target
    pub due_unix: Option<i64>,       // EKReminder.dueDateComponents
    pub completion_unix: Option<i64>,// EKReminder.completionDate
    pub is_completed: bool,          // EKReminder.isCompleted
}
```

### 5. Onboarding UI extension (this PR)

The V2-P10 allowlist editor (`apps/onboarding/Sources/OnboardingKit/AllowlistEditorViewModel.swift`) is extended to include Calendar / Notes / Reminders in the `deepHookableBundles` set, but each row's deep-hook toggle is **disabled and OFF by default** with a "Coming soon — deep-hook wire-up deferred to a later release" tooltip. Users can still flip capture-only on for the three apps (that path exists today — capture-only means the frontmost-window OCR path); only the deep-hook toggle is gated.

This is a UI-only change; no runtime path today reads any of the three sources. The scaffold's `read_events_since` returning empty vec makes it impossible to accidentally ingest even if a downstream mistake wires it in.

### 6. Non-goals of this ADR

- Does NOT enable ingest. Master switch remains at `plugin_enabled = false` conceptually (there is no wire; nothing to switch).
- Does NOT widen the cascade allowlist for `com.apple.iCal` / `com.apple.Notes` / (any Reminders bundle). Those bundles are already user-addable per V2-P10; the deep-hook is additive when the user opts in, not a relaxation.
- Does NOT ship a CLI binary per crate. The wire-up PR adds `calendar-reader` / `notes-reader` / `reminders-reader` CLIs mirroring `messages-reader` / `mail-reader`.
- Does NOT touch `messages_plugin.rs` / `mail_plugin.rs` or their tests. Wired adapters remain unchanged.

## Consequences

### Positive

- Locks the wire-format shape early; Tier2 pipeline can develop against the types without waiting on TCC review.
- Keeps `cargo build --workspace` green with the new crates present (Linux CI stays clean via the `cfg(target_os = "macos")` gate).
- Makes the CSO-gated wire-up PR a strict superset: it changes reader guts and adds cascade-equivalents, but does not re-open the workspace / type-surface decision.
- Signals the deferred coverage to users honestly ("Coming soon" tooltip) rather than pretending the toggle is functional.

### Negative

- Three new crate directories to maintain even before wire-up ships. Cost: ~one Cargo manifest audit per crate per release. Amortized against not-lost-context on wire-up.
- Downstream code that pattern-matches on `read_events_since` returning a populated vec today gets an empty vec; the wire-up PR flips that behaviour. Callers must handle "empty" as normal.

### Neutral

- Sets the precedent that other v1.5-eligible sources (Slack DMs via Slack MCP, Linear comments via Linear MCP, etc.) may follow the same scaffold-first / wire-second pattern.

## Status transition

- **Proposed:** on landing of this scaffold PR (cycle 8.5x).
- **Ratified:** on landing of the wire-up PR (cycle 8.60+) after CSO sign-off on §3(1)–(6).
- **Superseded:** if a later ADR consolidates all deep-hook readers into a single trait-object contract (Director-Brain has floated this; not scoped here).
