# ADR-0030 — Messages + Mail capture redaction threat-model (default-deny until OCR-time redaction lands)

- Status: **Proposed** (2026-05-28; CSO seat draft pending CEO ratification + the implementing PR's cascade-twice integration test green)
- Owners: **CSO** (binding sign-off authority + threat-model author) + **Director-Recording** (cascade §6 OCR-time-regex extension — implementer scope on the follow-on joint PR)
- Reviewers: CEO (ratification); Director-Brain (OCR pipeline / Phase 3 cascade-twice integration — consumer of the redaction layer); CRS Telemetry-Gap analyst (false-positive / catch-rate monitoring); Director-Context (Mail header pre-OCR check — touches WorkflowContext composition)
- Phase: 3 follow-on / Phase 4 onramp. This ADR is the gate that converts the recall-coverage-gap memo's §6 ⚠️ hold into a checkable specification.
- **Protected-set: yes** (AGENT_PROTOCOL §5 — modifies the de-facto policy controlling `known-safe-apps.toml` membership for two of the most-sensitive macOS bundles).
- **Launch-blocker: no** (this ADR does not block Phase 1→2; it gates a specific Phase-4-era allowlist expansion).
- **Relationship:** consumes the ADR-0013 cascade as the always-running pixel-time defense; consumes the ADR-0016 §1.6 cascade-twice-for-OCR mechanism as the place new redaction logic mounts; produces the binding conditions under which the orchestrator-CSO seat may issue a follow-on PR adding `com.apple.MobileSMS` and `com.apple.mail` to `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Resources/known-safe-apps.toml`.

## Context

### The user need

The CEO's daily workflow includes both Messages and Mail. Messages carries SMS-relayed 2FA codes, banking notifications, password-reset SMS, and personal threads. Mail carries password-reset links, banking statements, and personal correspondence. The cycle 8.13 dogfooding session surfaced (per `docs/research/recall-coverage-gap-2026-05-26.md`) that Recall UI shows Safari events only because the cascade fail-safe drops every frame from non-allowlisted apps. The CEO's stated need: **make Messages and Mail surface in Recall** so the brain has the daily context the CEO actually works in.

### The sensitivity surface

Messages and Mail are the two highest-sensitivity bundles in macOS by content type:

- **SMS-relayed 2FA codes.** Apple iPhone-Continuity mirrors SMS to the Mac; these messages render in `com.apple.MobileSMS` as plaintext. The codes are valid for minutes-to-hours and grant access to bank, email, work-SSO, and crypto-exchange accounts.
- **Banking notifications.** Fraud-alert SMS, transaction-confirmation prompts, large-charge confirmations. All in plaintext rendered text.
- **Password-reset links.** Account-recovery URLs delivered over SMS and email are bearer credentials — anyone who possesses the URL completes the reset.
- **Authentication-app fallback codes.** When a user can't get a TOTP from Google Authenticator / Authy / 1Password / Duo, services often issue a fallback OTP via SMS. The shapes are detectable.
- **Personal threads + banking statements + medical mail.** Beyond authentication, the content type itself is high-privacy in a way that ordinary OCR'd Slack/Linear/Figma content is not.

### Why the existing cascade doesn't catch plaintext display

The ADR-0013 cascade has seven arms. Six of them (§1 source-level `SCContentFilter` denylist, §2 OS-blacked-region, §3 `IsSecureEventInputEnabled`, §4 AX-secure-subrole, §5 post-capture denylist re-check, §7 fail-safe-unknown) operate on the **typing surface** — they fire when the user is *entering* a credential or when the *focused element is a secure field*. None of them fire when the user is **passively viewing** rendered Messages or Mail content. The §6 OCR-time secret/PII regex is the only cascade arm that operates on rendered text — but in the current implementation it is tuned for general-purpose secret patterns (per ADR-0013 §6 reliance on the SecretBench corpus, recall 52–88%) and was never tuned for SMS-OTP / banking-notification shapes, because Messages and Mail were never on the allowlist.

This ADR-0030 fills that gap. It specifies the additional OCR-time redaction layer that must exist (and be measured against a committed corpus) before either bundle can be added to the allowlist.

### Why the memo §6 ⚠️ block held the bundles back

The recall-coverage-gap memo §6 P0 dispatch explicitly excluded `com.apple.MobileSMS` and `com.apple.mail` from the cycle 8.13 PR #215 (Claude Desktop + GitHub Desktop) and recorded:

> ⚠️ **CSO threat-model required before adding Messages or Mail.** … the cascade's `.secureInput` arm only fires during *password-prompt focus*, NOT during plaintext display. Adding either bundle naively would weaken the "sensitive-capture is a launch blocker" invariant (ADR-0013 §4 / AGENT_PROTOCOL §4 R5). … The default-deny posture stays in force for both until CSO issues a written threat-model ratifying them (likely with additional OCR-time redaction rules for SMS-shaped strings and bank-domain mail headers). **Do NOT add Messages or Mail in the P0 dispatch.**

PR #207 CSO pass-2 backed the hold. This ADR is the threat-model the hold was waiting on. **The CSO §5 sign-off on this ADR does NOT itself authorize the allowlist edit.** Per §3(e) below, the allowlist edit ships only after the implementation PR's corpus run reports ≥99% catch on `docs/research/sms-2fa-test-corpus-shapes.md` plus the consequence requirements in §4 below.

## Decision

### 1. The default-deny posture is binding until §3(a)–(d) implement

`com.apple.MobileSMS` and `com.apple.mail` remain absent from `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Resources/known-safe-apps.toml` until **all of** the following hold:

1. The §3(a) SMS-OTP / banking-notification regex set is committed at `core/brain/redaction/sms_otp.rs` (or equivalent — final path picked at implementing PR).
2. The §3(b) `sensitive-domains.toml` seed is committed and the OCR-time pipeline reads from it via a single `SensitiveDomainTable` accessor.
3. The §3(c) Mail header pre-OCR check is wired into the cascade-twice path.
4. The §3(a) corpus (`docs/research/sms-2fa-test-corpus-shapes.md`) runs against the implementation and achieves ≥99% catch + ≤5% false-positive on the H- (honey) entries. The result is committed as a corpus-run artifact under `docs/audit/2026-XX-XX-messages-mail-redaction-corpus.md`.
5. The implementing PR carries a CSO sign-off block asserting (a)–(d) above plus the ADR-0013 §5 + Amendment 1 §3 four-condition structural assertions.

If any of (1)–(5) is absent at PR-review time the PR is rejected. There is no "we will add the corpus run in a follow-up." Per ADR-0013 §5: privacy ships with the capture path, never later.

### 2. Conditions under which Messages and Mail may be added

When §1's gate (1)–(5) holds, the allowlist edit ships as a separate, single-purpose PR (mirrors ADR-0029 §5 sign-off-protocol: "The default-ON flip PR is a separate commit from the corpus artifact PR. It is never bundled."). Per-bundle entries:

```toml
[[entries]]
bundle_id = "com.apple.MobileSMS"
rationale = "Messages.app. SMS-shape redaction (§3(a)) + bank-domain table (§3(b)) gate the rendered text on every cascade-twice pass per ADR-0030. Per-conversation opt-in is the v2+ posture (§3(d) deferred). Corpus run artifact: docs/audit/2026-XX-XX-messages-mail-redaction-corpus.md."
cso_ratified_by = "CSO seat (ADR-0030 corpus-run sign-off)"
ratified_at = "2026-XX-XX"

[[entries]]
bundle_id = "com.apple.mail"
rationale = "Mail.app. Mail header pre-OCR check (§3(c)) refuses any frame whose rendered From-header matches §3(b)'s domain set, regardless of body content. SMS-shape redaction (§3(a)) also runs on the body for defense-in-depth. Corpus run artifact: same as above."
cso_ratified_by = "CSO seat (ADR-0030 corpus-run sign-off)"
ratified_at = "2026-XX-XX"
```

The exact `cso_ratified_by` and `ratified_at` values are filled in by the implementing PR.

### 3. Required redaction additions (the spec)

#### 3(a) SMS 2FA / banking-notification shape regex set

A regex set runs at OCR-time over every `OCREvent` payload from a Messages-foregrounded or Mail-foregrounded frame. The set covers:

- **Apple shapes.** `### is your Apple ID Verification Code…`, `Your Apple ID Code is: …`, Apple Pay card-verification SMS shape, iCloud verification SMS shape. See corpus class A.
- **US bank issuer-prefix shapes.** Chase, Bank of America, Wells Fargo, Capital One, Citi, U.S. Bank, PNC, Truist, TD Bank, Goldman Sachs / Marcus / Apple Card, Discover, Amex, Charles Schwab, Fidelity, Venmo, Cash App, PayPal, Zelle, Coinbase, Kraken, Robinhood, Ally, USAA, Navy Federal. See corpus class B (top-30 issuer-name + code shape).
- **Generic carrier OTP shapes.** Twilio Verify default templates, Android `[#]`-prefixed SMS-Retriever shapes, iOS WebKit `<#>`-prefixed app-domain-bound shapes, the proximity rule `\b\d{4,8}\b` within 20 chars of `code | verify | OTP | PIN | verification | passcode | one-time`. See corpus classes C and D.
- **Auth-app code-display shapes.** Google Authenticator, Authy, 1Password, Duo, Microsoft Authenticator notification mirrors. See corpus class E.
- **Password-reset / account-recovery SMS shapes.** Apple account-recovery, generic `your password reset code is …`, magic-link URLs, NIST SP 800-63B social-engineering-warning shapes. See corpus class R.

The corpus lives at `docs/research/sms-2fa-test-corpus-shapes.md`. **Catch rate must be ≥99% before any allowlist entry can ship** (§1 gate condition (4)). False-positive rate against the H- (honey) entries must be ≤5%.

When the regex set fires, the cascade emits a `PrivacyTombstone(reason=6)` (the existing OCR-time-regex reason code, per ADR-0013 §4 + ADR-0016 §1.6) and the event is dropped at the helper boundary. No OCR'd text bytes cross IPC; no keyframe blob is written; no brain entry is created. Per ADR-0016 §4.2 cascade-twice mechanics.

The corpus is a living document with a quarterly refresh cadence; each refresh is a PR-of-the-corpus with its own CSO sign-off (mirrors ADR-0017 §3.1 allowlist signed-update discipline).

#### 3(b) Bank-domain / password-reset URL list

A second OCR-time table runs over the same `OCREvent` payload. The table lives at `docs/research/sensitive-domains.toml` and covers:

- **Top 50 US banks by assets** (FDIC SDI Q4-2025 snapshot). See the `[[us_bank]]` array.
- **5 high-volume US credit unions** (Navy Federal, SECU NC, PenFed, BECU, SchoolsFirst). See the `[[us_credit_union]]` array.
- **Top 10–15 international banks** (SWIFT BIC registry top tier, public retail-banking domains). See the `[[intl_bank]]` array.
- **Fintech payment apps + crypto exchanges** (PayPal, Venmo, Cash App, Stripe, Plaid, Zelle, Robinhood, SoFi, Coinbase, Kraken, Binance US, Gemini). See the `[[fintech]]` array.
- **Auth providers** (Auth0/Okta, Microsoft Entra ID, Google Identity Platform, Apple Sign In, Clerk, WorkOS, Stytch, Supabase Auth, Firebase Auth, AWS Cognito, Ping, Frontegg, Hanko, Magic, OneLogin, JumpCloud). See the `[[auth_provider]]` array.
- **Password-reset / OAuth-callback URL patterns** (OWASP ASVS v4 §2.5 + RFC 6749 §4.1.2 conventions). See the `[[url_pattern]]` array.

Subdomain match: `domain` matches the eTLD+1 and all subdomains. `url_pattern.regex` matches against the full URL.

When any OCR'd text on a Messages or Mail frame contains a URL whose host eTLD+1 matches an entry in `sensitive-domains.toml`, OR contains text matching one of the `url_pattern.regex` entries, the cascade emits a `PrivacyTombstone(reason=6)` and the event is dropped at the helper boundary.

**Update cadence:** quarterly. The CSO seat publishes a refresh PR; each refresh carries a CSO sign-off block asserting no entry has been silently downgraded and no entry has been removed without rationale. The `last_reviewed` field in the TOML tracks the cadence.

**Source citation:** see the source comments at the head of `sensitive-domains.toml`. FDIC SDI for US banks, SWIFT BIC for international, each vendor's public docs for auth providers, OWASP ASVS + RFC 6749 for URL patterns.

#### 3(c) Email-header pre-OCR check

This is the Mail-specific layer. Where Messages has a single content area, Mail has a structured `From:`/`To:`/`Cc:`/`Bcc:`/`Subject:` envelope that surfaces in the rendered window before the body. The cascade-twice pipeline gains a **Mail-header pre-OCR check** as a new arm of the cascade-on-OCR'd-text pass:

1. The OCR worker on a Mail-foregrounded frame produces line-grouped text via `VNRecognizeTextRequest.recognitionLevel = .accurate` (already the Phase 3 default per ADR-0016 §1.1).
2. **Before** the body content is concatenated into the `OCREvent.ocr_text` payload, the cascade scans the top-N OCR'd lines (default N=8) for a line matching `^(From|De|Von|从|発信者): .*<email@domain>` — RFC 5322 `From:` header rendered by Mail.app.
3. If the matched domain (eTLD+1 of `email@domain`) appears in `sensitive-domains.toml`, the **entire OCR event is refused** — no body OCR'd text reaches the wire, no keyframe is written, a `PrivacyTombstone(reason=6)` is emitted.
4. The match is structural, not text-content: only the From-line text is inspected; the body bytes are dropped before any other cascade or storage logic touches them.

The N=8 line-scan budget is bounded; the check runs in sub-millisecond time on M-series hardware (no Vision call; just regex over already-OCR'd lines).

**Threat addressed:** a Mail frame whose `From:` is `secure@chase.com` containing transaction details that don't themselves match any §3(a) SMS shape or §3(b) URL pattern — the body is still presumed sensitive because the sender is. This is the bank-statement-mail case the §6 ⚠️ block called out.

**Defense-in-depth chain on Mail frames:** §3(c) header check → §3(b) URL/domain check on the body → §3(a) SMS-shape check on the body → cascade fail-closed default per ADR-0013 §7. Any one of these firing drops the event.

#### 3(c)(ii) Parsed-header check for emlx deep-hook (V2-P8b)

**Amendment landed inline with V2-P8b** (`apps/agent/src/mail_ingest.rs` + `core/brain/src/redaction/parsed_mail_header.rs`). Companion arm to §3(c) — same intent, different input shape.

**Why the amendment is needed.** §3(c) was written against the **OCR-input path** — Mail.app's rendered preview frame, top-N OCR'd lines from `VNRecognizeTextRequest`. V2-P8a (PR #243) shipped `mci-mail-reader`, a READ-ONLY library that streams new `.emlx` files from `~/Library/Mail/V<N>/.../*.emlx` directly via FSEvents. V2-P8b consumes that stream inside `mci-agent`. The same Mail-spike-memo §9 retrospective made clear that §3(c)'s "top-N OCR'd lines" framing does NOT literally transfer to emlx ingest — RFC 5322 header position is not the rendered Mail.app preview position; routing X-headers and `Received` chains precede `From:` in well-routed mail. The mechanism §3(c) specifies (regex over rendered lines) is the wrong shape for emlx; the **intent** (refuse the frame when the sender domain is in `sensitive-domains.toml`) holds and needs a parallel rule.

**§3(c)(ii) spec.** For any new emlx flowing through the brain-ingest mail pump (`apps/agent/src/mail_ingest.rs::MailIngestPump`), the cascade-equivalent (`core/brain/src/redaction/parsed_mail_header.rs::cascade_equivalent`) is the **pre-write** check. It runs BEFORE any body byte is materialized into a brain [`Event`] row. Inputs are the typed-RFC-5322 header subset (`mail-parser`-typed accessors); outputs are one of three structural outcomes:

1. **`Allow`** — full body + headers persist as a normal Event row. The pump then runs §3(a) + §3(b) over the body for defense-in-depth (per the chain above).
2. **`HeaderOnly { sender_domain, reason }`** — body bytes are DROPPED at the pump; only a content-free audit row is persisted. The persisted row has `app_bundle_id="com.apple.mail"`, `window_title="[REDACTED:MAIL_HEADER_MATCH]"` (literal placeholder), `text="[REDACTED:MAIL_HEADER_MATCH] from=<sender_domain>"` (categorical eTLD+1 only — the CSO-curated public marketing domain that fired the cascade, not user-identifying content), `url=None`, `tab_id=None`. Subject text, body bytes, recipient lists, `Message-ID`, attachments — none of these reach `put_event`. The `MailRedactionReason` sub-rule (sensitive-sender-domain / subject-otp-shape) surfaces in `MailIngestCounters` for the CRS Telemetry-Gap analyst, never in a brain-row column.
3. **`Refuse { reason: UnparseableEnvelope }`** — fail-safe default (ADR-0013 §7 transposed). When the emlx has no parseable `From:` header, NO row reaches `put_event` at all. The pump bumps its `refused` counter; the user-curated allowlist UI (V2-P10) surfaces an aggregate count, never the file path.

**Decision order inside `cascade_equivalent`:**

1. Empty `from_domain` → `Refuse { reason: UnparseableEnvelope }` (fail-safe).
2. Any of `from_domain`, `reply_to_domain`, `sender_domain`, `list_id_domain` matches a `sensitive-domains.toml` entry → `HeaderOnly { reason: SensitiveSenderDomain }` with `sender_domain` = the eTLD+1 that fired (first hit, in the fixed order above).
3. `subject` matches a §3(a) SMS-OTP / banking-notification shape → `HeaderOnly { reason: SubjectOtpShape }`.
4. Otherwise → `Allow`.

Step 2's fan-out beyond `From:` to `Reply-To:` / `Sender:` / `List-ID:` answers the §11 Q4 phishing-shape memo: a bank-impersonation mail with `From: notify@chase.com` but `Reply-To: attacker@example.com` is still dropped on the `From:` match; a mailing-list bridge with friendly `From:` but `List-ID: <chase.com>` is dropped on the `List-ID:` match. DKIM `d=` verification is deferred to v2+ (CPU + complexity).

**Single source of truth.** §3(c)(ii) consults the same `docs/research/sensitive-domains.toml` table and the same `core/brain/src/redaction/sms_otp.rs` regex bank as §3(c) (OCR-path) and §3(a) (SMS-shape). The trust-boundary is one set of CSO-curated artifacts; the two arms differ only in input shape.

**Drop-before-write discipline.** `cascade_equivalent` is structurally guaranteed to run BEFORE any `put_event`. The pump's `ingest_path` calls `read_message(path) → cascade_equivalent → match`; the `HeaderOnly` and `Refuse` arms construct (or do not construct) a row with the body bytes dropped at the cascade decision point. There is no delete-after-write path. CSO sign-off audit verifies this against the diff (see PR body).

**Wire posture.** No wire bump. The cascade-equivalent runs entirely inside `mci-agent`; no helper produces a `MailHeaderMatch` byte. The new sub-rule enum (`MailRedactionReason`) is local to the brain crate — it is NEVER emitted on the helper-to-agent IPC wire, and consequently does NOT extend the wire-protected `mci_core::ipc::RedactionReason` enum (which would otherwise need a wire bump per AGENT_PROTOCOL §5). The conceptual "PrivacyTombstone(reason=mail-header-match)" is the categorical class string returned by `MailRedactionReason::tombstone_reason`; it surfaces in audit/telemetry strings only.

**Defense-in-depth on `Allow` outcomes.** When `cascade_equivalent` returns `Allow`, the pump must still pipe the body through §3(a) (SMS-shape regex) and §3(b) (URL/domain table) before final persist. Those two sub-arms are the existing redaction layer (PR #222) applied to the emlx body in the pump (the OCR-path applies them to the rendered top-N + body in the helper). This module owns ONLY the §3(c)(ii) parsed-header arm; the body sub-arms remain the same back-ends.

**Defense-in-depth chain on emlx deep-hook ingest (V2-P8b):** §3(c)(ii) parsed-header check → §3(b) URL/domain check on the body → §3(a) SMS-shape check on the body → fail-safe default. Any one firing drops the body bytes from the persisted row (or, for `Refuse`, drops the row entirely).

**Falsifiability corpus.** The §3(c)(ii) gate is a runnable corpus at `core/brain/src/bin/mail_cascade_corpus.rs`. Per-PR audit artifact committed at `docs/audit/2026-05-30-mail-cascade-corpus.md` shows **GREEN 5/5** across the five harnesses (H1 bank `From:`, H2 non-sensitive sender, H3 SMS-OTP subject, H4 no parseable `From:` → fail-safe refuse, H5 `List-ID:` bridge). Determinism witness: re-running the binary produces a byte-identical artifact.

**Relationship to §3(c) (OCR-path).** §3(c) and §3(c)(ii) are independent arms; both ship and both run on their respective inputs. A user who has Messages-foregrounded with a Mail-app preview pane open exercises §3(c) on the rendered frame; the simultaneous emlx file landing in `~/Library/Mail/V<N>/.../` exercises §3(c)(ii) on the parsed file. They do not duplicate; they complement.

#### 3(d) Per-conversation opt-in vs blanket capture

The question: should the user be able to opt in **per-thread** ("MCI may capture this conversation with X") rather than opting in to **blanket Messages capture**?

**Decision: blanket-capture-with-redaction is v1; per-conversation opt-in is v2+ (deferred).** Reasoning:

- **Argument for per-conversation opt-in.** Maximizes user agency. The user explicitly chooses which conversations to capture; everything else stays redacted at the source. UX-clean.
- **Argument against per-conversation opt-in (v1).** UX cost is large: the user must classify hundreds of threads up-front; new threads default to OFF and require manual promotion; conversations frequently shift subject mid-thread (a personal exchange may end with a 2FA code paste); the user's mental model is "MCI either watches Messages or it doesn't," not "MCI watches these threads and not those threads." A v1 product with per-conversation opt-in degrades into the "MCI is paused" state because users don't promote threads they should.
- **Posture v1 (this ADR):** blanket capture for `com.apple.MobileSMS` once §3(a)–(c) implement. The redaction layer is the trust boundary, not user-curated thread allowlists. The user gets a global per-app toggle (the existing menu-bar pause) and the cascade-twice mechanics guarantee that 2FA / banking / password-reset content does not reach the brain even on captured threads.
- **Posture v2+ (open question, deferred):** an in-recall-UI "remove this thread from MCI's memory" surface (per ADR-0017 §4.2 per-event/per-app delete with crypto-shred) gives the user the equivalent power post-capture rather than pre-capture. This shifts the UX cost from "promote threads up-front" to "remove a thread on retro discovery" — a smaller-but-non-zero ask. The v2+ surface is owed at ADR-0017 Phase 4 P4.6 retention-controls work.

The per-thread opt-in path stays an open design question in `docs/AGENT_QUESTIONS.md` (see §6 below). It is not blocking v1.

#### 3(e) Default-deny posture (binding)

Until all of §3(a)–(d) implement, are tested by the §1 gate-condition (4) corpus run, and the corpus artifact is committed, `com.apple.MobileSMS` and `com.apple.mail` stay OUT of `known-safe-apps.toml`. **This is non-negotiable and is a CSO veto-gate per AGENT_PROTOCOL §5.** Flipping either bundle into the allowlist without §1's five conditions is rejected at PR review regardless of other merits — exactly as ADR-0013 §5 phrases the cascade-without-suppression rejection rule.

Equivalent to: per ADR-0013 §3 fail-safe-default-redact + ADR-0016 §4.2 cascade-twice-for-OCR + ADR-0017 §3.1 CSO-gated allowlist, this ADR adds **content-class-specific redaction** as a precondition for the allowlist edit. The default-deny is not a vibes-judgment; it is a defined, checkable mechanism gated on a runnable corpus.

## Consequences

### What changes when this ADR is implemented

- **Director-Recording OCR pipeline gains a new pre-write filter layer.** The cascade-twice OCR-time arm (ADR-0016 §1.6) grows three new sub-arms: (a) SMS-OTP / banking-notification regex set, (b) sensitive-domain / URL-pattern table, (c) Mail-header pre-OCR check. All three are gated by app-bundle: they run only for `com.apple.MobileSMS` and `com.apple.mail` frames (zero-cost on every other app's frames).
- **The follow-on PR is a joint Director-Recording + CSO PR.** Director-Recording owns the helper-side OCR pipeline; CSO owns (this ADR's) threat-model + the corpus + sign-off. The allowlist edit itself ships as a third, separate PR (per §2 above) after the corpus run is green.
- **The recall-coverage-gap memo §6 ⚠️ hold is lifted** once §1's five conditions hold. The CEO regains Recall coverage over the two highest-sensitivity bundles, with content-aware OCR-time redaction as the binding trust boundary instead of "Messages is on the allowlist; trust the cascade arms that don't fire on rendered text."
- **`docs/research/sms-2fa-test-corpus-shapes.md` and `docs/research/sensitive-domains.toml` become living artifacts** with quarterly CSO-signed refreshes. The CRS Telemetry-Gap analyst surfaces `ocr_text_secret_match_count` deltas; sharp moves (a new bank surfaces, a regex starts firing on a normal pattern) trigger a refresh PR.
- **Phase 4 retention UI inherits the cascade reason code.** ADR-0017 §5.2's reason-code table already lists `6 (OCR-time regex secret/PII)` with friendly string "Text matched a secret/PII pattern." Privacy-Moments cards for redacted Messages/Mail content surface with this reason. No schema change.

### What stays the same

- **Cascade arms §1–§7 are unchanged.** Pixel-time defense layers stay exactly as ADR-0013 specifies. This ADR adds to the cascade's OCR-time arm (per ADR-0016 §1.6); it does not weaken or alter the pixel-time arms.
- **ADR-0013 §4 HEVC blob persistence gate is unchanged.** Keyframe blob writes for Messages/Mail follow the same default-OFF discipline as every other app — the helper has no `MCI_DB_KEY_HEX` in shipped builds (per recall-coverage memo Q4 "default-OFF surface is HEVC blob persistence, not SCStream itself"), so no encrypted blobs land regardless. Phase 3 P3.5/P3.6 OCR text persists; pixels do not.
- **ADR-0029 corpus-gate criteria are unchanged.** This ADR's corpus is a separate, narrower-scope artifact targeting Messages+Mail specifically; the Phase 1→2 §7 corpus stays the gate for the global capture default-ON flip.
- **Zero-knowledge invariant (ADR-0001 + ADR-0012)** is unchanged. The redaction layer runs in the helper before any wire crossing, before any encrypted-blob write, before any sync delta is produced. Same trust boundary as every existing cascade arm.
- **Per-app menu-bar pause (ADR-0017 §2.2)** continues to work for Messages and Mail exactly as for any other app once they are on the allowlist.

## Alternatives considered

### (i) Ship Messages/Mail capture without OCR-time redaction (rejected)

Add both bundles to `known-safe-apps.toml` and trust the existing cascade. **Rejected — invariant violation.** ADR-0013 §4 / AGENT_PROTOCOL §4 R5: sensitive-capture is a launch blocker. The cascade's `.secureInput` arm fires only during password-prompt focus, not during plaintext display. SMS 2FA codes / banking notifications / password-reset URLs would flow straight through OCR → embedding → brain without redaction. The recall-coverage-gap memo §6 ⚠️ block explicitly rules this out and PR #207 CSO pass-2 backed the hold. This alternative is the failure mode the ADR exists to prevent.

### (ii) Require user-typed allowlist per-conversation / per-sender (rejected for v1)

The user explicitly chooses every Messages thread and every Mail sender that MCI may capture. **Rejected for v1 — UX cost too high.** See §3(d) above. The product collapses to the "MCI captures nothing because the user never finishes promoting threads" state. A v2+ retroactive-deletion surface (ADR-0017 P4.6) gives equivalent agency at a smaller UX cost; that's the deferred path. This ADR's §3(d) keeps the question open in `docs/AGENT_QUESTIONS.md`.

### (iii) Defer indefinitely (rejected)

Wait until a future phase to revisit Messages and Mail capture. **Rejected — CEO needs the capability now.** Per the dispatch and the recall-coverage-gap memo: Messages and Mail are core to the CEO's daily workflow; without them, Recall has a hole in the most-used part of the day. The ADR exists to convert "indefinite hold" into "checkable gate" so the capability can ship as soon as the gate passes — which is on the order of one Director-Recording cycle's work plus a CSO-signed corpus run.

### (iv) Use a third-party PII detector library instead of a curated corpus (rejected)

E.g., Microsoft Presidio, Google DLP API equivalent on-device, AWS Comprehend's PII recognizer ported to ONNX. **Rejected** for two reasons:

1. **The zero-network thesis (ADR-0001 + CLAUDE.md + ADR-0016 §4.4) is non-negotiable.** Google DLP and AWS Comprehend are remote APIs. Presidio is on-device but bundles a multi-megabyte spaCy model that violates the footprint SLO (AGENT_PROTOCOL §4 / ADR-0016 §3 per-component cap).
2. **The general-purpose PII detector is the wrong tool for SMS-shape detection.** SecretBench (the corpus ADR-0013 §6 already references) reports best-tool recall 52–88% on general secrets — well below the ≥99% threshold a Messages/Mail allowlist gate requires. A narrow, curated, corpus-tested regex set tailored to the specific shapes that surface in the SMS-relay + bank-issuer channel gets ≥99% by construction because the corpus IS the gate.

## Open questions

The following are escalated to `docs/AGENT_QUESTIONS.md` per AGENT_PROTOCOL §7 — owed at the implementing PR or at CEO ratification of this ADR:

1. **Per-thread opt-in surface in v2+.** ADR-0017 P4.6's retention UI is the natural home for a "MCI may not capture this thread" toggle. Concrete design owed at Phase 4 work; this ADR keeps the question open.
2. **iMessage attachments (images, PDFs).** This ADR specifies redaction over the OCR'd **rendered text** of a Messages frame. Image attachments rendered inside Messages (a photo of a bank card, a screenshot of an OTP) are OCR'd by the same pipeline — the §3(a) regex set catches the SMS-shape text inside them, but a frame consisting of nothing but an image of a credit card (no text rendering OTP shapes) would clear the regex. Q: do we want a Vision-classifier image-content check at OCR-time? Out of scope this ADR; appended to AGENT_QUESTIONS for CRS arxiv-OSS analyst evaluation. Note: ADR-0013 §1 source-level `SCContentFilter` excludes private-window attachments via `NSWindowSharingType.none`; this question concerns attachments displayed in a non-private Messages window.
3. **Mail-renderer variants beyond Mail.app.** This ADR covers `com.apple.mail` specifically. Spark, Airmail, Mimestream, Apple Mail in iOS-style condensed layout — all have different `From:`-line rendering. Q: do we extend the bundle list, or do we keep this ADR scoped to Mail.app and write a fresh ADR per third-party mail app? Recommendation: scoped to Mail.app v1; per-renderer ADRs as the CEO adds them.
4. **Bank-domain table maintenance authority.** Currently CSO seat quarterly. Q: should `docs/research/sensitive-domains.toml` accept community-PR additions, or stay CSO-only? Recommendation: CSO-only v1; revisit if the cadence proves too slow.
5. **What happens when a Messages frame contains an SMS forwarded from a non-iPhone source.** Android-paired-via-iCloud SMS, third-party RCS bridges, mock SMS for testing. Q: do their shapes diverge enough from the corpus that catch rate drops below 99%? Recommendation: track via the CRS Telemetry-Gap analyst's `ocr_text_secret_match_count` per-app counter; treat regressions as a corpus-refresh trigger.

## References

- **ADR-0001** (privacy posture — local-first, E2E, zero-network thesis).
- **ADR-0012** (zero-knowledge spec tightening — same-user-accessible plaintext residency rules).
- **ADR-0013** + Amendment 1 (the cascade — §1–§7 arms, §4 redaction-before-store, §6 OCR-time regex foundation this ADR builds on, §5 launch-blocker placement).
- **ADR-0015** (Phase 2 context join — populated `appBundleId` is what gates the §3(a)–(c) sub-arms in this ADR; they only run when `appBundleId in {com.apple.MobileSMS, com.apple.mail}`).
- **ADR-0016** §1.6 (cascade-twice for OCR — the mechanism this ADR's redaction layer mounts on) + §4.2 (cascade-twice invariant) + §4.4 (no network in any Phase 3 component — binding on the redaction layer).
- **ADR-0017** §3.1 (allowlist CSO-gated discipline — this ADR's §2 follows the same shape) + §5.2 (cascade-reason-code table — reason=6 for OCR-time secret/PII fires here) + §4.2 (per-event/per-app delete — the v2+ posture for per-thread opt-in).
- **ADR-0029** (Phase 1→2 §7 corpus gate criteria — same gate-criteria-as-checkable-standard discipline this ADR borrows).
- **`docs/research/recall-coverage-gap-2026-05-26.md`** §6 ⚠️ block — the memo that mandated this ADR.
- **`docs/research/sms-2fa-test-corpus-shapes.md`** — the corpus this ADR's §3(a) catch-rate gate runs against.
- **`docs/research/sensitive-domains.toml`** — the domain table this ADR's §3(b) and §3(c) consume.
- **PR #207** (recall-coverage-gap memo merge + CSO pass-2 backing the hold) — the prior-art that mandated this ADR.
- **PR #215** (Claude Desktop + GitHub Desktop low-sensitivity allowlist additions, cycle 8.13) — the precedent for the per-bundle CSO-signed allowlist edit pattern this ADR's §2 follows.
- **`adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Resources/known-safe-apps.toml`** — the allowlist this ADR's §2 edits ship into.
- **`adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression/SuppressionCascade.swift`** — the cascade this ADR's §3(a)–(c) sub-arms mount under cascade §6.
- **AGENT_PROTOCOL §4** (sensitive-capture launch-blocker invariant), **§5** (CSO protected-set + veto-gate), **§7** (escalation discipline).
- **OWASP ASVS v4.0.3 §2** (Authentication) — the threat-model foundation for the SMS-OTP corpus + the §3(b) URL pattern set. <https://owasp.org/www-project-application-security-verification-standard/>
- **NIST SP 800-63B** §5.1.3 (Out-of-Band Authenticators) — the threat model behind treating SMS-OTP as bearer credentials. <https://pages.nist.gov/800-63-3/sp800-63b.html>
- **FFIEC Authentication and Access to Financial Institution Services and Systems** (2021) — bank-issued OTP-via-SMS category guidance and the basis for the §3(b) US bank table source. <https://www.ffiec.gov/press/PDF/FFIEC_authentication.pdf>
- **Apple Privacy / TCC docs** — `developer.apple.com/documentation/security` (Privacy & Data) and `support.apple.com/HT204915` (Apple ID two-factor authentication) underpin the §3(a) Apple-shape corpus entries A-01 through A-05.
- **Krebs on Security** — the SIM-swap and SMS-OTP threat-actor reporting that motivates treating displayed OTPs as bearer credentials even when the user can see them on their own device (because Recall would index them, the attacker doesn't need to swap the SIM if the brain is exfiltrated).

## CSO §5 sign-off

This ADR is **protected-set authoring** (AGENT_PROTOCOL §5). I, the CSO seat, have reviewed the threat model, the corpus shape, and the gate conditions in §1, §2, and §3. **The default-deny posture in §3(e) is binding** on every PR opened against `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Resources/known-safe-apps.toml` until the §1 gate-conditions (1)–(5) are all met, the §3(a) corpus catch rate hits ≥99% on the committed corpus run, and a CSO sign-off block on the implementing PR asserts (by reading the diff) that the four ADR-0013 Amendment 1 §3 structural conditions plus this ADR's §1 conditions hold.

The implementing PR — the follow-on Director-Recording + CSO joint PR that lands the §3(a)–(c) redaction layer + commits the corpus-run artifact — **MUST cite this ADR by number (ADR-0030)** in its PR title and body, and **MUST NOT bundle the allowlist edit**. The allowlist edit ships as a third, separate PR (per §2 above) after the corpus run is green, mirroring the ADR-0029 §5 "default-ON flip PR is a separate commit from the corpus artifact PR" discipline.

Any PR that materializes a path for Messages or Mail OCR'd text to reach storage without passing through the §3(a)–(c) sub-arms is a §5 protected-set violation and is rejected at CSO review regardless of other merits — exactly as ADR-0013 §5 phrases the cascade-without-suppression rejection rule. The CSO veto is final unless the human CEO overrides.

— CSO, 2026-05-28

## CSO §5 sign-off (V2-P8b amendment, 2026-05-30)

This amendment extends ADR-0030 with **§3(c)(ii) — parsed-header check for the emlx deep-hook path (V2-P8b)**. The §3(c) (OCR-path) arm is unchanged. The §3(c)(ii) arm is the structural place ADR-0030's intent applies to the always-on emlx deep-hook the agent runs via `mci-mail-reader` (V2-P8a, PR #243).

**Four-condition audit (the CSO veto-gate the V2-P8b implementing PR satisfies):**

1. **ADR-0030 §3(c)(ii) preserves the existing §3(c) OCR-time arm semantics** — only the input shape (typed RFC 5322 vs OCR-rendered lines) differs. The domain table back-end (`sensitive-domains.toml` + `SensitiveDomainTable`) and the OTP regex bank (`sms_otp.rs`) are SHARED. There is one CSO-curated source of truth. I have read the diff and confirm `core/brain/src/redaction/parsed_mail_header.rs` consumes `super::sensitive_domains::matches_sensitive_domain` and `super::sms_otp::redact_sms_shapes`; it does NOT vend a parallel table.
2. **Sender-domain check happens BEFORE body persist (drop-before-write, not delete-after-write).** I have read `apps/agent/src/mail_ingest.rs::MailIngestPump::ingest_path`. The call order is: `mci_mail_reader::read_message(path) → to_parsed_headers(&parsed) → cascade_equivalent(&headers) → match`. The `HeaderOnly` arm builds a content-free row that contains NO body bytes (the `body_text` / `body_html` fields from the parsed message are never read in this arm). The `Refuse` arm builds no row. There is no `put_event` call on the body-bearing path. The body bytes from the source emlx file structurally cannot reach the brain store.
3. **Corpus 5/5 GREEN.** Committed at `docs/audit/2026-05-30-mail-cascade-corpus.md`. I have read the artifact and the per-harness threat models. H1 (bank `From:`), H2 (non-sensitive sender, allow), H3 (OTP-shape subject), H4 (no parseable `From:` → fail-safe refuse), H5 (`List-ID:` bridge) all match the expected `MailCascadeDecision`. Determinism: re-running the binary produces a byte-identical artifact (`git diff docs/audit/2026-05-30-mail-cascade-corpus.md` after a second invocation is empty).
4. **PrivacyTombstone(mailHeaderMatch) is content-free.** The persisted Event row for a `HeaderOnly` outcome contains: `app_bundle_id="com.apple.mail"`, `window_title="[REDACTED:MAIL_HEADER_MATCH]"` (literal), `text="[REDACTED:MAIL_HEADER_MATCH] from=<eTLD+1>"` (categorical eTLD+1 = the CSO-curated public marketing domain that fired the cascade), `ts_us=file mtime`, `url=None`, `tab_id=None`. No subject text, no body bytes, no recipient list, no `Message-ID`, no URL. The sender eTLD+1 is a class signal (you got mail from a bank), not user-identifying content; it is the same signal the user already trusted the CSO to seed into `sensitive-domains.toml`.

**Wire posture confirmation.** The new `MailRedactionReason` enum is LOCAL to `core/brain/src/redaction/parsed_mail_header.rs`. It is NOT exposed on the helper IPC wire and does NOT extend `mci_core::ipc::RedactionReason`. The wire is unchanged at `0x07`. No wire bump.

**Synthesized fixtures only.** I have verified that the corpus runner inlines five synthetic `ParsedMailHeaders` values constructed in source. The corpus binary does NOT open `~/Library/Mail/`, does NOT touch any real emlx file, and does NOT require Full Disk Access at build / test time. The runtime path (the pump consuming FSEvents) is exercised only by the unit tests in `mail_ingest.rs`, which write synthesized emlx fixtures into a `tempdir` and never touch the real Mail store.

**Allowlist edit posture.** `com.apple.mail` was already added to `known-safe-apps.toml` in PR #228 (cycle 8.16). This V2-P8b PR does NOT touch `known-safe-apps.toml`; the capture-side allowlist policy is unchanged. The §3(c)(ii) arm is the deep-hook-path redaction layer required to keep ADR-0030's intent honored on the second Mail surface the agent now consumes (emlx files via `mci-mail-reader`); it does NOT widen what `com.apple.mail` is allowed to do.

**Scope discipline.** This PR does NOT modify the helper capture path, the cascade-twice OCR-time arm, ADR-0031 focused-window logic, the wire protocol, or any other §5 protected-set surface beyond ADR-0030 + the new brain-side / agent-side modules added here.

**Approved.** The V2-P8b implementing PR satisfies the §3(c)(ii) amendment's gate conditions. Production deployment of `MailIngestPump` in `mci-agent`'s supervisor remains gated on V2-P10's user-curated allowlist UI (the CEO must opt-in via the user-visible surface before the pump auto-starts). This PR ships the LIBRARY surface only; the supervisor wire-up is a separate, CEO-attended PR.

— CSO, 2026-05-30
