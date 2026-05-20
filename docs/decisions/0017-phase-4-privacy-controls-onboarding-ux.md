# ADR-0017 — Phase 4 Privacy Controls + Onboarding UX (TCC walkthrough · pause · allowlist/denylist · incognito · retention · recall-UI privacy moments)

- Status: Proposed (2026-05-20; CEO+CTO draft pending human CEO ratification). Protected-set authoring (AGENT_PROTOCOL §5) because the allowlist/denylist + per-app override + retention/delete surface directly modulate cascade decisions and the encrypted store's content set.
- Owners: **Director-Brain** (recall-UI privacy moments + retention controls + agent-shell-side state mgmt for Phase 4) + **Director-Context** (allowlist/denylist UI + incognito exclusion + per-app TCC revocation surface) + **Director-Recording** (menu-bar shell + pause button + capture-side incognito drop)
- Reviewers: **CSO** (binding — every protected-set PR carries a sign-off block; allowlist policy is CSO-gated per ADR-0013 §3; retention/delete touches the encrypted store; incognito heuristic is content-adjacent); **CTO** (sequencing + cross-Director arbitration); CEO (ratification gate); COO (onboarding-UX copy + the GTM-doc's 5-step walkthrough script binds here)
- Phase: 4 (after Phase 3 OCR + brain ships the recall-UI v1 and the brain has content to display; before Phase 5 packaging + sync, because Phase 5 needs the privacy-controls surface to ship under)
- **Protected-set: yes** (AGENT_PROTOCOL §5). Justification: allowlist + denylist + retention + incognito are the user-controlled levers over what the cascade allows AND what the store retains. Every PR in §6 below MUST carry a CSO sign-off block asserting the §4 invariants in this ADR.
- Relationship: consumes the cascade + `WorkflowContext` from ADR-0013 + ADR-0015; consumes the OCR pipeline + brain store from ADR-0016; produces the user-facing levers operationalized by `docs/business/2026-05-20-gtm-positioning.md` (the COO GTM doc's 5-step onboarding script binds to this ADR's UX decisions); does **not** change ADR-0008 store schema or ADR-0014 fd-pass seam.

## Context

DESIGN.md §15 Phase 4 is the one-line spec: *"Denylists, pause rules, redaction pass, delete/forget/export, at-rest encryption hardened."* This ADR locks the user-facing UX + the technical surfaces the UX commands; the COO GTM doc (`docs/business/2026-05-20-gtm-positioning.md`) locks the user-facing **copy**.

The biggest user-side friction (DESIGN.md §16 R1) is the **permission grant flow**. Three TCC permissions are required (Screen Recording / Accessibility / per-browser Automation); each is a separate dialog the OS — not MCI — fires. MCI's job is to make the sequence legible, recoverable, and non-coercive.

The biggest user-side **trust** surface is **what MCI captures vs ignores**. Phase 1 + Phase 2 + Phase 3 wire the cascade end-to-end with §1 source-level denylist, §3 secure-event-input detection, §4 AX subrole backstop, §6 OCR-time regex, and §7 fail-closed catchall. Phase 4 ships the user-facing controls over those layers:

- **Allowlist** (`known-safe-apps.toml`) — CSO-gated; users can request additions, CSO ratifies per-bundle.
- **Denylist** — user-controlled; bundle ids + window-title patterns + URL patterns the user wants MCI to refuse.
- **Incognito / private-window exclusion** — automatic per-browser detection (`NSWindowSharingType.none` heuristic + browser-specific signals) flowing into the cascade.
- **Per-app pause** — instant menu-bar toggle and keyboard shortcut.
- **Retention** — per-event delete, per-app delete, per-time-range delete, full wipe. The "delete" semantics are **crypto-shredding** (per-segment key destruction) per ADR-0012, not just SQL DELETE.

The biggest user-side **doubt** surface is **"did MCI redact this?"** The recall-UI v1 from Phase 3 P3.9 surfaces hits. Phase 4 adds **privacy moments** — opaque cards showing the cascade fired without revealing what was suppressed. This is the trust-by-audit-but-make-it-personal property.

## Decision

### 1. Onboarding flow + TCC walkthrough (binding on agent-shell first-launch)

The 5-step flow specified in the COO GTM doc (`docs/business/2026-05-20-gtm-positioning.md` §"Onboarding script") is the canonical script. This ADR locks the **technical** decisions:

#### 1.1 Order of TCC asks: Screen Recording → Accessibility → Automation (per-browser)

- **Why this order:** Screen Recording is most-blocking (cannot use product without it); Accessibility is required for §4 backstop (refuse-by-default if not granted is acceptable degradation); Automation is per-browser opt-in with graceful per-browser nil fallback.
- **Why not Accessibility first:** the user has just installed an app and is being asked for OS permissions. Asking for the most-blocking one first means "say no" exits the product cleanly; asking for AX first means we burn a yes on a non-blocking ask and then re-ask for Screen Recording.
- **Why all three at once via a single screen with buttons (not sequential):** the COO GTM doc's screen 4 lists all three with separate `[Grant ...]` buttons. Each opens the corresponding TCC pane URL. User can grant any order. No coercion.

#### 1.2 TCC denial fallbacks

| Permission | Fallback when denied |
|---|---|
| Screen Recording | MCI cannot capture. Persistent banner in recall-UI: "MCI is paused because Screen Recording is denied. [Grant Screen Recording]". Helper does NOT start `SCStream`. |
| Accessibility | §4 backstop disabled. MCI runs in allowlist-key-app-name-only mode. Less-urgent banner: "MCI is running with reduced privacy filtering. [Grant Accessibility]". |
| Automation (per-browser) | That browser's `URLProvider` returns nil silently. No banner — just URL-less indexing for that browser. |

#### 1.3 No auto-grant — re-asserts ADR-0015 §4.4

The onboarding flow **MUST NOT** use `tccutil`, any private API, or any "click-through" UX that bypasses the OS dialog. The "Grant ..." buttons open System Settings → the relevant TCC pane (via `x-apple.systempreferences:` URL schemes). The OS dialog firing is the consent. Already binding per ADR-0015 §4.4; restated here so future onboarding-UX PRs cannot quietly weaken it.

### 2. Menu-bar shell + pause

The menu-bar agent (DESIGN.md §15 Phase 1, P5 in cycle 2 — already exists as `mci-agent` daemon) gains a Phase 4 UI surface.

#### 2.1 Menu-bar icon states

| State | Icon | Tooltip |
|---|---|---|
| Active (cascade running, capture enabled) | filled brain glyph | "MCI is watching. Cmd-Shift-P to pause." |
| Paused (user-requested) | hollow brain glyph with pause overlay | "MCI is paused. Cmd-Shift-P to resume." |
| Paused (auto — incognito / streaming-app / DRM) | hollow brain glyph with "auto" badge | "MCI is paused because <reason>." |
| Error (TCC denied / helper crashed) | red dot | "MCI is not running. <reason>." |
| Idle (no recent capture activity) | dimmed brain glyph | "MCI is idle." |

Icon updates run on the agent-shell's tokio main thread; no IPC chatter (the agent already owns the cascade-outcome state via the existing wire-frame consumption from PR #15+).

#### 2.2 Pause semantics

- **Cmd-Shift-P** keyboard shortcut globally bound (registers via `NSEvent.addGlobalMonitorForEvents` for the modifier mask + key).
- Pause = `SCStream.stopCapture()` on the helper. Resume = `SCStream.startCapture()`. Same path used by the auto-pause heuristics (incognito / streaming app).
- Pause state persisted in `~/Library/Application Support/MCI/state.json` (NOT the encrypted store — pause is metadata, not content). Survives restart.
- Manual pause + auto-pause are independent: manual-pause = "MCI is off until user resumes"; auto-pause = "MCI is off because a heuristic fired, will resume when frontmost changes." Auto-pause does NOT override a manual-pause that was already in effect.

#### 2.3 Menu items (Phase 4 v1)

```
MCI (Active)
─────────────
Pause MCI         ⇧⌘P
Open Recall…      ⇧⌘F
─────────────
What MCI Sees…              (settings / allowlist+denylist)
What MCI Has Remembered…    (retention dial)
Privacy Moments…            (tombstone browser)
─────────────
About MCI
Quit MCI
```

### 3. Allowlist + denylist UI

#### 3.1 Allowlist (`known-safe-apps.toml`) — CSO-gated per ADR-0013 §3

The allowlist file lives at `~/Library/Application Support/MCI/known-safe-apps.toml`. It is **NOT** user-writable in v1. The settings UI shows the current allowlist read-only; a "Request app addition" button opens a `mailto:` or in-app feedback channel that routes to CSO review. CSO publishes a signed update bundle that bumps the local allowlist via Sparkle (Phase 5 packaging — auto-update channel).

**Why CSO-gated, not user-controlled (v1):** ADR-0013 §3 + ADR-0015 §5 + ADR-0016 §5 all rest on the allowlist being the moment `--capture` flips per-app from default-OFF to default-ON for a known-safe surface. A user-mutable allowlist would let a malicious script (or a confused user) silently relax the suppression. CSO sign-off per-bundle is the trust boundary.

**v2+ open question:** user-curated allowlist with strong UI friction (e.g., "type the bundle id, confirm twice, wait 24h" cooling-off) — Phase 5+ design question; out of scope this ADR.

#### 3.2 Denylist UI — user-controlled (strictly tightens, never widens)

Users can add to the denylist freely. The denylist is **strictly tightening** — it only ever ADDS `.suppress` decisions to the cascade; it cannot widen `.allow`. The settings UI presents:

- **By bundle id** — pick an app from a list of "apps MCI has seen frontmost in the last 30 days" (a content-free index built from the `events.app_bundle_id` column post-ADR-0016) OR enter a bundle id by hand.
- **By window-title regex** — "ignore any window whose title matches `^Private — `" etc. The regex is server-side-of-the-cascade input — flows through `WorkflowContext.windowTitle` → cascade § (new) → `.suppress(reason=8 /* user-denylist */)`.
- **By URL regex** — "ignore any tab whose URL matches `https://www\\.bank\\.com/`" — same shape.

Adding a denylist entry takes effect immediately. Removing one takes effect immediately too. Entries persist in `~/Library/Application Support/MCI/user-denylist.toml`.

**New cascade reason code:** `reason=8` (`userDenylist`). Wire schema bump `0x04 → 0x05` (or fold into the next bump if Phase 3 P3.6 hasn't shipped when Phase 4 enters). Lock-step bump per PR #44 / ADR-0016 §1.6 discipline.

#### 3.3 Incognito + private-window exclusion (automatic, capture-side)

The browser's incognito/private-window state surfaces via two channels:

- **`NSWindow.sharingType == .none`** — Safari + Chrome + Brave + Edge set this on incognito/private windows. The helper's `SCContentFilter` already excludes windows with `sharingType == .none` (this is the OS-level "don't share this window" signal). Phase 4 docs this as a structural property and adds a test.
- **Browser-specific window-title heuristics** — Safari "Private Browsing" in the title bar; Chrome's incognito badge; Firefox's "Private Browsing" mode. The cascade gets a new probe `BrowserIncognitoProbe` that reads `windowTitle` against per-browser patterns; on match → `.suppress(reason=9 /* incognitoExclusion */)`.

The `NSWindow.sharingType` path is the primary defense — incognito windows literally cannot reach the SCStream callback. The title heuristic is defense-in-depth for edge cases (Firefox + some Chrome configurations where `sharingType` is `nil` instead of `.none`).

### 4. Retention controls

#### 4.1 Delete semantics — crypto-shredding (per ADR-0012)

A `DELETE` from the recall-UI does NOT just `DROP FROM events WHERE id = X`. It:

1. Marks the event row tombstoned (`events.deleted_at_us = now()`).
2. Schedules a background compaction (Phase 9 work, but Phase 4 ships the scheduler) that **destroys the per-segment key** for any segment containing that event.
3. Wipes the event row + chunks + embeddings + keyframe blob.

The crypto-shred ensures that even if a deleted event's encrypted bytes have been backed up to Time Machine or a cloud backup, the bytes are unreadable post-shred. **Server-side delete (Phase 5 sync) is untrustworthy by construction; only the per-segment key destruction is.**

#### 4.2 Retention UI granularity

The settings UI offers four deletion granularities:

1. **Per-event delete.** Recall-UI hover → "..." menu → "Delete this event." Confirms; deletes; UI fade-out.
2. **Per-app delete.** Settings → app list → "Delete everything MCI remembers about <app>." Confirms; backgrounds; UI shows "<N> events queued for deletion."
3. **Per-time-range delete.** Settings → date picker → "Delete everything between <start> and <end>." Confirms; backgrounds.
4. **Full wipe.** Settings → bottom of page → "Forget everything." Triple-confirm (typed "FORGET" string + checkbox + delay). Backgrounds; deletes the entire `mci.sqlite` + blob store + rotates the DB master key.

#### 4.3 Retention dial — set-and-forget

A simple slider for the default-retention horizon:

- "Forever" (default for v1).
- "Keep for 1 year, then forget."
- "Keep for 6 months, then forget."
- "Keep for 1 month, then forget."

The brain's background compaction (Phase 9) reads this preference and crypto-shreds events older than the horizon. Per-event / per-app deletes from §4.2 are immediate; the retention dial is a continuous background process.

#### 4.4 Export (DESIGN.md §15 Phase 4 "...export")

Export to JSON / CSV from the recall-UI. The export is **plaintext** (the user is asking for it — they own the data) but writes only to a user-chosen file path. No automatic upload, no telemetry. The export action emits a content-free counter (`export_event_count`) for sanity.

### 5. Recall-UI privacy moments display

The recall-UI v1 from Phase 3 P3.9 already surfaces twice-cleared events as searchable hits. Phase 4 adds the **privacy moments** surface — a separate timeline view (or filter toggle) showing `PrivacyTombstone`s.

#### 5.1 What a privacy moment card shows

```
┌──────────────────────────────────────────────────┐
│  MCI redacted this                               │
│                                                  │
│  App:        com.1password.app                   │
│  Time:       2026-05-20 14:32:11                 │
│  Reason:     Password field detected (§4)        │
│                                                  │
│  (no content captured)                           │
└──────────────────────────────────────────────────┘
```

The card carries **only the post-cascade-decision metadata** — `appBundleId` + `ts` + the cascade reason code mapped to a friendly string. **NEVER** the OCR'd text (because it didn't reach OCR), NEVER the keyframe (because it wasn't stored), NEVER the windowTitle/url (because content-as-content invariant — Phase 4 does not relax this).

#### 5.2 The mapped strings

Per-reason friendly strings (final copy lives in `apps/recall-ui/Resources/Localizable.strings`, eligible for COO copy review):

| Reason code | Friendly string |
|---|---|
| 1 (denylist) | "App was on the denylist." |
| 2 (DRM / blacked region) | "DRM-protected video (Apple TV, Netflix, etc.)." |
| 3 (secure event input) | "Password being typed." |
| 4 (AX secure-text-field) | "Password field detected." |
| 5 (denylist drift) | "App was being captured but moved to denylist." |
| 6 (OCR-time regex secret/PII) | "Text matched a secret/PII pattern." |
| 7 (fail-closed catchall) | "App was unknown — MCI refused by default." |
| 8 (user denylist — new Phase 4) | "You asked MCI to ignore this." |
| 9 (incognito — new Phase 4) | "Incognito/private browser window." |

#### 5.3 The "show me what you saw" debug mode (out of scope for Phase 4)

A power-user mode that shows the cascade input deltas (just the bundleId / windowTitle hash / URL hash that the cascade actually evaluated, not the content) might land Phase 4.5+. Out of scope for v1; mentioned here to avoid scope creep.

### 6. PR sequence — Director-Brain + Director-Context + Director-Recording own per their scope

Phase 4 lands as a 7-PR sequence, comparable in cadence to Phase 2 (6 PRs) and lighter than Phase 3 (11 PRs). Each PR carries a CSO sign-off block asserting §4 invariants.

- **P4.1 — Menu-bar shell + pause button + Cmd-Shift-P** (Director-Recording, `apps/agent/` or new `apps/menu-bar/` if SwiftUI separation needed). 1 cycle.
- **P4.2 — Onboarding flow + TCC walkthrough UI** (Director-Recording, lives in `apps/agent/` or new `apps/onboarding/`). Implements the COO GTM doc's 5-step script. 1 cycle.
- **P4.3 — Allowlist read-only UI + "request addition" feedback channel** (Director-Brain, recall-UI settings panel). CSO-gated; the allowlist file itself is bumped via signed updates (Phase 5 packaging). 1 cycle.
- **P4.4 — Denylist UI + cascade `reason=8` + wire bump** (Director-Context for UI + Director-Recording for cascade integration). CSO-gated wire bump. 1 cycle.
- **P4.5 — Incognito + private-window exclusion** (Director-Recording for the `NSWindow.sharingType` exclusion test + the `BrowserIncognitoProbe`; Director-Brain for the cascade `reason=9` plumbing). 1 cycle.
- **P4.6 — Retention controls + crypto-shred scheduler** (Director-Brain + CSO co-owned — touches the encrypted store + key destruction). 1 cycle.
- **P4.7 — Recall-UI privacy moments view** (Director-Brain). Read-only timeline of `PrivacyTombstone` rows. 1 cycle.

### 7. Privacy invariants — LOAD-BEARING (CSO veto-gate per ADR-0013 §5)

These invariants are why this ADR is protected-set:

1. **Allowlist is CSO-gated, not user-writable** (§3.1). User-curated allowlist is a v2+ open question.
2. **Denylist is strictly-tightening** (§3.2). It can only add `.suppress` decisions; can never widen `.allow`. Tripwire test: every `userDenylist` cascade decision is `.suppress` by construction.
3. **Incognito exclusion fires BEFORE storage** (§3.3). Same trust boundary as ADR-0013 §2 cascade-before-storage.
4. **Delete = crypto-shred** (§4.1). A `DELETE` that doesn't destroy the per-segment key is a §4 protected-set violation. CSO veto on any change to the deletion code path.
5. **Privacy moment cards carry NO user content** (§5.1). `appBundleId` + `ts` + reason-string only. Never OCR'd text, never keyframe, never windowTitle/url. CSO veto.
6. **Export is user-initiated only** (§4.4). No automatic upload, no telemetry, no scheduled export. CSO veto on any change to the export code path.
7. **TCC denials never block the agent from running** (§1.2). MCI runs with reduced functionality, never refuses to launch. Coerced consent is not consent.
8. **No auto-grant of TCC permissions** (§1.3). Re-asserts ADR-0015 §4.4. Banned: `tccutil`, private APIs, any "click-through" UX bypassing the OS dialog.

### 8. Out of scope (explicitly deferred)

- **User-curated allowlist** (v2+ — see §3.1).
- **Sync of privacy controls across devices** — Phase 5 (zero-knowledge sync). Phase 4's state lives in `~/Library/Application Support/MCI/state.json` + `user-denylist.toml` per-device.
- **Per-event "tag this for retention"** — Phase 9 retention features. Phase 4 retention is dial-driven, not per-event.
- **Power-user debug mode** showing cascade input deltas (§5.3) — out of scope v1.
- **Programmatic API for the privacy controls** — Phase 6 (agent API). Phase 4 ships UI only; the agent API can layer onto these surfaces later.
- **Windows port of Phase 4** — Phase 8. UIA + Windows credential manager + Windows.Media.Ocr equivalents.

## Consequences

- Positive: users have direct, legible control over what MCI captures and what it remembers. The trust surface from F-STRAT-001b ("third-party audit + demonstrable behavior") gains its user-facing half.
- Positive: the cascade reason codes (1-9) are now fully exercised post-Phase 4. `userDenylist` + `incognitoExclusion` are the two new ones; Phase 4 wires them into the existing cascade discipline (strictly-tightening, never widens `.allow`).
- Positive: delete-by-crypto-shred makes Phase 5 sync safer — a delete on device A reaches device B as a tombstone, and any backup of the pre-delete ciphertext is unreadable because the segment key was destroyed.
- Negative / tradeoff: per-browser incognito heuristics are fragile. Each browser update can change the window-title pattern. CRS Telemetry-Gap analyst tracks `incognito_probe_match_rate` (content-free count) and flags regressions.
- Negative / tradeoff: the 7-PR sequence is large. Phase 4 takes ~3 attended sprints minimum.
- Forces (binding on every Phase 4+ PR):
  - **Any change weakening the allowlist's CSO-gate is a §7.1 violation.**
  - **Any new cascade reason code that widens `.allow` instead of adding `.suppress` is a §7.2 violation.**
  - **Any retention/delete path that does not crypto-shred is a §7.4 violation.**
  - **Any privacy-moment surface that carries user content is a §7.5 violation.**

## CSO sign-off (placeholder — owed at first protected-set PR in §6)

Protected-set authoring (AGENT_PROTOCOL §5). The §7 privacy invariants are binding. CSO sign-off blocks are owed on every PR in §6 asserting (by reading the diff) that the invariants hold. CSO veto is final unless the human CEO overrides.

— CSO, pending (this ADR is a CEO ratification gate; CSO sign-off is owed at PR P4.1)

## References

- ADR-0001 (privacy posture), ADR-0008 (encrypted store — Phase 4 crypto-shred touches the segment key model), ADR-0012 (zero-knowledge spec tightening + crypto-shred deletion semantics), ADR-0013 + Amendment 1 (the cascade Phase 4 controls), ADR-0015 (Phase 2 context join — Phase 4 reads the `WorkflowContext` for the denylist patterns), ADR-0016 (Phase 3 OCR + brain — Phase 4 surfaces the privacy moments + retention over Phase 3's events).
- `docs/STATE.md` (2026-05-20 afternoon — Phase 4 ADR drafted in parallel with Phase 2 Wave 1 land + Phase 3 ADR ratification).
- `docs/AGENT_PROTOCOL.md` §4 (footprint), §5 (protected-set), §7 (escalation), §8 (ADR-required for material choices).
- `docs/DESIGN.md` §9 (security model + at-rest + deletion semantics), §15 Phase 4 (canonical one-line scope), §16 R1 (permission friction — the #1 product risk this ADR addresses).
- `docs/business/2026-05-20-gtm-positioning.md` §"Onboarding script" (canonical user-facing copy — this ADR locks the technical decisions behind it).
- Apple — `NSWindow.sharingType` <https://developer.apple.com/documentation/appkit/nswindow/1419729-sharingtype>; `x-apple.systempreferences:` URL schemes for opening TCC panes; `NSEvent.addGlobalMonitorForEvents` for global keyboard shortcuts.
