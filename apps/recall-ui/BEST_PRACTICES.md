# apps/recall-ui/BEST_PRACTICES.md

Subtree invariants for the recall SwiftUI app. Read the top-level
`BEST_PRACTICES.md` first; this file adds recall-UI contracts
derived from PR #84 (design system) and PR #90 (empty states).

## Purpose

RecallUI is a read-only consumer of the Phase-3 brain and the
primary user-facing query surface. Rules below encode the design-
system discipline, empty-state consistency, and the ⌘K Action
Panel registration pattern that PRs #84 / #90 established.

## Rules

1. **Read-only through the FFI.** All brain access goes through
   `../../adapters/macos/mci-brain-ffi/`, which opens the store
   read-only. Do NOT link a write path, do NOT open the SQLite
   file directly, do NOT add a "feedback write" without the FFI
   allow-list update.

2. **MCIDesignSystem tokens (PR #84).** All colors, typography,
   spacing, and radii MUST resolve through `MCIDesignSystem`. Ad-
   hoc `Color(red:...)`, `.font(.system(size: 13))`, and inline
   spacing constants are banned in shipping views. New tokens go
   into the design system, not into a view file.

3. **Empty-state consistency (PR #90).** Every list, grid, and
   result surface MUST show one of the canonical empty states
   (no-data, no-results, permission-denied, loading, error). Never
   render a blank container. Empty-state copy lives in a shared
   module, not inline per view.

4. **⌘K Action Panel registration pattern.** New actions register
   through the Action Panel registry, NOT via ad-hoc menu items.
   This preserves discoverability and the keyboard-first posture
   RecallUI commits to.

5. **View models are UI-shaped, not brain-shaped.** RecallUIKit
   view models translate FFI results into view state; do NOT
   expose raw FFI structs to SwiftUI views. Brain schema drift
   should stop at the view-model boundary.

6. **No blocking calls on the main actor.** FFI calls MUST run on
   a background actor and marshal results back. A synchronous
   query on the main thread freezes the recall UX and violates
   the footprint SLO on burst.

7. **Ranking + retrieval live in `../../core/brain/`.** RecallUI
   composes queries and displays results; it does NOT re-rank,
   re-score, or filter beyond user-visible controls. Retrieval
   changes belong in the brain crate.

## Common mistakes

- Hardcoding a color like `Color(red: 0.1, green: 0.1, blue: 0.1)`
  in a view — bypasses MCIDesignSystem. Add a token.
- Showing a blank `List` on empty results instead of the empty-
  state view — regression risk called out in PR #90.
- Registering a menu action outside the Action Panel registry —
  breaks ⌘K discovery.
- Using `.task { let x = ffi_call() }` on the main actor without
  offloading — janks the UI.

## Reference chain

- `../../BEST_PRACTICES.md` — MCI-wide invariants (root).
- `./README.md` — target map and edit rules.
- `../../adapters/macos/mci-brain-ffi/BEST_PRACTICES.md` — FFI wall.
- `../../docs/decisions/0016-phase-3-ocr-brain.md`,
  `0035-v2-p12-chat-surface-anylanguagemodel.md`.
- `../../docs/research/2026-07-12-recall-ui-audit.md`.
