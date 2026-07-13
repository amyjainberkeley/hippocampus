# ADR-0036 — V2-P13 Timeline UI scaffold (Rewind-style visual timeline strip)

- Status: **Proposed** (2026-07-13; awaits CEO ratification)
- Owners: **Director-Brain** (proposal + this scaffold PR); **CTO** (Phase D sequencing); **CSO** (veto-gate on the new FFI read surface — see §4)
- Reviewers: CTO (adapter-tier discipline, downsample budget); CSO (read-only invariant carry-through); CEO (ratification)
- Phase: **Phase D — V2-P13** (Rewind-style visual timeline strip)
- **Protected-set: NO for the Swift + view-model work.** The new FFI entry point `mci_brain_ffi_timeline_events` is added to the FFI's read-only allowlist (`tests/readonly_invariant.rs::ffi_exports_no_mutating_surface_beyond_allowlist`) — a §5 protected-set surface. CSO reviews that no writer path is added.
- **Launch-blocker: NO for v1.0.** Timeline strip is Phase D. Scaffold ships now so the shape is locked; live rendering awaits V2-P1 M4 lift + real captures. The `MCIEmptyState.noTimelineEvents()` copy is the load-bearing UX until then.
- **Relationship:** Complements the existing flat `TimelineView` (⌘2, `recentEvents`-backed chronological list). The strip (⌘8) is the *visual* Rewind-style companion; the two coexist during Phase D scaffold and may collapse into one tab in Phase D full impl (cycle 8.55+). See §5.

## Context

V2-P13 asks for a Rewind-style visual timeline: a horizontally-scrolling strip of capture cards with thumbnails + time markers, so a user can *see* their day at a glance rather than scanning a list of text rows. The recall-ui audit (`docs/research/2026-07-12-recall-ui-audit.md` §G9) flagged the existing `TimelineView` as "polished but thin — a flat list, no visual grouping, no keyframe strip." Phase D fills that gap.

Full Phase D impl is cycle 8.55+ scope — this ADR scopes the **scaffold** that ships now so:

1. The shape (⌘8 tab, view-model, resolution toggle, empty state, event-card layout, click-to-DetailPane handoff) is locked before we accumulate real captures.
2. The FFI read surface (`mci_brain_ffi_timeline_events`) is added under a bounded, tested contract so live rendering post-V2-P1-M4 is a wiring change, not a new design.
3. Empty-state UX is honest: "No captures yet. Screen recording will start once V2-P1 lands + you grant permissions" — no synthetic teaser rows (would violate the "canned data is a trust-boundary violation" discipline that the P3.9c privacy-moments deferral established).

Prior ADRs number through 0035. This is ADR-0036.

## Decision

1. **New FFI read entry point `mci_brain_ffi_timeline_events`.** Returns a `TimelineEventJson` array — a lightweight subset of `HitJson` (event id, ts, app bundle, short snippet, thumbnail path). Read-only, uses the same `SqlCipherBrainStore::recent_events` primitive powering the flat `TimelineView`. Added to the FFI read-tier allowlist (surface size pinned at 15 in `readonly_invariant.rs`).

2. **Input contract: bounded.** `TimelineQueryJson` carries `start_ts_us`, `end_ts_us`, and an optional `resolution` string. The FFI:
   - Rejects `start_ts_us > end_ts_us` (400-equivalent — returns null + last-error).
   - Rejects ranges wider than **90 days** (`TIMELINE_MAX_RANGE_US`).
   - Caps the per-call row budget at **1000 rows** (`TIMELINE_MAX_EVENTS`) via bucketed downsampling.
   - Snippet cap: **80 chars** per row (vs. 280 for `HitJson`) — the strip renders one card per ~40 px, so the JSON payload stays well inside a single-frame budget even at max density.

3. **Downsampling strategy.** When the raw event count exceeds `TIMELINE_MAX_EVENTS`, the FFI bucketizes by time and keeps one representative per bucket. Bucket width = `max(range_us / MAX_EVENTS, 1 minute)`; ranges ≤ 24 h floor to a 1-minute bucket for a stable "one card per minute" feel. Within each bucket the chronologically-earliest event wins (simple, deterministic, cheap). A follow-on cycle may pick "densest event" or "middle-of-bucket keyframe" strategies — the wire shape is identical.

4. **Scroll performance budget.** SwiftUI `ScrollView(.horizontal)` with `LazyHStack` renders at most ~50 visible cards at once on a 4K display (96 px wide × ~50 slots). With `TIMELINE_MAX_EVENTS = 1000` in memory, the strip has a comfortable ~20× overprovision headroom. Thumbnail decoding is deferred — cards render an SF Symbol placeholder tinted with the accent color in the scaffold; the `HitThumbnail`-style blur pipeline lands with Phase D full impl.

5. **Thumbnail load path.** `TimelineEvent.thumbnailPath` carries the same absolute path that `Hit.thumbnailPath` carries (`<blob_dir>/<sha256>.bin`, per KeyframeBlobWriter, ADR-0016 §4.8). Post-cascade-only by construction — a `.suppress`-decided event has no keyframe hex in the store, so surfacing this path cannot leak a redacted keyframe. **In the scaffold** cards render a placeholder icon; wiring the blob-decode pipeline is Phase D full impl.

6. **New `RecallTab.timelineStrip` (⌘8).** Distinct from the existing `RecallTab.timeline` (⌘2). Deep-link alias: `?tab=timeline-strip` / `?tab=strip`. The tabs coexist during Phase D scaffold; consolidation is a Phase-D-full-impl decision informed by dogfood data.

7. **Default protocol impl on `BrainReader.timelineEvents`.** Projects `recentEvents(limit: 1000)` into `TimelineEvent`s and filters by the window. Lets existing test-scope conformers work without modification; the production `FFIBrainReader` overrides with the dedicated FFI-backed path so a real store gets proper downsampling + hard cap.

8. **Empty state via `MCIEmptyState.noTimelineEvents()`.** Reuses the existing canonical component (cycle 8.49 polished-empty-state work). No new empty-state artwork in this scaffold; the shared copy stays consistent across the flat timeline (⌘2) and the strip (⌘8).

## Alternatives considered

- **(A) Skip the FFI addition; project `recentEvents` in Swift.** Rejected. Would offload downsampling to the Swift side, meaning every zoom/pan pulls up to 10k rows across the FFI boundary and re-buckets them in Swift. Poor perf ceiling; obfuscates the wire-level cap; harder to reason about "what does the strip actually ask for."
- **(B) Add `events_in_range` to `SqlCipherBrainStore` (protected-set).** Considered. Would push the range predicate into SQL (`WHERE ts_us BETWEEN ? AND ?`) — cleaner + faster + O(range_events) not O(recent_events_hard_cap). Deferred: the scaffold's row budget (10k `recent_events` filtered in-memory) is bounded and correct; a protected-set change on `sqlcipher_brain_store.rs` requires CSO sign-off on the SQL and its migration story. Track as a follow-on optimization once dogfood data shows the scan is a real bottleneck. Amendment path (below) covers the migration.
- **(C) Merge the strip into the existing `TimelineView` (⌘2) tab.** Considered. Would avoid the tab-count bump. Rejected for the scaffold: the two views have fundamentally different interaction models (list nav vs. horizontal scrub); shipping side-by-side lets dogfood tell us which wins before consolidation. If the strip proves out, Phase D full impl retires the flat list — reversible, one-tab change.
- **(D) Pinch-to-zoom gestures.** Considered. Rejected for the scaffold — meaningful gesture handling on macOS pushes the LOC budget over the 500 cap. Buttons (segmented picker for Day / Week / Month) + keyboard shortcuts (⌘+ / ⌘−) suffice and are more discoverable. Trackpad gestures land in Phase D full impl.

## Consequences

### Positive

- **Ships the shape now.** Live rendering post-V2-P1-M4 is a wiring change, not a design push.
- **Bounded FFI contract.** 90-day / 1000-row / 80-char caps give the client + FFI a shared, testable budget.
- **Read-only-by-construction preserved.** New surface is on the allowlist; no new writer path.
- **Reuses `DetailPaneView`.** Click a card → resolves through `fetchEventsByIds` → hands off to the existing detail component. No new detail UI to maintain.
- **Default protocol impl** means existing test-scope BrainReader conformers work unchanged.

### Negative

- **Two timeline tabs coexist.** ⌘2 (flat list) and ⌘8 (strip) share the recent-events surface until Phase D full impl decides which wins. Slight cognitive load for early dogfooders.
- **Downsample loses events.** By definition — 1000 rows over a 30-day window is one representative per ~43 minutes. Acceptable for a scaffold "at-a-glance" view; the search tab is the recall path when a specific event matters.
- **Thumbnail placeholder is visually thin** vs. real keyframe-plus-blur. Cards feel like text bubbles more than "your Mac's memory" until Phase D full impl wires the decode pipeline.
- **Bounded-input rejection is surface for a bad UX** if the view accidentally requests > 90 days. Guarded: `TimelineResolution.day.defaultWindowUs = 30 days` — the view can never trip the FFI cap through normal use. A regression that widened `defaultWindowUs` would fail the FFI's window check + surface as a load error, not a silent stall.

## Amendment path

If dogfood reveals the `recent_events(10_000)` → in-memory filter is a bottleneck on a 6-month corpus, the follow-on is Alternative B: add `events_in_range` to `SqlCipherBrainStore` (protected-set; CSO sign-off), push the range predicate into SQL, and have `mci_brain_ffi_timeline_events` route through the new method. Zero wire-shape change; drop-in swap on the Rust side. Amendment lands as ADR-0036 v2.

If the two-tab (⌘2 + ⌘8) split proves confusing in dogfood, Phase D full impl retires the flat list and promotes the strip to `RecallTab.timeline`. Reversible; one tab-enum edit + view swap.

## References

- `apps/recall-ui/Sources/RecallUI/TimelineStripView.swift` — the ⌘8 view scaffold.
- `apps/recall-ui/Sources/RecallUIKit/BrainReader.swift` — `TimelineEvent`, `TimelineResolution`, protocol method + default impl.
- `apps/recall-ui/Sources/RecallUIKit/FFIBrainReader.swift` — production override that routes to the FFI.
- `adapters/macos/mci-brain-ffi/src/lib.rs` — `mci_brain_ffi_timeline_events` + downsample helpers.
- `adapters/macos/mci-brain-ffi/tests/readonly_invariant.rs` — read-tier allowlist bumped to 15.
- `docs/research/2026-07-12-recall-ui-audit.md` §G9 — the timeline-grouping gap this scaffold addresses.
- `docs/decisions/0016-brain-schema-and-privacy-model.md` §4.3, §4.8 — read-only + keyframe-post-cascade invariants (carried through).
- `docs/decisions/0017-privacy-moments-cascade.md` §5 — read-only-by-construction seam.
- `docs/decisions/0035-v2-p12-chat-surface-anylanguagemodel.md` — most recent prior ADR (cadence check).
