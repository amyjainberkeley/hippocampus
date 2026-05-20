# ADR-0015 — Phase 2 Context Join (NSWorkspace + AX + per-browser AppleScript)

- Status: Proposed (2026-05-20; CTO draft pending human CEO ratification). Protected-set authoring (AGENT_PROTOCOL §5) because it modifies the inputs the ADR-0013 cascade consumes and changes what `WorkflowContext` carries across the helper boundary at suppress-time.
- Owners: **CTO** (this ADR — sequencing + per-field design) + **Director-Recording** (Phase-2 PR sequence implementation, in the Swift helper)
- Reviewers: **CSO** (binding — ADR-0013 cascade input contract; first-launch Apple Events consent; tombstone `appBundleId` payload now carries real values); CEO (ratification gate); Director-Sync-Core (notes only — `core::ipc` payload shape unchanged this phase); Director-Context (the org role most adjacent to context-join, even though Phase-2 lands in the macOS helper); CRS (telemetry-gap analyst — per-app/per-browser failure-mode characterization)
- Phase: 2 (between Phase-1 close — §7 corpus green + G2 footprint proof — and Phase 3 OCR+brain)
- **Protected-set: yes** (AGENT_PROTOCOL §5). Justification: every `WorkflowContext` field is user content. The PRs in §6 below MUST carry CSO sign-off blocks asserting the §5 invariants in this ADR.
- Relationship: makes ADR-0013 cascade §1 (source-level denylist) operationally meaningful for the first time (currently dead because `appBundleId == nil` in every callback — `SCStreamCaptureSession.swift:274–279`, `:382–389`); feeds the existing `PrivacyTombstone` payload (already carries `appBundleId`) with real values; does **not** change the ADR-0014 fd-pass seam or the IPC wire schema.

## Context

Phase 1 closes (per `docs/STATE.md` 2026-05-20) with the live SCStream callback verified end-to-end, the ADR-0013 cascade running cascade-before-encode, and all four §7-corpus probes implemented + live-mechanically-verified. One inconvenient remainder: the `WorkflowContext` struct passed into the cascade has **every field nil** at every call site. The cascade still works — §3 (`IsSecureEventInputEnabled`), §4 (AX subrole), §7 (fail-safe redact) all fire on signals other than context — but the design contract has a hole:

- **ADR-0013 cascade §1 — source-level denylist via `SCContentFilter`** — is structurally dead today. The denylist matches on `appBundleId` / `url` / `windowTitle`. The helper passes `nil` for all three (`SCStreamCaptureSession.swift:274–279`). The §1 probe cannot fire because there is nothing to match against. Step-2 v4 audit explicitly deferred §1 to Phase 2 for this reason.
- **The `knownSafeApps` allowlist** referenced in ADR-0013 §3 + §6 cannot be populated, because every frame's app is "unknown" → cascade fail-closed → all frames `.suppress` on `reason=7`. This is the safe direction but it makes the allowlist unreachable; capture can never flip default-ON without the allowlist; the allowlist needs `appBundleId` to key on.
- **`PrivacyTombstone.appBundleId`** is already wired through the cascade output and IPC `0x03` payload (PRs #24/#44) but it always carries the empty/nil value at suppress time, so tombstones cannot answer "1Password fired the cascade" vs "an unrelated app did" — undermining the recall-UI privacy-moment surface (ADR-0013 §4).
- **The brain value-prop** (DESIGN.md §15 Phase 3) requires knowing "what app + what site + what page was on screen when this frame happened." Without context-join the recall index is a pile of screenshots with no anchors. Phase 3 cannot start until Phase 2 populates the context.

The DESIGN.md §15 Phase 2 line — "NSWorkspace + Accessibility + AppleScript browser URL. Onboarding/permission flow." — is the canonical scope. This ADR locks the per-field extraction design, the threading/staleness model, the privacy invariants the cascade depends on, and the PR sequence that lands it.

Strategic note (per `docs/STATE.md` 2026-05-20 reframe): screenpipe has shipped encryption; the §7 secure-surface corpus is now MCI's primary remaining wedge. Phase 2 is not a wedge expansion — it is the connective tissue that makes the §7 wedge **operationally enforceable per-app** (the §1 denylist + the per-app `known-safe-apps.toml` allowlist both run on `appBundleId`). Phase 2 makes Phase-1's privacy guarantee selectable and auditable by app, not just by surface.

## Decision

### 1. Per-field extraction design — APIs, alternatives, rejection reasons

`WorkflowContext` has four fields (`Suppression/SuppressionInputs.swift:130–150`): `appBundleId`, `windowTitle`, `url`, `pageText`. Each gets a dedicated, OS-API-free provider trait + a single production impl in the macOS helper. The cascade still consumes the existing `WorkflowContext` shape — the seam shape does not change.

#### 1.1 `appBundleId` — `NSWorkspace.frontmostApplication.bundleIdentifier`

- **Chosen API:** `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`, polled at **1 Hz** on a dedicated background actor. The 1 Hz cadence intentionally matches `StreamPolicy.cascadeFloorIntervalMs = 1000` from PR #39 — context staleness and cascade-floor heartbeat share the same period, so the worst-case "user app-switched but cascade has not seen it yet" lag is bounded by the same number.
  - Apple ref: <https://developer.apple.com/documentation/appkit/nsworkspace/1532097-frontmostapplication>
- **Alternative rejected — per-frame query in the SCStream callback.** Cost: one `NSWorkspace` call (~100 µs) × ~5 fps × all-day session. At 5 fps that's ≈ 1.8M extra calls/day on the capture hot path for staleness that is at most 1 s better than the polled version. Cascade decisions are not made at frame granularity in practice — they are made at app-switch granularity, which is human-scale (seconds, not frames). Rejected on footprint grounds (AGENT_PROTOCOL §4 / DESIGN.md §4 budget).
- **Alternative rejected — `NSWorkspaceDidActivateApplicationNotification` push.** A push-driven `NSDistributedNotificationCenter` observer would give zero-lag updates on app switch. Real trade-off: notifications can be missed (suspended helper, notification-center backpressure) and there is no "current value" replay — the helper would still need a polled fallback for state at startup. Adding a push observer **plus** the polled fallback is more code, more state, and more failure modes than the polled-only design, for a staleness win (sub-second instead of ≤1 s) that the cascade does not benefit from. **Re-consider** if telemetry (CRS Telemetry-Gap analyst) ever shows >1 s app-switch lag causing a §1 denylist miss in practice. Deferred, not killed.
- **Alternative rejected — pid-from-frontmost-window via `CGWindowListCopyWindowInfo`.** Returns pid, not bundle id; would require a second `NSRunningApplication(processIdentifier:)` lookup; loses nothing over `NSWorkspace.frontmostApplication`. Same data, longer path. Rejected.

#### 1.2 `windowTitle` — `AXUIElementCopyAttributeValue(focusedApp, kAXFocusedWindow → kAXTitle)`

- **Chosen API:** the same AX path PR #38 (§4 backstop) already pays for `kAXSubroleAttribute`. We piggy-back on the existing focused-element traversal: from the AX app reference for the frontmost app, read `kAXFocusedWindowAttribute` then `kAXTitleAttribute`. Cost is one additional AX read on a reference we already had — sub-percent of the §4 footprint budget by inspection.
  - Apple refs: <https://developer.apple.com/documentation/applicationservices/axuielement_h>, attribute constants <https://developer.apple.com/documentation/applicationservices/kaxfocusedwindowattribute>, <https://developer.apple.com/documentation/applicationservices/kaxtitleattribute>.
- **Privacy implication — LOAD-BEARING.** Window titles **are user content**: "Untitled — Notes.app", "Re: Q3 layoffs — Mail", "1password — vault unlock", "Slack | #security-incidents", IM previews. Window titles MUST flow through the ADR-0013 cascade BEFORE storage. The helper never persists a raw `windowTitle` ahead of a cascade decision. Concretely: `windowTitle` is read into the in-process `WorkflowContextSnapshot` actor only; it crosses the cascade boundary only as an input; on `.suppress` it is dropped at the helper boundary per ADR-0013 §2 redaction-before-store; on `.allow` it is permitted to flow downstream (Phase 3 will write it to the encrypted store). Until the §7 corpus is green and the allowlist has its first entry there are **no `.allow` decisions**, so `windowTitle` reaches storage **zero times** during Phase 2.
- **Alternative rejected — `CGWindowListCopyWindowInfo` `kCGWindowName`.** Returns the window name for many windows, but requires no AX permission, AND returns names for *all* on-screen windows (not just the focused one) — a strictly larger surface than what the cascade needs. Picking the right one ("which window is focused?") collapses back to the AX traversal anyway. Rejected on minimum-data-collection grounds (DESIGN.md §9 / ADR-0001).
- **Alternative rejected — title from `SCWindow.title` on the active `SCContentFilter`.** Available, but tied to the filter's snapshot generation (same drift problem ADR-0013 §5 / `DenylistDriftProbe` was added to solve). Worse: the filter's window list lags behind the user's actual focus by an indeterminate amount. Rejected.

#### 1.3 `url` — per-browser AppleScript bridge

- **Chosen API:** a `URLProvider` trait, with one impl per supported browser, dispatched by frontmost bundle id. Each impl issues a single one-line AppleScript ("tell application X to get URL of active tab of front window") via `NSAppleScript`. Supported browsers in this ADR: **Safari, Chrome, Firefox, Arc, Brave, Edge.** (Firefox: AppleScript support is limited to URL-of-front-window — see R2 in DESIGN.md §16; the impl returns `nil` cleanly when AppleScript fails.)
  - Apple refs: `NSAppleScript` <https://developer.apple.com/documentation/foundation/nsapplescript>, Apple Events authorization model <https://developer.apple.com/documentation/security/com_apple_security_automation_apple-events>, and the TCC Automation pane <https://support.apple.com/guide/mac-help/control-access-to-features-mchld5a35146/mac>.
- **First-launch consent (required UX in the agent shell).** Each browser's AppleScript probe requires the user to grant Apple Events permission for that specific (helper) → (browser) pair via **System Settings → Privacy & Security → Automation**. The helper MUST NOT attempt to auto-grant. Concretely:
  - First call per browser per session: the OS prompts the user. If granted → cached for the session. If denied → the per-browser `URLProvider` returns `nil` from then on (no retry storm).
  - The agent shell (apps/agent/) must explain *before* the prompt fires what is being asked for and why ("MCI needs permission to read the active tab URL from Safari so it can index your workflow. Click Allow."). The OS dialog will fire on the first probe attempt against each browser; the shell should pre-stage the explanation so the prompt is not a surprise.
  - The shell exposes a per-browser opt-out (user can decline / revoke at any time → `url=nil` forever for that browser).
- **Alternative rejected (for Phase 2) — WebExtension URL bridge.** WebExtensions can read URLs cleanly without AppleScript at all and bypass the per-browser consent dance. They also require the user to install an extension per browser, which is an entirely separate distribution + update problem. DESIGN.md §15 Phase 7 schedules this as "Browser extension (clean page text)." Phase 2 ships the AppleScript bridge so MCI has *some* URL signal at MVP; Phase 7's extension supersedes when shipped. Rejected for Phase 2 on user-side-install grounds, not on quality.
- **Alternative rejected — DOM scraping via AX (`AXWebArea` + descendants).** Chrome and Safari expose the rendered DOM through AX. We can in principle walk to the URL field. Fragile across browser versions (one Chrome update can shift the subtree shape); higher per-frame cost (deeper traversal) than the cached AppleScript bridge; URL extraction this way is duplicative of what Phase 7's WebExtension will do better. Rejected.
- **Alternative rejected — `~/Library/Safari/History.db` (and equivalents).** Persisted, indexed, easy. Not real-time (the row appears on navigation commit, not on tab switch) and only covers Safari. Rejected on "wrong signal" grounds — we want *active* tab, not *last navigated*.

#### 1.4 `pageText` — **DEFERRED TO PHASE 3 (OCR pipeline)**

- Phase 2 ships with `pageText = nil` everywhere. Per DESIGN.md §15, Phase 3 stands up the Vision OCR pipeline (dirty-rect-scoped) which is the canonical Phase-3 source for page text. The WebExtension page-text bridge (Phase 7) is the second-pass cleaner.
- Privacy framing: this means in Phase 2 the cascade never sees `pageText`, so the §6 "OCR-time secret / PII regex" probe (ADR-0013 cascade §6) is structurally inert this phase, exactly as it has been. No regression, no surprise.

### 2. `ContextProvider` trait — OS-free protocol, headless testability

Mirroring the `SecureEventInputProbe` / `AXSecureSubroleProbe` / `BlackedRegionProbe` pattern already established in `Suppression/SuppressionInputs.swift`, Phase 2 introduces:

```swift
public protocol ContextProvider: Sendable {
    /// Snapshot the current workflow context. Returns the
    /// freshest values the provider has; fields default to nil
    /// when a sub-provider declined / failed / lacks permission.
    func snapshot() -> WorkflowContext
}

public protocol URLProvider: Sendable {
    /// Active-tab URL for the supplied frontmost bundle id, or
    /// nil if this provider does not handle that bundle, the
    /// browser is not running, or Apple Events permission is
    /// denied / revoked. MUST be non-blocking on the hot path.
    func activeTabURL(forFrontmost bundleId: String) -> String?
}
```

Production impls (all in `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Context/`):

- `NSWorkspaceContextProvider` — `appBundleId` only, polled at 1 Hz (§3 below).
- `AXWindowTitleProvider` — `windowTitle` via the existing AX path (PR #38 reuses).
- `AppleScriptURLProvider` — composite. Holds an array of single-browser `URLProvider`s (`SafariURLProvider`, `ChromiumURLProvider` (shared by Chrome/Brave/Edge — same AppleScript dialect), `FirefoxURLProvider`, `ArcURLProvider`); dispatches by frontmost bundle id; falls back to `nil` cleanly when no impl matches.
- `CompositeContextProvider` — assembles the three above into a single `ContextProvider.snapshot()` result; this is the production wiring that the SCStream callback consumes.

Each production impl is matched by a stub impl in tests (`StubContextProvider`, `StubURLProvider`) so the cascade decision logic remains unit-testable headlessly, no OS in the loop. This is the same pattern PRs #36/#37/#38 used for the §7 corpus probes; reusing it is deliberate.

### 3. Polling cadence + threading + bounded staleness

- **One dedicated `WorkflowContextSnapshot` actor** in the helper. It owns the latest `WorkflowContext` value and serializes all writes from background pollers.
- **`NSWorkspaceContextProvider` polls at 1 Hz** on a dedicated `Task` driven by `DispatchSourceTimer` (the same primitive the cascade-floor heartbeat from PR #39 uses). On each tick: read `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`, read window title via AX off the frontmost app, kick the matched `URLProvider` (if any). Push the assembled `WorkflowContext` to the snapshot actor.
- **The SCStream callback** (`SCStreamCaptureSession.swift` `stream(_:didOutputSampleBuffer:of:)`) reads the latest snapshot synchronously — a single async-actor-await is too expensive on the hot path; instead, the snapshot actor exposes a non-blocking `currentSync()` that returns its last stored value (the actor still serializes *writes*). The callback never makes an AX call, never invokes AppleScript, never touches `NSWorkspace` directly.
- **Bounded staleness contract.** The maximum lag between a user app-switch and the cascade seeing the new `appBundleId` is `≤ 1 s` (the polling period). This is the same bound the cascade-floor heartbeat (PR #39) already commits to. The §1 denylist is per-app, not per-frame, so 1 s of lag on the *first* frame after a switch is acceptable. Frames during that 1 s lag are evaluated against the *prior* app's denylist entry — which is still a denylist check, just against the wrong app for ≤1 s. Worst case: a denylisted app is unsuppressed for ≤1 s of frames at the moment of switch-in, after which §1 fires. Mitigated by the fail-safe default (ADR-0013 §3/§7): if the prior app was unknown and the new app is also unknown until the next tick, both windows fail-closed under §7. The window of risk is therefore "user switched from a known-allowed app *into* a denylisted app, and the cascade has not ticked yet" — bounded to 1 s and characterized as acceptable per ADR-0013 §1's per-app (not per-keystroke) granularity. The CRS Telemetry-Gap analyst tracks first-frame-after-switch misses as a `policy_lag_event` metric (content-free, count only).

### 4. Privacy invariants — LOAD-BEARING (CSO veto-gate per ADR-0013 §5 + this ADR)

These invariants are why this ADR is protected-set. Any future PR that weakens any of them requires a fresh CSO amending ADR.

1. **Every `WorkflowContext` field is USER CONTENT.** `appBundleId` reveals what apps the user runs ("com.openai.chat", "com.1password.app", "com.tinder.macos"). URLs include query parameters, doc ids, share tokens. Window titles include doc names, message previews, recipient names. None of these are metadata-by-virtue-of-being-non-pixel. They are content.
2. **Context strings flow through the cascade BEFORE storage.** The helper MUST NOT write raw `WorkflowContext` fields to disk, IPC, or any sink outside the in-process snapshot actor and the cascade input, ahead of a `.allow` decision. This is the ADR-0013 §2 "redaction-before-store guarantee" extended explicitly to context fields. Phase 1 keeps the cascade fail-closed on unknown apps (`reason=7`), so **until the `known-safe-apps.toml` allowlist has its first CSO-gated entry, NO context reaches storage**. Phase 2 ships this property structurally intact.
3. **`PrivacyTombstone.appBundleId` (already in the 0x03 payload, PRs #24/#44) starts carrying real values.** This is the one path on which context reaches the wire today — at suppress time, on a frame already redacted, capped to a length (per the existing PR #44 payload contract). Director-Recording PR P2.5 (§6 below) wires the real value through; CSO sign-off confirms the payload is not widened (still `appBundleId` + reason + counter — no `windowTitle`, no `url`).
4. **First-launch Apple Events consent is user-mediated. The helper MUST NOT auto-grant.** No scripting of `tccutil`, no programmatic permission grants, no "click here to grant" UX that bypasses the OS dialog. The helper falls back to `url = nil` gracefully on denial (`URLProvider.activeTabURL(...)` returns `nil`; cascade carries on; no retry storm).
5. **Threat model — out of scope but documented.** A hostile browser extension could spoof the active-tab URL via AppleScript injection (the extension can register a fake URL in the browser's scriptable surface). MCI is not building anti-malware; if a browser is compromised the URL it reports is whatever the attacker says it is. The same threat exists for any URL-introspection tool on macOS. Documented here so future review does not relitigate. Mitigations explicitly NOT in scope: AppleScript-call integrity verification, browser-extension allowlist enforcement, browser binary signing checks.
6. **No telemetry payload may include raw context fields.** The CRS Telemetry-Gap analyst gets counts only (`policy_lag_event`, `url_provider_denied`, `ax_window_title_failed`). Not the URL itself, not the title, not the bundle id of the affected app. This is the existing `HelperHealthSnapshot` discipline (PR #44 wire 0x03) extended to Phase-2 metrics.

### 5. How this unlocks Phase-1 invariants

- **ADR-0013 cascade §1 (source-level denylist) starts firing.** Currently it cannot fire — `appBundleId == nil`. PR P2.1 + P2.5 make the §1 probe operationally meaningful for the first time. STEP-2-FINDING-001/003/004 closures (PRs #38/#39/#40) hold structurally because §1 only **adds** suppress decisions; it can never widen `.allow`.
- **The `known-safe-apps.toml` allowlist becomes a CSO tool, not a hypothesis.** ADR-0013 §3 / §6 describe a per-app override allowlist for known-safe apps. Until Phase 2, the allowlist key (`appBundleId`) was always nil → no entry could ever match → the allowlist was inert. Post-Phase-2, the CSO can grant capture for specific bundle ids once §7 corpus is green for that bundle. This is the mechanism by which `--capture` eventually flips default-ON (ADR-0013 Amendment 1 §4 — still CSO-gated, this ADR does not change that).
- **`PrivacyTombstone.appBundleId` propagation** through `0x03` payload (PR #44) starts carrying real values. Recall UI privacy moments (ADR-0013 §4) can finally answer "what app fired the cascade" instead of "an app fired the cascade." Trust-by-audit (F-STRAT-001b) becomes specific.

### 6. PR sequence — Director-Recording owns the implementation, CSO gates each

Phase 2 lands in a sequence of small protected-set PRs, mirroring the Phase-1 enabler-PR cadence ratified by ADR-0013 Amendment 1. Each PR carries a CSO sign-off block asserting the §4 invariants above. Director-Recording owns the implementation; CTO arbitrates if any PR drifts across the `core/` seam (the seam SHOULD NOT cross — all Phase-2 work lives in `adapters/macos/MCICaptureHelper/`).

- **P2.1 — `ContextProvider` trait + `NSWorkspaceContextProvider`** (active-app polling at 1 Hz, snapshot-actor, `currentSync()`). Headless unit tests with `StubContextProvider`. 1 cycle.
- **P2.2 — `AXWindowTitleProvider`** reusing PR #38's AX path. Headless tests against the same Cocoa probe-harness app PR #37 stood up (`tools/probe-harness/`). 1 cycle.
- **P2.3 — `URLProvider` trait + `SafariURLProvider`** (Safari first — simplest AppleScript surface, safest test target; Apple-shipped browser, predictable consent dialog). First-launch consent UX in the agent shell (`apps/agent/`). 1 cycle. This is the first PR that touches the agent shell's onboarding flow; CSO reviews the UX copy to ensure invariant §4.4 (no auto-grant) is structurally honoured.
- **P2.4 — `ChromiumURLProvider`** (Chrome / Brave / Edge — shared AppleScript dialect, one impl, three matched bundle ids) **+ `FirefoxURLProvider`** (URL-of-front-window only, per DESIGN.md R2) **+ `ArcURLProvider`** (Arc has its own AppleScript dictionary). Each provider has its own consent dialog; the agent shell explains each. Graceful per-browser failure: Safari granted + Chrome denied → MCI works on Safari URLs, returns `nil` for Chrome. 1 cycle.
- **P2.5 — Wire it into `SCStreamCaptureSession.swift`.** This is the PR where the context snapshot read replaces the all-nil `WorkflowContext(...)` construction at `SCStreamCaptureSession.swift:274–279` and the all-nil return at `:382–389`. CSO-gated: this is the moment context starts reaching the cascade for real. Carries the §4 invariants assertion + a diff-level review confirming the snapshot-read is non-blocking and the `WorkflowContext.windowTitle` / `url` paths cannot bypass the cascade. 1 cycle.
- **P2.6 — Live verification on the Mac (audit doc, no code).** Human-in-the-loop, on the real machine. Reuses the Step-1/Step-2 audit harness pattern. Verifies: cascade sees real bundle id on app switches within 1 s; §1 denylist fires when an entry is added; per-browser consent dialogs fire on first probe; revocation cleanly returns `url = nil`; no PII leaks above what tombstone payloads document; `cascade_forced_count` (PR #44 wire 0x03) unchanged baseline + correct deltas. Output: `docs/audit/2026-XX-XX-phase2-context-join.md`. 1 cycle.

This is six cycles, comfortably inside the Phase-2 envelope. The 3-PRs-per-night-run cap (AGENT_PROTOCOL §1) means Phase 2 takes ≥ 2 night-runs end-to-end.

### 7. Test discipline (binding on every PR in §6)

- **Headless unit tests.** `ContextProvider` + `URLProvider` are pure traits; stub impls cover the cascade decision matrix with explicit `(appBundleId, windowTitle, url)` tuples. Mirrors the `StubSecureEventInputProbe` / `StubAXSecureSubroleProbe` discipline already in place (PRs #36/#37/#38).
- **Integration test — synthetic app-switch lag bound.** A test mode injects synthetic `bundleId` changes into the snapshot actor at 1 Hz and asserts `cascade.decide(...)` sees the new value within bounded lag (≤1 s + 1 tick safety margin). Headless — no OS, no AppleScript, no real frontmost-app. Pins the §3 staleness contract.
- **Privacy tripwire test (CSO-protected).** A test asserts that for any cascade decision that resolves to `.suppress`, none of `WorkflowContext.windowTitle` / `url` / `pageText` reach the storage layer or the IPC sink. **Today this is structurally impossible because no `.allow` path exists** (allowlist empty → fail-closed). The test documents this so future allowlist-population work cannot accidentally relax the invariant — the test will fail loudly if a code path is added that lets context bypass cascade decisions.
- **Live verification (P2.6 only, human-in-the-loop).** The audit doc in `docs/audit/` captures real-machine observations. Not faked. Per AGENT_PROTOCOL §9 hard-stops, footprint claims on this work are also gated; Phase-2 PRs measure incremental cost vs the pre-Phase-2 baseline and report in the PR body.

### 8. Material-choice trade-offs called out explicitly

- **Poll (1 Hz) vs notification (push).** Poll won for simplicity + bounded freshness (1 s lag is acceptable for cascade per §3 above). Push (`NSWorkspaceDidActivateApplicationNotification`) is faster but adds a fallback requirement, more code paths, more failure modes. Re-consider if telemetry shows >1 s lag causing real-world §1 misses.
- **AppleScript vs WebExtension** for URL. AppleScript chosen for Phase 2 (no user-side install). WebExtension is Phase 7's "the right way." This is an interim, not a permanent.
- **Per-browser providers vs unified scraper.** Per-browser, because each browser's AppleScript dialect differs (Safari uses `tell application "Safari" to URL of front document`; Chromium uses `URL of active tab of front window`; Firefox is the most restricted; Arc has its own shape) AND we want graceful per-browser failure modes (Safari granted + Chrome denied → still works on Safari).
- **Window title via AX vs via `CGWindowList`.** AX, because AX gives us the *focused* window directly; `CGWindowList` would give us all windows and force us to re-derive focus, which is what AX already tells us cleanly.
- **`appBundleId` only (Phase 2) vs `appBundleId + appName + pid`.** Bundle id only. Display name is locale-variable and not a stable key; pid is per-launch and not useful for denylist matching. Allowlist keys + denylist keys are both bundle ids.

### 9. Out of scope (explicitly deferred)

- **`pageText`** — Phase 3 (OCR pipeline, dirty-rect-scoped Vision OCR per DESIGN.md §15 Phase 3). The WebExtension page-text bridge (Phase 7) is the second-pass cleaner.
- **WebExtension URL bridge** — Phase 7.
- **Windows context-join** — Phase 8 (`adapters/windows/`). UIA + WinRT analogs; equivalent ADR owed at Phase 8.
- **Cross-browser tab-switch tracking** — Phase 2 captures the FRONTMOST tab's URL only. Multi-tab indexing is a Phase-3+ retrieval question, not a capture question.
- **`URLProvider` for non-listed browsers** (Vivaldi, Opera, Brave Beta, etc.) — opt-in extensions later; out of Phase 2.
- **Auto-flip of `--capture` default-ON** — still ADR-0013 Amendment 1 §4 / CSO-gated. Phase 2 unlocks the `known-safe-apps.toml` allowlist; flipping capture default-ON requires the committed §7 corpus artifact + a fresh CSO sign-off, exactly as ADR-0013 Amendment 1 specifies.

## Consequences

- Positive: ADR-0013 cascade §1 (source-level denylist) becomes operationally meaningful for the first time. The `known-safe-apps.toml` allowlist becomes a CSO tool. Recall-UI privacy moments become specific ("MCI redacted this because 1Password was frontmost") instead of generic ("an app fired the cascade"). The brain value-prop gets its app/site/title anchors so Phase 3 (OCR + brain) can stand on them.
- Positive: the seam shape (`WorkflowContext` struct, cascade trait inputs, IPC `0x03` payload) is unchanged — Phase 2 is purely additive providers, no breaking changes to `core/`, no IPC wire bump (ADR-0014 fd-pass seam unaffected).
- Positive: each per-field provider is independently testable and independently fail-able. A browser revoking AppleScript permission does not break the rest of the pipeline; an unknown app does not break the cascade (fail-closed is intact).
- Negative / tradeoff: per-browser consent dialogs are a first-launch UX cost. Six browsers × one prompt each = up to six "Allow MCI to control X?" dialogs. Mitigated by the agent shell pre-staging the explanation; users who decline some browsers still get partial coverage.
- Negative / tradeoff: window titles are user content, and the cascade now consumes them as inputs. The privacy invariants in §4 above are the mitigation; the tripwire test (§7) makes them structural.
- Negative / tradeoff: 1 Hz polling adds a tiny steady-state cost — one `NSWorkspace` call + one AX read + (when a browser is frontmost) one AppleScript call per second. Within the AGENT_PROTOCOL §4 footprint budget by inspection; PR P2.6 measures and reports actuals.
- Forces (binding on every future PR):
  - **Any context field reaching storage without a cascade `.allow` decision is a §5 protected-set violation.** Period. Includes "just for telemetry," "just for the recall UI's debug pane," "just to render an audit artifact."
  - **Any change to first-launch consent UX requires CSO review.** The non-auto-grant invariant (§4.4) is load-bearing.
  - **Any new browser `URLProvider` requires a fresh per-browser audit** (consent dialog text, denial-graceful-fallback test, integration check that bundle-id dispatch is correct).
  - **Any change widening the per-app override allowlist** (`known-safe-apps.toml`) requires CSO sign-off, exactly as ADR-0013 §3 / §6 already specifies.

## CSO sign-off (placeholder — owed at first protected-set PR in §6)

Protected-set authoring (AGENT_PROTOCOL §5). The §4 privacy invariants — context-as-content, cascade-before-storage, real-value `appBundleId` in tombstone payload, no auto-grant of Apple Events consent — are binding. CSO sign-off blocks are owed on every PR in §6 asserting (by reading the diff) that the invariants hold. CSO veto is final unless the human CEO overrides.

— CSO, pending (this ADR is a CEO ratification gate; CSO sign-off is owed at PR P2.1)

## Director-Recording sign-off (placeholder — owed at PR P2.1)

The Phase-2 PR sequence in §6 is Director-Recording's implementation scope. Acknowledged: every PR in the sequence carries the §4 invariants assertion in its PR body; provider impls live in `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Context/`; the `core/` seam is unchanged; the IPC wire schema is unchanged this phase (PR #44's 0x03 payload already carries the `appBundleId` field, which finally starts carrying real values at P2.5). The first-launch consent UX in the agent shell is a co-owned surface with the (future) Director-Context; for Phase 2 it lives in `apps/agent/` and Director-Recording carries it.

— Director-Recording, pending (owed at PR P2.1)

## References

- ADR-0001 (privacy posture — local-first, E2E, minimum-data-collection), ADR-0003 (no OS code above the `CaptureSource` seam — Phase 2 honors this, all OS code lives in `adapters/macos/`), ADR-0007 (separate signed macOS helper — Phase 2 providers live in the helper), ADR-0013 + Amendment 1 (the cascade Phase 2 feeds; §1 source-level denylist becomes meaningful; §2 redaction-before-store guarantee extends to context fields), ADR-0014 (fd-pass seam — unchanged this phase).
- `docs/STATE.md` (2026-05-20 — Phase 1 close state + screenpipe-encryption reframe → §7 corpus as primary remaining wedge → Phase 2 is connective tissue, not a wedge expansion).
- `docs/AGENT_PROTOCOL.md` §4 (footprint budget, sensitive-capture invariant), §5 (CSO protected-set + veto-gate, dependency-addition rule), §8 (ADR-required for material choices), §9 (autonomous-mode hard stops apply to Phase-2 PRs too).
- `docs/DESIGN.md` §15 Phase 2 ("NSWorkspace + Accessibility + AppleScript browser URL. Onboarding/permission flow."), §16 R1 (permission friction), R2 (browser coverage uneven — Firefox AppleScript gap), R5 (sensitive-capture invariant — Phase 2 does not relax it).
- `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression/SuppressionInputs.swift` — the `WorkflowContext` struct (lines 130–150), the existing probe-trait pattern Phase 2 mirrors (`SecureEventInputProbe`, `AXSecureSubroleProbe`, `DenylistProbe`, `BlackedRegionProbe`, `DenylistDriftProbe`).
- `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/SCStreamCaptureSession.swift` — current all-nil context construction at the SCStream callback (lines 274–279, 382–389). PR P2.5 changes these two sites.
- PR #38 (§4 AX backstop — `AXWindowTitleProvider` reuses this code path), PR #39 (`cascadeFloorIntervalMs` — sets the 1 Hz cadence we match), PR #44 (`0x03` `HelperHealth` payload — already carries `appBundleId`, starts carrying real values at P2.5), PR #37 (`tools/probe-harness/` — `AXWindowTitleProvider` reuses for headless integration tests).
- Apple — `NSWorkspace.frontmostApplication` <https://developer.apple.com/documentation/appkit/nsworkspace/1532097-frontmostapplication>; AX `kAXFocusedWindowAttribute` / `kAXTitleAttribute` (see `AXAttributeConstants.h`); `NSAppleScript` <https://developer.apple.com/documentation/foundation/nsapplescript>; Apple Events authorization (TCC Automation) <https://support.apple.com/guide/mac-help/control-access-to-features-mchld5a35146/mac>.
- Phase-3 dependency: DESIGN.md §15 Phase 3 (OCR + brain) consumes the per-frame `WorkflowContext` Phase 2 produces; `pageText` is filled by Phase 3's Vision OCR.
