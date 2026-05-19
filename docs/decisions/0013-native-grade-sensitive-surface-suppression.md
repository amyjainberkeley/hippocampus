# ADR-0013 — Native-grade sensitive-surface suppression (launch-blocker)

- Status: Accepted (2026-05-18; ratified by human CEO via /night-run cycle 4 — F-STRAT-001a derived work). **Amended 2026-05-19 — Amendment 1 (enabler-PR gating boundary); see end of file.**
- Owners: **CSO** (binding contract) + **Director-Recording** (Phase-1 implementation)
- Reviewers: CEO; Director-Sync-Core (CaptureSource adapter PR consumes this contract); Director-Context (workflow-context metadata side); CRS (research-spike memo author, `docs/research/2026-05-18-macos-secure-surface-detection.md`)
- Phase: 0 (contract); implementation lands in Phase 1 (macOS capture spine)
- **Protected-set: yes** (AGENT_PROTOCOL §5 — sensitive-capture denylist / redaction / incognito-exclusion)
- **Launch-blocker: yes** (AGENT_PROTOCOL §4 / R5 — privacy is a launch blocker; ships **with** the capture path, not later)

## Context

`F-STRAT-001a` (resolved 2026-05-18; see `docs/AGENT_QUESTIONS.md`) made MCI's headline differentiator **"MCI never captures what your Mac itself would hide on a screen-share."** The CEO's reference model — iOS FaceTime / SharePlay auto-blanking secure password fields — is **iOS-only**. macOS screen capture does **not** auto-blank password fields for arbitrary apps. To honor the wedge on macOS, MCI must *actively* detect-and-redact sensitive surfaces at capture time, using the signals the OS itself exposes.

The CRS research-spike memo `docs/research/2026-05-18-macos-secure-surface-detection.md` verified the four candidate signals and proposed a detection cascade with a fail-safe default. **This ADR locks the cascade as a binding contract on the Phase-1 macOS capture path.** It is owned jointly by CSO (privacy contract; veto authority per AGENT_PROTOCOL §5) and Director-Recording (Phase-1 implementation).

This ADR also re-states the AGENT_PROTOCOL §4 / R5 invariant: **privacy ships with the capture path, never later.** The Swift helper PR that lands `SCStream` lifecycle (Phase 1) is the same PR that wires the cascade. A capture-without-suppression PR is rejected at review.

## Decision

### 1. The cascade (binding order)

Every captured `StateTransition` (DESIGN.md §5; ADR-0006) runs through the cascade below in the **macOS Swift helper** (ADR-0007), **before any frame, dirty-rect, or workflow-context metadata crosses IPC into the Rust core**. Order matters; the first signal that fires drives the response.

1. **Source-level denylist via `SCContentFilter`.** The Swift helper constructs the `SCStream` with `SCContentFilter(display:excludingApplications:exceptingWindows:)` populated from the user's app/url denylist (`denylist` table — DESIGN.md §12). Pixels and window-bounds from denylisted sources **never enter the pipeline**. AGENT_PROTOCOL §4 / R5 / DESIGN.md §9.3 "load-bearing privacy primitive."
2. **OS-already-blacked-out region.** If a captured frame contains a known-black region matching a tracked window's bounds (`NSWindowSharingType = .none`, FairPlay / DRM playback, or denylist-excluded above), the helper **also drops the metadata for that window** (window title, URL, page text). Pixels are already gone via the OS; metadata must follow.
3. **Process-wide `IsSecureEventInputEnabled()` true at frame time.** The helper re-polls the Carbon `IsSecureEventInputEnabled()` bit **on every state transition** before encode/store. If true: **suppress the whole event** — drop the keyframe, drop the OCR-bound text, drop the AX-extracted title/URL. Emit a privacy tombstone (§4 below).
4. **Focused AX element has `kAXSecureTextFieldSubrole`.** The helper queries `AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute, …)`. If the value is `"AXSecureTextField"`: **suppress the whole event** as in §3.
5. **App/URL denylist post-capture (belt-and-suspenders).** Even when source-level §1 should have caught it, re-check the `WorkflowContext` at OCR-orchestration time against the same `denylist` table and drop. Mismatches between §1 and §5 are tracked as a CRS Telemetry-Gap metric.
6. **OCR-time secret / PII regex.** Defense-in-depth only (ADR-0012 §9; Basak et al. arXiv:2307.00714 — best-tool recall ≈ 52–88%). Mask matched ranges in `event_text` **before indexing**. Never the primary signal.
7. **Fail-safe default: unknown ⇒ redact.** When none of §1–§4 fire but the helper cannot positively classify the focused element with reasonable confidence (e.g., an Electron window where AX is silent on a focused element that isn't a known role), the helper **must** redact the event rather than index it. A privacy tombstone is emitted.

### 2. The redaction-before-store guarantee

When the cascade fires (any of §3 / §4 / §5 / §7, or both §1+§2 metadata-drop):

- **No pixels cross IPC.** The Swift helper does not pass the surface handle to the Rust core for that event. The frame bytes never enter the encode pipeline, never reach `core/store/`, never reach the blob store, never reach `sync_log`.
- **No event-level text crosses IPC.** Window title, URL, page text, OCR-bound text are all dropped at the helper boundary.
- **No FTS / vector index entries are written.** Because the event never reaches `core/brain/`, the `event_text` / `event_text_fts` / `event_vectors` rows for it never exist.
- **The sync delta log is also unaffected** — a never-stored event cannot be synced; the zero-knowledge invariant (ADR-0001, ADR-0012) is preserved through the simplest possible path: the data isn't there to leak.

This guarantee is **binding on every implementer**. A future PR that materializes any of the above for a suppressed event — even temporarily, even "just to compute a dirty-rect," even "just for telemetry" — requires a fresh CSO ADR amendment.

### 3. Fail-safe default — "unknown ⇒ redact" is non-negotiable

When the helper cannot positively determine the secure-surface status of the focused element with reasonable confidence, the cascade resolves to **redact**, not "pass through with a warning." The exact threshold for "reasonable confidence" is:

- AX query returns a non-secure subrole **AND**
- `IsSecureEventInputEnabled()` is false **AND**
- the foreground app's bundle ID is **either** on a curated `known-safe` allowlist (initially empty; populated by Phase-1 integration tests per the CRS memo's per-app override matrix) **or** the foreground app's window has `sharingType = .readOnly` (the AppKit default) and the focused element has a recognizable non-secure AX role (`AXTextField`, `AXTextArea`, `AXLink`, `AXStaticText`, `AXButton`, etc.).

If any of these conditions cannot be evaluated (AX permission missing, app crashed mid-probe, helper out of memory), the resolution is redact. **Flipping this default to "pass through on uncertainty" is a CSO-protected amendment** and will be rejected at review without one.

### 4. Privacy tombstone — the demonstrable-redaction surface

Every suppression-fired event emits a **privacy tombstone** into the pipeline. A privacy tombstone is a minimal `events`-table row with:

- `ts` — the state-transition timestamp.
- `device_id` — same as any other event.
- `app_bundle` — the foreground app at the time of suppression.
- `source_type = 'redacted'` (new value, distinct from `ext` / `ocr` / `ax`).
- `summary = NULL`, `entities = NULL`, `keyframe_blob_ref = NULL`, `dhash = NULL`, `window_title = NULL`, `url = NULL`.
- A new column **`redaction_reason TEXT`** added to `events` in a Phase-1 schema bump (ADR-0009 migration mechanism), holding one of the cascade reasons: `'denylist-source'`, `'os-blacked-region'`, `'secure-event-input'`, `'ax-secure-subrole'`, `'denylist-postcapture'`, `'failsafe-unknown'`.

The recall UI surfaces tombstones as privacy moments — "MCI redacted this event because the OS reported secure input was active in 1Password." This makes the suppression guarantee **audit-survivable** (F-STRAT-001b: trust-by-audit) rather than invisible.

**Schema impact:** ADR-0009's schema-version discipline applies. Phase 1's store-init PR bumps `meta.schema_version` and adds:

```sql
ALTER TABLE events ADD COLUMN redaction_reason TEXT;
```

This DDL is **deferred to Phase 1** to keep the Phase-0 store skeleton (`claude/cso/phase0-store-skeleton-v2`) unchanged. The contract is locked here; the column lands with the helper.

### 5. Launch-blocker placement (AGENT_PROTOCOL §4 / R5)

**The Phase-1 macOS capture spine PR that wires `SCStream` lifecycle is the same PR that wires the cascade end-to-end.** This is a CSO veto-gate clause: a Phase-1 PR that lands `SCStream` without §1 (source-level `SCContentFilter` denylist), §3 (`IsSecureEventInputEnabled` re-poll), §4 (AX subrole check), §7 (fail-safe default), and §4 above (privacy tombstone) is **rejected at CSO review** regardless of other merits. There is no "we'll add suppression in the next PR." Privacy ships with capture or capture does not ship.

### 6. Scope honesty (binding, from the CRS memo)

The cascade has known coverage gaps; the ADR locks how MCI handles them:

- **Electron AX intermittency.** Where AX is silent on a focused Electron element, §4 cannot fire and the resolution falls through to §7 (fail-safe redact). A per-app override allowlist may relax this once Phase-1 integration tests characterize each app; the table is maintained under `adapters/macos/known-safe-apps.toml` and additions require CSO review.
- **Firefox web-password fields.** AX is weaker than Safari / Chromium browsers here; §3 still fires when the secure-event-input bit toggles, but the resolution is coarser-grained. Documented in user-visible privacy docs.
- **Carbon / CEF custom-drawn password prompts.** No AX, no `NSSecureTextField`. §3 catches them when the app calls `EnableSecureEventInput()` (sudo / pinentry-style); otherwise the cascade falls through to §7.
- **Windows analog (Phase 8).** UIA `IsPassword`, `WDA_EXCLUDEFROMCAPTURE`, WGC exclusion filters. Equivalent cascade owed at Phase 8; this ADR does not bind it.

### 7. Validation requirements (gating Phase 1 → 2)

The Phase-1 helper PR must include:

- An **integration-test corpus** of secure-surface scenarios — at minimum: System Settings password sheet, Safari autofill, 1Password vault unlock, Terminal `sudo` prompt, a known-Electron app's password field (Slack workspace switcher / VS Code settings), a `WDA_EXCLUDEFROMCAPTURE`-equivalent third-party window (`NSWindowSharingType = .none`), an `AVPlayer`-FairPlay HDCP playback.
- For each scenario: **a programmatic assertion that no pixels and no metadata for the redacted region cross IPC** (test inspects the channel sent from helper to core) **and** that a privacy tombstone with the correct `redaction_reason` is emitted.
- An **audit report artifact** (test output JSON), committed under `docs/audit/2026-XX-XX-suppression-corpus.json`, that F-STRAT-001b's published third-party security audit can re-run.

A Phase-1 helper PR without these tests does not pass CSO review.

## Consequences

- Positive: MCI's strategic wedge becomes a code-enforced guarantee. The recall UI tombstones make it visible to the user. F-STRAT-001b's audit has something concrete to validate.
- Positive: source-level `SCContentFilter` exclusion makes the load-bearing primitive operate at the **earliest** possible layer (frame never enters the pipeline) — the cheapest correct implementation.
- Positive: the fail-safe default + the launch-blocker placement remove the most common failure mode (capture ships, suppression is "coming in a follow-up," followup never comes, ship.).
- Negative / tradeoffs: the cascade adds per-frame work to the helper — at worst ~1 AX query + 1 Carbon syscall per state-transition. State-transitions are not frame-rate-frequent (DESIGN.md §5 — event-driven, ~10⁰–10¹ Hz under normal use), so the cost is sub-percent of the §4 footprint budget. Director-Recording's Phase-1 measurement PR confirms.
- Negative / tradeoffs: tombstone events fill the `events` table at the rate of secure-surface encounters. For a normal user this is dozens per day. Storage cost is rounding error; ADR-0009 schema unchanged except the `redaction_reason` column.
- Forces (binding on every future PR):
  - **Any Phase-1 PR that lands `SCStream` without the full cascade is rejected.**
  - **Any PR that materializes pixels / text / metadata for a suppressed event** (for any reason: telemetry, debugging, "just to compute X") requires a fresh CSO ADR amendment.
  - **Any change to the fail-safe default** (§3 above) requires a fresh CSO ADR amendment.
  - **The `known-safe-apps.toml` override table** (§6) requires CSO review on every addition.
  - **Privacy tombstones are public events**: the recall UI must surface them by default. A "hide tombstones" UI toggle requires CSO review.

## Alternatives considered

- **"Capture everything; redact at indexing time."** Rejected. This is Microsoft Recall's 2024 failure mode: pixels exist in transit, in encode buffers, in temp files; redaction at index time still leaves a window where plaintext is reachable. ADR-0012 §5/§6 already names this threat ("plaintext in MCI same-user-accessible process while running") and §6 requires minimal-plaintext-residency. Capturing-then-redacting violates that ADR.
- **"OCR-time regex as the primary mechanism."** Rejected. Basak et al. arXiv:2307.00714 — best-tool recall 52–88%. A 12–48% miss rate is not the privacy primitive a launch-blocker can rest on. OCR regex is defense-in-depth (§6 of the cascade), not primary.
- **"Defer the cascade to Phase 4 (privacy controls)."** Rejected. Violates AGENT_PROTOCOL §4 / R5: "Sensitive-capture invariant: denylist + redaction + incognito-exclusion + one-click pause ship with the capture path, not later. Privacy is a launch blocker." This ADR re-states the rule and binds Phase 1.
- **"`SCContentFilter` source-level exclusion only; no detect-and-redact cascade."** Rejected. `SCContentFilter` requires the user to pre-configure a denylist by app or URL. Most users won't. The cascade catches the cases the user didn't pre-configure (an inline password field inside a non-denylisted app) — which is exactly the gap F-STRAT-001a's wedge fills.

## CSO sign-off

This ADR is protected-set authoring (AGENT_PROTOCOL §5). It is **binding on every Phase-1 macOS capture spine PR, every Phase-2 context-join PR, and every future change to redaction logic in `core/**` or `adapters/macos/**`**. Implementer deviations — especially flipping the fail-safe default, materializing pixels/metadata for a suppressed event, hiding tombstones by default in the recall UI, or shipping `SCStream` without the cascade wired end-to-end — require a fresh CSO review and an amending ADR. The CSO veto is final unless the human CEO overrides.

— CSO, 2026-05-18

## Director-Recording sign-off

The detection cascade above is Director-Recording's Phase-1 implementation scope. The integration-test corpus in §7 is owed in the Phase-1 helper PR. Director-Recording acknowledges:

- The cascade runs **in the Swift helper** (ADR-0007); `core/` stays OS-agnostic (ADR-0003).
- The privacy tombstone schema change lands in the same Phase-1 PR as the cascade (one migration, one `meta.schema_version` bump).
- The Phase-1 PR does **not** ship `SCStream` lifecycle without the cascade end-to-end (§5 launch-blocker).
- Per-app overrides in `known-safe-apps.toml` are CSO-gated additions, not Director-Recording-unilateral.

— Director-Recording, 2026-05-18

## References

- `docs/AGENT_QUESTIONS.md` § F-STRAT-001 (2026-05-18, resolved by CEO) — the strategic wedge this ADR implements.
- `docs/research/2026-05-18-macos-secure-surface-detection.md` (CRS, this cycle) — verified findings on each candidate signal.
- ADR-0001 (privacy posture), ADR-0007 (macOS Swift helper), ADR-0009 (schema-version + re-embed migration discipline), ADR-0012 (zero-knowledge spec + §5 / §6 same-user-process threat model + process-hardening).
- DESIGN.md §3 (day-in-the-life pause / recall), §5 (capture pipeline), §9 (privacy / encryption / sensitive-content controls), §10 (process model + hardening), §12 (data model — `events`, `denylist`).
- AGENT_PROTOCOL §4 (sensitive-capture launch-blocker invariant), §5 (CSO protected-set + veto-gate).
- Apple — `kAXSecureTextFieldSubrole`, `IsSecureEventInputEnabled()`, `NSWindow.sharingType`, `SCContentFilter`, FairPlay-protected playback (see CRS memo for exact references).
- Microsoft Recall — TotalRecall Reloaded, CSO Online 2026-04-16 (the failure shape this ADR prevents).
- `docs/COMPETITORS.md` (CRS, screenpipe entry, 2026-05-18) — the competitive context.

## Amendment 1 (2026-05-19) — Enabler-PR gating boundary

- Status: Accepted (2026-05-19; ratified by human CEO in the Phase-1 live-capture human-in-the-loop session). Protected-set authoring (AGENT_PROTOCOL §5). Amends the operational reading of §5 and §7; the substantive cascade contract (§1–§4, §6) is unchanged.
- Decision record: `docs/AGENT_QUESTIONS.md` § "2026-05-19 — CSO/CEO — ADR-0013 §7 enabler-PR gating boundary".

### Context

The Phase-1 live-capture work (live `SCShareableContent`/`SCStream`/`SCStreamConfiguration`, the `SCStreamOutput` callback, IOSurface retain → surface-lease release, VideoToolbox HEVC encode) can only be done and verified on a live screen on a real Mac, in a human-in-the-loop session. It lands as a **sequence** of small protected-set PRs, not one PR.

A literal reading of §7 ("A Phase-1 helper PR without these tests does not pass CSO review") conflicts with the operational reality recorded in `docs/STATE.md`: the §7 secure-surface integration-test corpus (1Password, `sudo`, FairPlay/HDCP, `NSWindowSharingType=.none`, System Settings password sheet, secure text fields) is **HUMAN-ONLY and must be run on a real machine** — it cannot be a precondition for the very PRs that make it runnable. This amendment removes the contradiction without weakening the launch-blocker.

### Decision

1. **What the §7 corpus gates (unchanged in force, sharpened in scope).** The §7 integration-test corpus + the committed audit artifact (`docs/audit/2026-XX-XX-suppression-corpus.json`, §7) gate **all three of**: (a) the **Phase 1 → 2** transition; (b) **enabling capture in any shipped or default build** (capture default-ON); (c) declaring any **footprint/G2 measurement** as a satisfied gate. Until the corpus is green on a real machine and the artifact is committed, none of (a)/(b)/(c) may be claimed. This is non-negotiable and remains a CSO veto-gate.

2. **What the §7 corpus does NOT gate.** The §7 corpus is **not** a per-PR blocker on the *enabler PRs* — the live-`SCStream` wiring sequence (live session + `SCStreamOutput`; IOSurface retain → surface-lease; VideoToolbox encode behind `.allow`). Those PRs may merge before the corpus exists, **provided every condition in §3 below holds**. This is the only operational change Amendment 1 makes to §5/§7.

3. **The conditions an enabler PR must satisfy to merge (CSO structural review — all four, every PR).** Each enabler PR carries a CSO sign-off block asserting, by reading the diff:
   - **(a) Cascade-before-encode (§5).** The ADR-0013 `SuppressionCascade` runs on every frame *before* any encode call site. The single encode call site is reachable only on the cascade's `.allow` branch. No new path reaches encode/store/IPC ahead of, or around, the cascade.
   - **(b) Fail-closed preserved (§3/§7).** The "unknown ⇒ redact" default is intact; no enabler PR widens an `.allow` path or relaxes a probe to "pass through on uncertainty."
   - **(c) No stored / emitted suppressed event (§2 redaction-before-store guarantee).** No path materializes pixels, text, or metadata for a `.suppress` decision — not for encode, not for telemetry, not "just to compute X."
   - **(d) No IOSurface pool-stall (§4 footprint failure mode).** The surface retain/release discipline cannot stall the OS frame pool on any path (drop / suppress / allow / error / throw). Exactly-once release on every exit.
   A PR that fails any of (a)–(d) is rejected at CSO review exactly as a no-cascade PR is under §5.

4. **Capture stays default-OFF / dev-only until the corpus is green.** Every enabler PR keeps the live-capture path **disabled in any default or shipped build** — gated behind an explicit, non-default dev affordance (e.g. an opt-in `--capture` flag and/or a non-default build configuration). No default code path may start a live `SCStream` that reaches an encode/store until §2's gate (1)(b) is satisfied. **Flipping capture default-ON is a CSO-protected change** and requires the committed §7 corpus artifact + a fresh CSO sign-off.

5. **§5 is not weakened.** §5's rule — "a Phase-1 PR that lands `SCStream` without the full cascade wired end-to-end is rejected" — remains fully in force. It is *already* satisfied structurally: the cascade is wired in `SCStreamPipeline` (landed PR #15) and every enabler PR feeds that existing gate rather than bypassing it. Amendment 1 clarifies that the §7 *corpus* (as distinct from the *cascade*) is a capture-on / Phase 1→2 gate, not a per-enabler-PR blocker, conditioned on §3 + §4 above.

### Consequences

- The live-capture sequence can proceed in small, individually reviewable protected-set PRs without a literal-§7 deadlock, while the launch-blocker is *strengthened*: capture cannot reach a shipped/default build, and no footprint or Phase-1→2 claim can be made, until the real-machine §7 corpus is green and its artifact is committed.
- CSO review load is explicit and bounded per enabler PR: assert (a)–(d) from the diff. No "follow-up" path is created.
- The recall-UI tombstone surface (§4) and the fail-safe default (§3) are untouched.

### CSO sign-off

Amendment 1 is protected-set authoring (AGENT_PROTOCOL §5). It narrows the *operational* reading of §5/§7 only; the substantive cascade (§1–§4, §6), the redaction-before-store guarantee, the fail-safe default, and the tombstone surface are unchanged and remain CSO-protected. The four structural conditions in §3 and the default-OFF condition in §4 are themselves a binding CSO veto-gate on every enabler PR. Flipping capture default-ON, or claiming the Phase 1→2 / footprint gate, without the committed §7 corpus artifact is rejected without a fresh CSO sign-off. The CSO veto is final unless the human CEO overrides.

— CSO, 2026-05-19

### Director-Recording sign-off

Director-Recording owns the enabler-PR sequence and acknowledges: every enabler PR carries the §3 (a)–(d) assertions and the §4 default-OFF gate in its PR body; the live-capture path ships disabled until the human runs the §7 corpus green on a real machine and the artifact is committed; flipping capture default-ON is CSO-gated, not Director-Recording-unilateral.

— Director-Recording, 2026-05-19
