# Task 7 Report: Native Light Recall Experience And New Icon

Status: implemented, reviewed, and repaired in this worktree.

Initial implementation commit: `cfb7c06`

Review repair: `fix: make Task 7 workspace states source-backed` (the commit containing this report, based on `235107e`; exact SHA is returned in the Task 7 handoff).

## Repair Summary

- Removed the sidebar capture footer because Recall UI has no trustworthy runtime supervisor channel.
- Replaced the Now capture/readiness panel with a `SummaryStats.totalEvents` historical row metric labeled `Stored events`.
- Removed `Ready`, `On record`, and all other live capture claims from the workspace shell.
- Restricted `Recent keyframes` to rows whose `thumbnailPath` is non-nil and nonempty after whitespace trimming; OCR-only rows are excluded.
- Changed the filmstrip unit from invented `sources` to singular/plural `keyframe` counts.
- Centralized Command-1 through Command-8 destination metadata in `MCI.Workspace`; sidebar labels, root key handling, and the custom-names command now consume that map. Command-6 opens Sources and Command-8 opens Settings.
- Changed the Brief view construction from `hasFullDayCapture: true` to `false`; absent coverage now renders as unconfirmed rather than claiming capture has not started.
- Replaced speculative brief and search copy with statements about saved briefs and stored memory.
- Strengthened only the neutral icon outer tile from `#F6F8FB` to `#DDE4EC`, then regenerated every iconset size and `AppIcon.icns`.
- Left `TimelineStripView.swift` and the shared keyframe decoder untouched for Task 4.
- Left concurrent Task 2/3 worktree changes untouched and unstaged.

## Scope

- Preserved the approved adaptive semantic palette, zero letter spacing, native `NavigationSplitView`, and existing Search, Timeline, Episodes, Brief, Privacy, and Settings view models from `cfb7c06`.
- Kept Now, Search, Timeline, Episodes, and Briefs as primary destinations.
- Kept Sources, Privacy, and Settings as secondary destinations.
- Kept Recall UI read-only and made every new metric historical/source-backed.

## Repair Files

- `assets/branding/AppIcon.svg`
- `assets/branding/AppIcon.iconset/*`
- `assets/branding/AppIcon.icns`
- `apps/recall-ui/Sources/RecallUIKit/DesignSystem/MCIDesignSystem.swift`
- `apps/recall-ui/Sources/RecallUI/MCIRecallApp.swift`
- `apps/recall-ui/Sources/RecallUI/MemoryWorkspaceView.swift`
- `apps/recall-ui/Sources/RecallUI/SearchView.swift`
- `apps/recall-ui/Sources/RecallUI/BriefView.swift`
- `apps/recall-ui/Tests/RecallUIKitTests/MemoryWorkspaceTests.swift`
- `.superpowers/sdd/2026-09-01-hippocampus-memory-layer/task-7-report.md`

## TDD Evidence

- RED test additions cover historical-only Now metrics, nonempty-thumbnail keyframe filtering, keyframe count units, and the canonical shortcut map.
- `swift test --package-path apps/recall-ui --filter MemoryWorkspaceTests` remains blocked before test compilation by the selected CommandLineTools manifest linker:
  `Undefined symbols for architecture arm64: PackageDescription.Package.__allocating_init(...)`.
- A direct pre-implementation contract typecheck failed for the expected reason: `MCI.Workspace` did not yet contain `historicalEventMetric`, `recentKeyframes`, `keyframeCountLabel`, `destination(forKeyboardShortcut:)`, or `Destination.keyboardShortcut`.
- After implementation, a direct executable behavior probe passed all assertions for the 42-row historical metric, nil/empty/whitespace thumbnail rejection, singular/plural keyframe labels, Command-6 Sources, and Command-8 Settings.

## Exact Verification

- `swiftc -parse` over all repaired Swift production and test files: passed.
- Direct `swiftc` RecallUIKit module typecheck at `arm64-apple-macosx14.0`: passed; only pre-existing ActionPanel, QueryPersistence, and GlobalHotkey warnings remain.
- Direct `swiftc -typecheck` over every RecallUI source file at `arm64-apple-macosx14.0`: passed; only pre-existing ActionPanel isolation warnings remain.
- Direct Task 7 workspace behavior executable: passed with `Task 7 workspace behavior probe passed`.
- `xmllint --noout assets/branding/AppIcon.svg assets/branding/AppIcon-template.svg`: passed.
- `colors.json` JSON parse: passed.
- Forbidden icon-source scan for neon mint, face, brain, and squiggle terms: no matches.
- All ten iconset PNGs matched their required square dimensions from 16 through 1024 pixels.
- `iconutil` successfully expanded the regenerated `AppIcon.icns`; `file` reports `Mac OS X icon, 996859 bytes, "ic12" type`.
- Neutral outer-tile source contrast against white increased to `1.28:1`; the regenerated 16x16 and 32x32 PNGs were visually inspected and retain the rounded base plus dark layered mark.
- Task 7 path-scoped `git diff --check`: passed.
- Forbidden regression scan found no `hasFullDayCapture: true`, `hits.count` source label, OCR fallback in the keyframe filter, hardcoded `⌘6` custom-names shortcut, capture footer, capture-value derivation, or `showsCaptureStatus` metadata.
- `git diff -- apps/recall-ui/Sources/RecallUI/TimelineStripView.swift`: empty.
- No push, publish, signing, amend, reset, or rebase was performed.

## Truthfulness Audit

- Filmstrip `Loading` is controlled by `isLoading`; `Unavailable` and `Memory unavailable` occur only after a read throws; the keyframe count is the filtered row count.
- Now `Stored events` comes from `SummaryStats.totalEvents`; `Recent events` comes from the returned recent-event rows; Brief values come from `latestBrief()`.
- Now `Loading`, `Unavailable`, and `Unknown` correspond respectively to an active load, a caught read failure, and absence of a summary without an error.
- Sources empty/error states come from the observed-app row result or a caught read failure.
- Brief model availability is backed by the existing on-disk model probe. Capture coverage is explicitly unconfirmed when the optional coverage value is absent.
- `current` references left in `MCIRecallApp.swift` and `BriefView.swift` refer only to macOS appearance, app version, locale, or time zone.
- No Recall UI copy claims the supervisor is currently capturing, ready, paused, or on record.

## Render Evidence

- `assets/branding/AppIcon.iconset/icon_16x16.png`: inspected at original resolution after regeneration; the neutral tile boundary is visible and the dark layered memory mark remains recognizable.
- `assets/branding/AppIcon.iconset/icon_32x32.png`: inspected at original resolution; overlapping panes and the front memory lines remain distinct.
- App screenshots remain unavailable because SwiftPM cannot compile the package manifest under the installed CommandLineTools toolchain. Direct source typechecks provide compiler coverage but not runtime layout evidence.

## Risks

- Recall UI intentionally shows no live capture status until a trustworthy runtime supervisor channel is designed and injected.
- SwiftPM XCTest execution remains unavailable in this machine configuration even though direct source typechecks and the focused executable behavior probe pass.
- Existing Swift 6 isolation/conformance warnings are outside Task 7 and were not changed.
