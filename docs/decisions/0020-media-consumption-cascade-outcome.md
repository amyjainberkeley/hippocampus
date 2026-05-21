# ADR-0020 — `.mediaConsumption` Cascade Outcome + Bibliographic Events

- Status: Accepted (2026-05-21; ratifies the Phase 2.x design fork surfaced in AGENT_QUESTIONS PR #55, answered by CEO 2026-05-20 afternoon).
- Owners: **Director-Recording** (cascade decision impl in Swift helper) + **Director-Brain** (synthetic-text event writer + retrieval integration)
- Reviewers: CSO (protected-set — new cascade path carries `windowTitle` to disk); CTO (sequencing + cross-Director arbitration); CEO (ratification)
- Phase: 3.x (lands AFTER Phase 2 P2.5 wiring + Phase 3 P3.6 wire bump are on `main`; both are prerequisites because the path needs real `appBundleId` + `windowTitle` + `url` reaching the cascade)
- **Protected-set: yes** (AGENT_PROTOCOL §5). Justification: introduces a new cascade path that carries `windowTitle` and `url` to the brain store. Although `.mediaConsumption` captures LESS than `.allow` (no pixel keyframe, no OCR), it IS a new explicit decision the cascade emits, and the stored text is user content.

## Context

When a user watches a streaming app (Apple TV, Netflix, Disney+, etc.), MCI enters a degenerate steady state: the rendered surface is FairPlay-protected, ScreenCaptureKit delivers a black rectangle, the §2 `PixelGridBlackedRegionProbe` fires, and the cascade emits `.suppress(reason=2)` tombstones every tick. No useful frame ever reaches encode.

This is privacy-correct (ADR-0013 §2 + §7 fail-closed; structurally cannot leak DRM content because Apple does not permit screen-recording of it — CRS research 2026-05-20: Daring Fireball + Apple Developer Forums #63725 + Screenify Studio 2026-04-23).

Three options were considered in AGENT_QUESTIONS (PR #55):

- **A) Do nothing.** Current behavior correct, inside footprint budget by 50×+.
- **B) Pause SCStream when frontmost is a streaming app.** Saves negligible CPU; adds SCStream lifecycle complexity.
- **C) General "media-consumption mode" detection.** Phase 3+ heuristic; too broad for now.

**CEO rejected all three** and reframed: the valuable signal during media consumption is the **title + URL** of what's being watched. Pixels are useless for DRM content. MCI should capture the metadata as a bibliographic event so users can later ask "what movie was that" or "what episode covered X."

## Decision

### 1. New cascade outcome: `.mediaConsumption`

The cascade gains a third explicit outcome alongside `.allow` and `.suppress(reason=N)`:

```
.mediaConsumption(bundleId, windowTitle, url, ts)
```

Behavior when `.mediaConsumption` fires:

- **NO keyframe stored.** Pixels are useless (DRM black) or privacy-conservative.
- **NO OCR run.** Text content is not the goal; bibliographic metadata is.
- **An `events` row is created** with synthesized `text`:
  - With URL: `"Watched: <title> on <appName> (<url>)"`
  - Without URL: `"Watched: <title> on <appName>"`
- **That text is embedded + indexed normally** via the standard chunker → embedder → brain-store pipeline.
- **A content-free `PrivacyTombstone(reason=10 /* mediaConsumption */)` is emitted** on the wire for telemetry counting.
- **The recall UI surfaces these as normal events** ("Watched: <title>") — not as opaque privacy-moment cards. This is bibliographic data, not redacted moments.

### 2. Curated streaming-app list

A curated `streaming-apps.toml` config file (CSO-reviewed, lives alongside `known-safe-apps.toml`):

**Native apps (DRM-only — FairPlay/Widevine; §2 probe will fire):**
- `com.apple.TV` (Apple TV)
- `com.netflix.Netflix` (Netflix)
- `com.disney.disneyplus` (Disney+)
- `com.hulu.plus` (Hulu)
- `com.amazon.aiv.AIVApp` (Prime Video)
- `com.apple.Music` (Apple Music)
- `com.apple.podcasts` (Apple Podcasts)
- `com.apple.iTunes` (iTunes / legacy media)

**Web-only (no DRM — pixels capture normally via `.allow`; URL provides the bibliographic key):**
- YouTube, Vimeo, Twitch — matched by URL pattern via Phase 2 P2.3/P2.4 wiring. Already covered structurally by `.allow` + URL capture; `.mediaConsumption` does NOT fire for these. No change needed.

### 3. Two-condition gate (debounce)

`.mediaConsumption` fires only when BOTH conditions hold:

1. `frontmostApplication.bundleIdentifier ∈ streamingApps` (from `streaming-apps.toml`)
2. §2 `PixelGridBlackedRegionProbe` has fired ≥3 times in the last 10 seconds

The two-condition gate prevents false positives on apps that MIGHT play DRM but currently aren't (e.g., user opens Apple TV but hasn't started playing — cascade keeps running normally until §2 fires repeatedly). This also avoids pausing on incidental black frames from app launch or interstitial screens.

### 4. What `.mediaConsumption` does NOT do

- **Does not widen `.allow`.** `.mediaConsumption` captures LESS than `.allow` — no pixel keyframe, no OCR. It is a strictly-narrower data path.
- **Does not pause SCStream.** The capture pipeline stays running. The cascade evaluates each frame; frames matching the two-condition gate get `.mediaConsumption` instead of `.suppress(reason=2)`.
- **Does not auto-detect new streaming apps.** The curated list is small and explicit. Auto-detection fails silently and unsafely.
- **Does not cover non-streaming media consumption** (YouTube in Chrome, music apps not playing video, etc.). That is Option C from the original question — deferred to Phase 3+ with real telemetry.

### 5. Wire schema impact

- New `RedactionReason` variant: `10` (mediaConsumption).
- New wire message type: `MediaConsumptionEvent` (next to `OCREvent`), carrying `bundleId`, `windowTitle`, `url` (optional), `ts`.
- Wire schema bump required (coordinated with the next scheduled bump; does NOT require its own 0x04→0x05 if bundled with other Phase 3.x wire work).
- Lock-step Swift / Rust / Python (`tools/wire_decode.py`) bump per the pattern established in PR #44 (0x02→0x03) and PR #79 (0x03→0x04).

### 6. PR sequence (Phase 3.x)

Owned jointly by Director-Recording (cascade side) + Director-Brain (brain side). Each PR CSO-gated.

1. **P3.x.1 — `streaming-apps.toml` + cascade decision impl.** Wire schema bump; `MediaConsumptionEvent` message type; two-condition gate in the Swift helper cascade; tombstone `reason=10`. Director-Recording.
2. **P3.x.2 — synthetic-text event writer + retrieval test.** Brain-side: `MediaConsumptionEvent` → `events` row with synthesized bibliographic text → embed → index. Recall query "what did I watch last Tuesday" returns the right hit. Director-Brain.
3. **P3.x.3 — recall UI rendering.** `MediaConsumptionEvent` rendered as a normal timeline entry with a "Watched" badge. Director-Brain.

## §4 LOAD-BEARING invariants (CSO veto-gate; binding on every implementer)

1. **`.mediaConsumption` captures LESS than `.allow`.** No pixel keyframe. No OCR. Only `windowTitle` + `url` + `appBundleId` + synthesized bibliographic text. Any future PR that adds pixel storage or OCR output to this path requires a fresh CSO ADR amendment.
2. **The curated streaming-app list is CSO-reviewed.** Additions require CSO sign-off. The list is NOT user-extensible in v1 (user extension is a Phase 4 question gated on the denylist UI per ADR-0017 §3.2).
3. **Per-app denylist wins.** If a user denylists a streaming app's `bundleId` via ADR-0017 §3.2, `.mediaConsumption` for that bundle NEVER fires. Denylist is absolute; `.mediaConsumption` is a policy layer below it.
4. **Two-condition gate is mandatory.** BundleId match alone is insufficient — §2 probe must have fired ≥3× in 10s. A PR that removes the debounce or weakens the threshold requires CSO sign-off.
5. **`windowTitle` stored by this path IS user content.** The cascade-twice pattern from ADR-0016 §1.6 does NOT apply here (no OCR involved), but the stored text is not opaque — it contains the show/episode name. This is intentional and CEO-directed (bibliographic value > privacy cost for media titles).
6. **No network calls.** The `streaming-apps.toml` file is bundled locally. No remote list fetch, no "phone home to check if this app is a streaming app." Zero-network thesis (ADR-0016 §4.4) extends to this path.

## Consequences

- **Positive:** Users can search "what did I watch last Tuesday" and get a real answer, even for DRM-protected content where pixel capture is structurally impossible.
- **Positive:** `.suppress(reason=2)` tombstones during streaming sessions become `.mediaConsumption` events with actual bibliographic value — the brain grows instead of emitting opaque privacy moments.
- **Positive:** `.mediaConsumption` captures strictly LESS than `.allow` — this is a narrower data path, not a wider one. CSO sign-off is straightforward.
- **Negative / tradeoff:** `windowTitle` for streaming apps is user content (reveals viewing habits). CEO explicitly accepted this tradeoff — bibliographic search value outweighs the marginal privacy cost for media titles.
- **Negative / tradeoff:** The curated list requires maintenance. New streaming services require a CSO-reviewed list update. Acceptable for v1 scope (~8-10 entries); revisit if the list grows past ~20.
- **Negative / tradeoff:** Web-based streaming (YouTube in Chrome) is NOT covered by `.mediaConsumption` — those paths already get `.allow` + URL capture. The asymmetry (native DRM apps get `.mediaConsumption`, web apps get `.allow`) may confuse users expecting uniform behavior. Recall UI should present both uniformly as "media you watched."

## CSO sign-off (placeholder — owed at first protected-set PR)

§4 invariants binding. `.mediaConsumption` captures strictly LESS than `.allow` — no pixel keyframe, no OCR. The new path carries `windowTitle` to disk, which is user content, but CEO directed this explicitly for bibliographic value. Each PR carries the sign-off block.

— CSO, pending (owed at PR P3.x.1)

## References

- **AGENT_QUESTIONS** PR #55 — CEO answer (2026-05-20 afternoon): "don't pause; capture bibliographic metadata via `.mediaConsumption`."
- **ADR-0013** §2 (DRM black-region detection) + §7 (fail-closed catchall) — the existing cascade behavior `.mediaConsumption` sits alongside.
- **ADR-0015** §4 (context-join LOAD-BEARING invariants) — P2.1/P2.3/P2.4/P2.5 provide the `appBundleId` + `windowTitle` + `url` this path consumes.
- **ADR-0016** §1.6 (wire schema) — `.mediaConsumption` extends the wire with a new message type.
- **ADR-0017** §3.2 (per-app denylist) — denylist takes absolute precedence over `.mediaConsumption`.
- **F-STRAT-002** — allocated DERIVED-FORK-001 to ADR-0020 (this ADR) when F-STRAT-002 took ADR-0018 + ADR-0019.
- CRS research 2026-05-20: Daring Fireball, Apple Developer Forums #63725, Screenify Studio 2026-04-23 — Apple does not permit screen recording of FairPlay-protected content.
