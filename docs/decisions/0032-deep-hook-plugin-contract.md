# ADR-0032 — Deep-hook plugin contract (cascade-equivalent for non-OCR sources)

- Status: **Proposed** (2026-05-29; CSO seat + Director-Recording joint draft; CEO ratification on V2-P7 PR merge)
- Owners: **CSO** (binding sign-off authority on the per-plugin cascade-equivalent invariant) + **Director-Recording** (plugin contract implementation, V2-P7 / V2-P8 / V2-P9 implementers)
- Reviewers: CEO (ratification on V2-P7 PR merge); Director-Brain (consumer of plugin-emitted CaptureEvents); Director-Context (V2-P10 onboarding UX, FDA permission gate); CRS Telemetry-Gap analyst (per-plugin counter `plugin_redactions_count{plugin_id, reason}`).
- Phase: 3.x (capture-source plurality). First implementation lands as V2-P7 (Messages.app SQLite deep hook).
- **Protected-set: yes** (AGENT_PROTOCOL §5 — establishes a NEW ingest path that bypasses the pixel-time SCStream cascade entirely; the cascade-equivalent in this ADR is the *only* defense against sensitive content reaching the brain by that path).
- **Launch-blocker: no** for V2-P7 (Messages is already on the allowlist per PR #228 — the plugin is additive, not a relaxation; the brain-ingest plumbing remains default-OFF per V2-P10).
- **Relationship:** amends ADR-0013 §1 + §4 (cascade is no longer the only ingest gate — every per-plugin event runs through a cascade-equivalent first); amends ADR-0016 §1.6 + §4.2 (cascade-twice is OCR-specific; the plugin path has its own equivalent); amends ADR-0017 §3.1 (the user-curated allowlist surface — formal version lands in V2-P10); extends ADR-0030 §3 with §3(f) (per-plugin redaction arm). Pairs with ADR-0031 §1 (OCR-input scope) — ADR-0031 governs the pixel/OCR path, this ADR governs every plugin path.

## Context

### The cycle 8.18 lesson

Cycle 8.16's PR #228 added `com.apple.MobileSMS` and `com.apple.mail` to the cascade allowlist, with ADR-0030 §3(a)–(c) as the OCR-time redaction floor. That path covers ONE shape of access: SCStream pixels → Vision OCR → text → cascade-twice → brain ingest. The CEO's vision (brain-v2 memo §5.5) requires a SECOND shape: read the source store directly. Messages.app stores every message in a SQLite database at `~/Library/Messages/chat.db`; reading that database under Full Disk Access is faster, more accurate, and carries per-row metadata (sender handle, service, thread guid, timestamps) the OCR path never recovers.

The risk: the SQLite read path bypasses the cascade entirely. Every defense ADR-0013 / 0015 / 0016 / 0017 / 0030 / 0031 mounts on SCStream is **structurally inert** on a plugin-emitted event. Naively ingesting chat.db rows would put SMS-OTP codes, banking notifications, and password-reset URLs into the brain even with the OCR-path cascade running.

This ADR establishes the equivalent of the cascade for any non-OCR ingest source.

### Why the OCR-time cascade does not generalize

ADR-0013 cascade arms §1–§7 fire on pixel/OCR boundaries:

- §1 `SCContentFilter` denylist — pixel-time source filter; not invoked when reading SQLite.
- §2 OS-blacked region — pixel-time mask; not invoked.
- §3 `IsSecureEventInputEnabled` — keystroke-tap signal; not invoked.
- §4 `kAXSecureTextFieldSubrole` — AX focus probe; not invoked.
- §5 post-capture denylist re-check — frame-time; not invoked.
- §6 OCR-time secret/PII regex — works ONLY on OCR'd text bytes from a pixel frame.
- §7 fail-safe-unknown — frame-time default.

None of these arms fires on a chat.db row. Six of the seven are structurally pixel-bound; the seventh (§6 OCR-time regex) operates on the wrong input class (OCR'd pixel text vs. SQLite-rendered text). ADR-0030 §3(a)–(c) extends §6 with SMS-OTP-shape + sensitive-domain + Mail-header gating — but the bundle-keyed gate (`bundle_is_in_scope`) is still keyed on `OCREvent.app_bundle_id`, which a plugin event does not carry.

The plugin contract specified below mounts the **same redactors** (`sms_otp::redact_sms_shapes`, `sensitive_domains::matches_sensitive_domain`) on a NEW event class so the trust boundary is preserved by reuse, not reinvention.

### What this ADR does NOT do

- Does NOT relax any ADR-0030 §3(a)–(c) semantics on the OCR path.
- Does NOT widen the cascade's pixel-time arms; ADR-0013 §1–§7 remain unchanged.
- Does NOT itself enable plugin ingest; V2-P7's `MessagesPluginConfig::DEFAULT` ships with `plugin_enabled = false`. The V2-P10 onboarding flow is what flips the master switch behind an explicit user opt-in.
- Does NOT widen the cascade allowlist. `com.apple.MobileSMS` and `com.apple.mail` are already on the allowlist (PR #228); the plugin path is an additional ingest source for those bundles, not a new bundle.

## Decision

### 1. Every deep-hook plugin runs through a cascade-equivalent BEFORE brain ingest

A plugin event MUST NOT reach the brain store, the encrypted blob store, or any embedding/retrieval surface without first passing through a per-plugin cascade-equivalent that enforces:

1. **Defense-in-depth reuse.** The cascade-equivalent reuses the same `sms_otp` regex set and the same `sensitive_domains` table the OCR-time arm uses. Plugin-emitted text MUST receive the same OTP/banking-shape scrubbing the OCR path does. No new redactor class is invented; only the trigger is new.
2. **Per-event drop / redact decision.** Each event's cascade-equivalent returns either `drop_event = true` (with a stable, content-free `drop_reason`) or `drop_event = false` plus a `redacted_body` where every §3(a) regex match is replaced in place with the rule-class replacement token. The drop / redact decision is final at the cascade-equivalent boundary; brain ingest never re-decides.
3. **Surfacing for telemetry.** The decision yields a `fired_rules: Vec<&'static str>` and a stable enum `drop_reason`. The agent emits `plugin_redactions_count{plugin_id, drop_reason}` and `plugin_redactions_count{plugin_id, rule}` content-free counters via the CRS Telemetry-Gap analyst's existing surface.
4. **Zero-cost on the hot path.** The cascade-equivalent is invoked exactly once per plugin event, on the plugin's polling thread, after the source read. The helper's hot path (SCStream / OCR) is untouched.
5. **No additional content surface.** The cascade-equivalent has access only to fields the plugin already exposes. It does NOT open a second source-read, does NOT escalate to remote endpoints, does NOT consult any out-of-band signal.

### 2. The V2-P7 §3(f) Messages.app cascade-equivalent (binding)

The first implementation under this contract is `core/brain/src/redaction/messages_plugin.rs` (V2-P7). Its decision order (first match wins) is:

| # | Predicate | Drop reason | ADR §3(f) source |
|---|---|---|---|
| 1 | `plugin_enabled = false` | `PluginDisabled` | This ADR §3(b) default-OFF |
| 2 | `body = None` (attachment-only) | `PluginNoBody` | This ADR — no body, no ingest |
| 3 | Any participant ∈ `participant_denylist` | `ParticipantDenylisted` | User-curated opt-out |
| 4 | `allow_all_participants = false` AND no participant ∈ `participant_allowlist` | `ParticipantNotAllowlisted` | V2-P10 explicit-allowlist mode |
| 5 | Any participant matches `sensitive_domains` | `SensitiveParticipantDomain` | ADR-0030 §3(b) reuse |
| 6 | Body contains a URL / host matching `sensitive_domains` | `SensitiveUrlInBody` | ADR-0030 §3(b) reuse |
| 7 | §3(a) `redact_sms_shapes` fires | (no drop — in-place redaction) | ADR-0030 §3(a) reuse |

Predicate 7 is non-dropping: matched OTP/banking shapes are replaced in place with `[REDACTED:SMS_OTP]` / `[REDACTED:BANK_NOTIFICATION]` (same tokens, same discipline as the OCR-time arm). The cascade-equivalent is not "more lenient than the OCR-time arm" — every shape the OCR arm drops, the plugin arm also catches (the OCR arm drops the entire FRAME; the plugin arm drops the entire EVENT for predicates 1–6, and redacts in place for predicate 7, mirroring the OCR-time `redact_sms_shapes` behaviour). The §3(c) Mail-header check has no Messages equivalent (Messages has no envelope header), so the analogue is the sensitive-participant-domain check (predicate 5).

### 3. Default-OFF + FDA onboarding

#### 3(a) Master switch

`MessagesPluginConfig::DEFAULT` ships with `plugin_enabled = false`. No `chat.db` row reaches the brain without an explicit user opt-in. V2-P10 (the user-curated allowlist + onboarding UI) is the surface that flips the master switch.

#### 3(b) Full Disk Access permission gate

Reading `~/Library/Messages/chat.db` requires macOS Full Disk Access. The V2-P7 read library (`mci-messages-reader`) surfaces this as `MessagesReaderError::AccessDenied` on every read attempt without the grant. The V2-P7 CLI (`messages-reader`) prints a one-line "grant Full Disk Access" hint; the equivalent surface in the production agent is owed to V2-P10's onboarding UI. The V2-P7 PR ships the **stub** (the error variant + the CLI hint); V2-P10 wires the **UI gate** (a permission card with a deep-link into System Settings).

#### 3(c) Allow-all-participants by default

`MessagesPluginConfig::DEFAULT::allow_all_participants = true`. Until V2-P10 ships, every participant is implicitly allowed; the cascade-equivalent runs the §3(a) regex + §3(b) URL check on every participant's message. V2-P10 flips `allow_all_participants = false` and lands the per-participant allowlist UI. This staged rollout preserves the trust posture (no content escapes redaction) while letting the deep-hook ingest plumbing land before the onboarding UI is ready.

#### 3(d) Per-thread opt-in is V2+ (ADR-0030 §3(d) discipline)

This ADR does NOT specify a per-thread opt-in surface. ADR-0030 §3(d) already decided "blanket-capture-with-redaction is v1; per-conversation opt-in is v2+ (deferred)." That decision generalizes to plugin events: the V2-P7 cascade-equivalent is the trust boundary, not user-curated thread allowlists. ADR-0017 P4.6's retro-delete UI is the natural home for any per-thread "remove from MCI's memory" surface in v2+.

### 4. The corpus gate (binding)

A 5-class corpus runs against the V2-P7 §3(f) cascade-equivalent. The committed artifact `docs/audit/2026-05-30-messages-plugin-corpus.md` is the GREEN gate. Per ADR-0030 §1 condition (4) and ADR-0029 §5 corpus-then-flip discipline:

| Class | Description | Gate |
|---|---|---|
| **MS-** | SMS-OTP shapes (Messages context) | Catch ≥99% |
| **MB-** | Bank-notification shapes (Messages context) | Catch ≥99% |
| **MU-** | Sensitive URL / host in body | Drop ≥99% |
| **MP-** | Sensitive participant (e.g. `alerts@chase.com`) | Drop ≥99% |
| **MH-** | Honey / adversarial (must NOT drop or redact) | FP ≤5% |

The overall gate is `(catch ≥99% on MS+MB+MU+MP) AND (FP ≤5% on MH)`. PR review MUST verify the committed artifact reports GREEN on every class.

### 5. Per-plugin redaction extension pattern (forward-looking)

Future plugins (V2-P8 MailAppPlugin, V2-P9 KeystrokeIngestPlugin) follow the same shape:

- A per-plugin module under `core/brain/src/redaction/<plugin>_plugin.rs`.
- A per-plugin event struct projecting the source store / API shape.
- A per-plugin `XxxConfig` struct that ships `DEFAULT` with `plugin_enabled = false`.
- A per-plugin `redact_<plugin>_event(evt, cfg) -> Decision` entry point.
- A per-plugin corpus + committed artifact + per-class catch/FP gate.
- The CSO sign-off block on each implementing PR asserts the four ADR-0013 Amendment 1 §3 structural conditions + the ADR-0030 §1 / §3(f) gate conditions.

This ADR is the contract; each per-plugin PR is the bound implementation.

### 6. CSO sign-off (binding)

The CSO seat hereby attests on behalf of the V2-P7 PR:

1. **The cascade-equivalent reuses §3(a) + §3(b) without modification.** `messages_plugin::redact_messages_plugin_event` calls `sms_otp::redact_sms_shapes` and `sensitive_domains::matches_sensitive_domain` directly. No new regex, no new domain, no shortened decision path.
2. **Drop / redact decisions are final at the cascade-equivalent boundary.** Brain ingest in V2-P10's plumbing consumes `MessagesPluginDecision::drop_event` and `MessagesPluginDecision::redacted_body` without re-deciding.
3. **Default-OFF master switch.** `MessagesPluginConfig::DEFAULT::plugin_enabled = false`; no `chat.db` row reaches the brain in shipped V2-P7 binaries until V2-P10 flips it.
4. **READ-ONLY contract preserved.** The `mci-messages-reader` crate opens `chat.db` with `SQLITE_OPEN_READ_ONLY` only; `#![forbid(unsafe_code)]` is set on the lib body. No new write surface to a user-owned SQLite file.
5. **Synthesized fixtures only.** Every test in `mci-messages-reader/tests/` materializes a synthesized `chat.db` into a `tempfile::tempdir()`. No real user content reaches the test surface.
6. **The §4 corpus is GREEN.** The committed artifact at `docs/audit/2026-05-30-messages-plugin-corpus.md` reports GREEN on all 5 classes; the runner is deterministic (`cargo run -p mci-brain --bin messages_plugin_corpus --release` reproduces the artifact byte-for-byte).
7. **ADR-0030 §3(f) is additive.** §3(a)/(b)/(c) semantics are unchanged; §3(f) layers on top with the same redactors. No relaxation of any existing arm.
8. **No edit to `known-safe-apps.toml`.** `com.apple.MobileSMS` is already on the allowlist (PR #228); V2-P7 is a NEW ingest path for that bundle, not a new bundle.

— CSO + Director-Recording (joint), 2026-05-29

## Consequences

### Positive

- A new ingest source class (deep-hook plugins) becomes safe to add behind a per-plugin CSO-signed corpus gate.
- The V2-P7 / V2-P8 / V2-P9 PRs can land sequentially with the same shape — the contract is the template.
- The same redactors serve both the OCR-time and plugin-time paths; one set of regexes to maintain.
- V2-P10's onboarding flow gets a clean default-OFF surface to wrap: a permission card + a master-switch UI element, both backed by structural defaults.

### Negative / cost

- One per-plugin cascade-equivalent module per supported plugin. The cost grows linearly with plugin count.
- A V2-P10 user who flips `plugin_enabled = true` without curating the per-participant allowlist gets the broadest (most defensive) posture — the §3(a) regex + §3(b) URL check on every message. This is intentional; the cost is paid in occasional `[REDACTED:SMS_OTP]` substitutions on benign messages, not in leaked content.
- The corpus gate is per-plugin: V2-P8 (Mail) and V2-P9 (Keystroke) will each ship their own.

### Footprint discipline

The cascade-equivalent is a pure-Rust regex + static-table lookup. No new allocation per event beyond the `String::to_string` inside `redact_sms_shapes`. AGENT_PROTOCOL §4 R2 footprint envelope (≤ ~1–2% of one CPU core / ≤ ~250 MB RAM on an all-day session) is preserved.

### Compliance with existing invariants

- **AGENT_PROTOCOL §4 R5 sensitive-capture launch-blocker**: preserved. Plugin-emitted content cannot reach the brain without passing the cascade-equivalent.
- **AGENT_PROTOCOL §5 protected-set**: this ADR + the V2-P7 PR carry CSO sign-off blocks.
- **ADR-0001 zero-network thesis**: preserved. The plugin reads a local SQLite file; the cascade-equivalent is pure-Rust regex + static lookup; no network.
- **ADR-0030 §3(e) default-deny**: preserved. The cascade-equivalent ships default-OFF; V2-P10 is the explicit opt-in.
- **ADR-0031 focused-window scope**: orthogonal. ADR-0031 governs the pixel/OCR path; this ADR governs every plugin path. The two arms are independent.

## Alternatives considered

### (i) Run plugin events through the OCR-time cascade-twice arm (rejected)

Re-shape every plugin event into a synthetic `OCREvent` so the existing cascade-twice OCR arm fires on it. **Rejected.** The OCR-time cascade is bundle-keyed on `app_bundle_id`; reusing it would require synthesizing an `app_bundle_id` for every plugin event AND inventing a "no-pixel cascade pass" that bypasses arms §1–§5 (which all assume pixel input). The result is a one-off shim per plugin with no clean separation. The per-plugin cascade-equivalent in this ADR is cleaner: one redactor module per plugin, with a stable contract.

### (ii) Defer the cascade-equivalent entirely; trust the source app (rejected)

Reason: "iMessage is end-to-end-encrypted; the source rows are already trusted." **Rejected — invariant violation.** ADR-0013 §3 fail-safe-default-redact treats every input as untrusted at the cascade boundary. The fact that iMessage encrypts content in transit does not mean a captured plaintext SMS-OTP is safe to embed and index. AGENT_PROTOCOL §4 R5 sensitive-capture launch-blocker is binding regardless of the source's trust posture.

### (iii) Per-thread opt-in as v1 (rejected for v1)

See §3(d). ADR-0030 §3(d) already rejected this for the OCR-time arm; the same UX-cost reasoning applies to the plugin arm.

### (iv) Ship V2-P7 with brain-ingest plumbing wired (rejected for v1)

Wire the cascade-equivalent's output to the brain store in the V2-P7 PR. **Rejected — too much surface for one PR.** V2-P7 is the read library + the cascade-equivalent + the corpus. V2-P10 is the brain-ingest plumbing + the onboarding UI. Splitting the work is consistent with the AGENT_PROTOCOL §1 "one logical change per branch" discipline and lets the CSO veto-gate on V2-P10 focus on the ingest plumbing without re-reviewing the cascade-equivalent.

## Status — V2-P7 PR is the implementing PR for this ADR

The V2-P7 implementing PR (`claude/director-recording/v2-p7-messages-plugin`) lands:

1. `adapters/macos/mci-messages-reader/` (READ-ONLY adapter crate).
2. `core/brain/src/redaction/messages_plugin.rs` (the cascade-equivalent — this ADR §2).
3. `core/brain/src/bin/messages_plugin_corpus.rs` (the corpus runner — this ADR §4).
4. `docs/audit/2026-05-30-messages-plugin-corpus.md` (the committed GREEN artifact).
5. This ADR.
6. The CSO sign-off block in the PR body asserting the §6 conditions.

V2-P10 (the brain-ingest plumbing + onboarding UI) is the follow-on PR that lifts the `plugin_enabled = false` default; that PR carries its own CSO sign-off block per AGENT_PROTOCOL §5.

## Cross-references

- **Brain v2 memo:** `docs/research/brain-architecture-v2-vision-2026-05-29.md` §5.5 (deep-hook plugin contract) + §6.1 E2 (protected-set escalation) + §6.2 (cascade-equivalent for non-OCR sources) + §7.3 V2-P7 (this PR's spec).
- **ADR-0013** + Amendment 1: the cascade arms this ADR adds a peer to.
- **ADR-0017** §3.1 + §4.2: user-curated allowlist discipline + retro-delete surface.
- **ADR-0030** §3(a)/(b)/(c)/(d)/(e): the OCR-time redaction layer this ADR's §3(f) extends.
- **ADR-0031**: focused-window OCR-input scope — the OCR-path peer of this ADR.
- **V2-P7 read library:** `adapters/macos/mci-messages-reader/`.
- **V2-P7 cascade-equivalent:** `core/brain/src/redaction/messages_plugin.rs`.
- **V2-P7 corpus runner:** `core/brain/src/bin/messages_plugin_corpus.rs`.
- **V2-P7 committed corpus artifact:** `docs/audit/2026-05-30-messages-plugin-corpus.md`.
