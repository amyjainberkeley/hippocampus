# Task 7 Report: Native Light Recall Experience And New Icon

Status: implemented and committed in this worktree.

Commit: cfb7c06

## Scope

- Implemented the approved adaptive palette and semantic token surface.
- Replaced negative font tracking with zero letter spacing for every `MCIFontRole`.
- Replaced the forced-dark root `TabView` with a hideable `NavigationSplitView` workspace shell.
- Added primary destinations: Now, Search, Timeline, Episodes, Briefs.
- Moved utility destinations below the primary workflow: Sources, Privacy, Settings.
- Preserved existing Search, Timeline, Episodes, Brief, Privacy, and Settings view models.
- Left `apps/recall-ui/Sources/RecallUI/TimelineStripView.swift` untouched.

## Files

- `assets/branding/AppIcon-template.svg`
- `assets/branding/AppIcon.svg`
- `assets/branding/AppIcon.iconset/*`
- `assets/branding/AppIcon.icns`
- `assets/branding/colors.json`
- `apps/recall-ui/Sources/RecallUIKit/DesignSystem/MCIDesignSystem.swift`
- `apps/recall-ui/Sources/RecallUI/BrandTheme.swift`
- `apps/recall-ui/Sources/RecallUI/MCIRecallApp.swift`
- `apps/recall-ui/Sources/RecallUI/MemoryWorkspaceView.swift`
- `apps/recall-ui/Sources/RecallUI/SearchView.swift`
- `apps/recall-ui/Sources/RecallUI/EpisodesView.swift`
- `apps/recall-ui/Sources/RecallUI/BriefView.swift`
- `apps/recall-ui/Tests/RecallUIKitTests/MCIDesignSystemTests.swift`
- `apps/recall-ui/Tests/RecallUIKitTests/MemoryWorkspaceTests.swift`

## Tests And Verification

- RED attempted:
  - `swift test --package-path apps/recall-ui --filter 'MCIDesignSystemTests|MemoryWorkspaceTests'`
  - Result: blocked before test compilation by SwiftPM manifest link failure in the selected CommandLineTools toolchain:
    `Undefined symbols for architecture arm64: PackageDescription.Package.__allocating_init(...)`.
- Toolchain cross-check:
  - `swift test --package-path apps/onboarding --filter OnboardingCopyTests`
  - Result: same manifest link failure, confirming the blocker is not specific to Task 7.
- FFI precondition:
  - `cargo build -p mci-brain-ffi`
  - Result: passed.
- Source typechecks:
  - `swiftc -typecheck ... Sources/RecallUIKit/*.swift`
  - Result: passed with pre-existing Swift 6 warnings in `ActionPanelCore.swift`, `QueryPersistence.swift`, and `GlobalHotkeyManager.swift`.
  - Temporary `RecallUIKit` module plus `swiftc -typecheck ... Sources/RecallUI/*.swift`
  - Result: passed with the same pre-existing warnings plus existing ActionPanel extension warnings.
- Syntax parse:
  - `swiftc -parse` over all changed Swift files and new tests
  - Result: passed.
- Asset validation:
  - `node -e "JSON.parse(... colors.json ...)"`
  - Result: passed.
  - `xmllint --noout assets/branding/AppIcon.svg assets/branding/AppIcon-template.svg`
  - Result: passed.
  - `rg '#7AFFC1|#3AFDC8|face|brain|squiggle' assets/branding/AppIcon.svg assets/branding/AppIcon-template.svg`
  - Result: no matches.
  - `sips -g pixelWidth -g pixelHeight` on representative iconset sizes
  - Result: 16x16, 32x32, and 1024x1024 sizes confirmed.
  - `file assets/branding/AppIcon.icns`
  - Result: valid Mac OS X icon, `ic12` type.
- Scope guard:
  - `git diff -- apps/recall-ui/Sources/RecallUI/TimelineStripView.swift`
  - Result: no diff.

## Render Evidence

- Canonical generated icon evidence:
  - `assets/branding/AppIcon.iconset/icon_16x16.png` inspected visually; the layered mark remains legible at 16px.
  - `assets/branding/AppIcon.iconset/icon_512x512@2x.png` inspected visually; neutral layered memory mark on a light dimensional base.
- UI screenshots at 1440x900, 1024x700, and 760x520 were not captured because `swift build` / `swift test` cannot start under the current SwiftPM manifest-linking failure. Direct source typechecks were used instead.

## Decisions

- Kept the old `Color.brandMint` API as an adaptive bridge to cobalt action tokens, avoiding a broad view rewrite while removing the neon mint visual.
- Added `MCI.Workspace` descriptors in `RecallUIKit` so workspace structure is unit-testable without changing the package manifest.
- Mapped old `RecallTab.timelineStrip` deep links to the standard Timeline destination for this narrowed pass, because `TimelineStripView.swift` is owned by another task.
- Kept Chat out of the primary shell and command list because it is a placeholder surface.
- Used native `NavigationSplitView`, `.sidebar` list style, SF Symbols, standard buttons, materials in navigation/control areas, hover states, keyboard shortcuts, reduce-motion handling in shimmer, and reduce-transparency fallbacks.

## Risks

- Full SwiftPM tests and app screenshots remain blocked by the local CommandLineTools `PackageDescription` link failure.
- The new Sources utility surface is intentionally aggregate/source-list only; deeper source drill-down can be expanded once the source-specific UI contract is finalized.
- Existing unrelated Swift 6 warnings remain in pre-existing ActionPanel/QueryPersistence/GlobalHotkey code.
