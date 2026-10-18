# Secret matrix — what Hippocampus skips or refuses before it stores (2026-10-17)

This is the outside judge for one launch claim: **Hippocampus does not store the sensitive things on this list.** It is not a self-assessment — every PASS below is a synthetic screen run through the exact policy code the signed helper runs, with an assertion that fails the build if the drop regresses. It is deliberately honest about what it does **not** catch.

No absolute claim is made here. This matrix shows, case by case, *which rule fires* and *which test proves it*, and names every case that a person must confirm on a real Mac or that is a documented limitation.

## How to reproduce

```sh
env -i HOME="$HOME" USER="$USER" TMPDIR="$TMPDIR" LANG=en_US.UTF-8 \
  PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  nice -n 15 scripts/launch/secret-matrix/run.sh
```

The run below was green except where a row says otherwise:

- Rust redaction unit tests (sms_otp, messages_plugin, sensitive_domains, ocr_secrets, mod): PASS
- Rust cross-engine parity (core/brain/tests/reading.rs): PASS
- Swift matrix (SecretMatrixTests): PASS
- Swift corroborating suites (NeverReadPasswordManagers / Denylist / BrowserPrivateWindow / SuppressionCascade / ConcreteProbes): PASS

## What a "synthetic screen" is, and what this does not do

The suppression cascade is OS-API-free by design (`SuppressionCascade.swift`): it takes an app bundle id, a window title, a URL, OCR lines with positions, and three OS signals (the Carbon secure-input bit, the focused element's AX subrole, an OS-blacked region), and returns allow or suppress. A synthetic screen is exactly that input, all strings invented. The harness injects only the three OS signals (they cannot be produced headlessly); every rule under test — the denylist, the browser checks, the secret regex — is the real shipping code, not a copy.

Production posture is reproduced exactly: `admissionPolicy: .ordinaryApplications` (what `Sources/MCICaptureHelper/main.swift` passes — Hippocampus reads ordinary apps and relies on the cascade, it is not an allowlist-only capture), the full browser bundle set, and the real `SensitiveCaptureDenylist` rules. **No screenshot is taken and no real memory is read.**

What this does not do: it does not render real pixels through PP-OCR, and it does not run the live Carbon/AX/ScreenCaptureKit APIs. Those are covered by the probe tests (`CarbonSecureEventInputProbeTests`, `AXSubroleProbeTests`) and by the on-device checks in the "needs a person" section.

## The cascade, in order (first match wins)

Reference for the "rule" column. From `SuppressionCascade.decide` + the OCR-time pass in `OCRPostAllowEmitter.handleOCRResult`:

1. **§1 denylist-source** — app bundle / URL / window title is on the never-read list.
2. **§2 os-blacked-region** — the OS already renders the window black to capture.
3. **§3 secure-event-input** — `IsSecureEventInputEnabled()` is true (a password field, sudo, a vault unlock, anywhere in the login session).
4. **§4 ax-secure-subrole** — the focused element is an `AXSecureTextField`.
5. **§5 denylist-postcapture** — a denylist edit the live filter has not caught up to.
6. **§6 ocr-time-secret** — the OCR'd text matches one of four secret shapes; checked on the raw read, the reading-order text, and the exact stored text.
7. **§7 failsafe-unknown** — anything the cascade cannot positively classify as non-secure is dropped (AX must *affirmatively* say non-secure to allow; `nil` is a drop).

## The matrix

| # | Case (synthetic screen) | Verdict | Rule that fires | Proving test(s) |
| - | ----------------------- | ------- | --------------- | --------------- |
| 1 | Password field active (secure input on) — any app | PASS | Cascade §3 — IsSecureEventInputEnabled() | SecretMatrixTests.testSecretMatrix; CascadeSecureEventInputTests; CarbonSecureEventInputProbeTests |
| 2 | Focused element is a secure text field (AXSecureTextField) | PASS | Cascade §4 — kAXSecureTextFieldSubrole | SecretMatrixTests.testSecretMatrix; CascadeAXSubroleTests; AXSubroleProbeTests |
| 3 | Visible password inside a password-manager / authenticator window (15 bundles checked; e.g. 1Password, Apple Passwords, Bitwarden, Dashlane, KeePassXC, Keeper, NordPass, Proton Pass, Enpass, Yubico Authenticator) | PASS | Cascade §1 — SensitiveCaptureDenylist.appBundles + passwordManagerFamilies (whole-app skip; the window is never read, so a password shown in it is never captured) | SecretMatrixTests.testSecretMatrix; NeverReadPasswordManagersTests (.verified = 76 identifiers across 66 bundle-id families, each with a cited source) |
| 4 | Private browser window — Firefox (title ends "— Private Browsing") | PASS | Cascade §1 — window title marker (BrowserPixelCapturePolicy.titleIsPrivate) | SecretMatrixTests.testSecretMatrix; BrowserPrivateWindowTests.testEachPrivateTitleMarkerSkipsTheWindow |
| 5 | Private browser window — Chrome "New Incognito Tab" / Edge "New InPrivate tab" | PASS | Cascade §1 — window title marker | SecretMatrixTests.testSecretMatrix; BrowserPrivateWindowTests.testEachPrivateTitleMarkerSkipsTheWindow |
| 6 | Private browser window — "Incognito"/"InPrivate"/"Private" badge in the top bar (for a window with no private title, e.g. a navigated Chrome/Brave/Safari window) | PASS | Cascade §1 — top-bar read (BrowserPixelCapturePolicy.topBarFinding), top 120 pt only | SecretMatrixTests.testSecretMatrix; BrowserPrivateWindowTests.testIncognitoInTheTopBarSkipsTheFrameButIncognitoOnThePageDoesNot, testTheTopBarIsTheTop120PointsOfTheWindowOnly |
| 7 | Bank / sign-in page open in a browser (by URL): accounts.google.com, secure.chase.com, bankofamerica.com, login.microsoftonline.com | PASS | Cascade §1 — SensitiveCaptureDenylist.sensitiveDomains (host + subdomain match) | SecretMatrixTests.testSecretMatrix; CascadeDenylistTests.testURLDenylistMatchSuppresses; NeverReadPasswordManagersTests.testPasswordManagersWebVaultsAreNeverRead |
| 8 | Bank / sign-in page with the address in the top bar, or a page titled with the address | PASS | Cascade §1 — BrowserPixelCapturePolicy.namesDeniedSite (address bar / title) | SecretMatrixTests.testSecretMatrix; BrowserPrivateWindowTests.testASignInOrBankAddressInTheTopBarSkipsThePage, testAPageTitledWithASignInOrBankAddressIsSkipped |
| 9 | API key / token printed in a terminal (AWS access key id; GitHub PAT). The frame clears the pixel-time cascade, then the OCR text is dropped. | PASS | Cascade §6 — OCR-time secret regex (SuppressionCascade.decideOcr, patterns 2 & 3) | SecretMatrixTests.testSecretMatrix; core/brain reading.rs cross-engine parity; ocr_secrets::tests |
| 10 | API key / token / JWT in a text editor (token = "…"; api_key = …; a JWT) | PASS | Cascade §6 — OCR-time secret regex (patterns 1, 2 & 4). Re-checked on the raw join, the reading-order text, and the exact stored text (OCRPostAllowEmitter.handleOCRResult). | SecretMatrixTests.testSecretMatrix; ocr_secrets::tests; BrowserPrivateWindowTests.testPasswordFieldsPasswordManagersAndSignInSitesStayNeverRead |
| 11 | One-time code shown on screen in a chat app and captured by OCR (e.g. "Your verification code is 123456") | needs a person | NOT covered on the OCR path — a bare numeric OTP is not one of the four §6 shapes (PRIVACY.md:72, SECURITY.md:29). Covered only on the Messages/Mail deep-hook INGEST path (Case O2). | SecretMatrixTests.testSecretMatrix (asserts the current, documented behavior); see ignored test testGAP_onScreenOtpOnOcrPathIsNotRedacted |
| 12 | Credit-card number typed in a plain text editor and captured by OCR ("4111 1111 1111 1111 …") | needs a person | NOT covered — there is no credit-card / Luhn / PAN detector on any storage path. Only a soft instruction to the local model (apps/mind/.../Prompts.swift:27) asks it not to record card numbers; that is not a hard filter. Documented in PRIVACY.md:96. | SecretMatrixTests.testSecretMatrix (asserts the current, documented behavior); see ignored test testGAP_creditCardOnOcrPathIsNotRedacted |
| O2 | One-time code / bank alert in a message, via the Messages or Mail **deep-hook ingest** (opt-in; the path that reads the Messages/Mail store directly, not OCR). E.g. "Your Apple ID code is 123456". | PASS | ADR-0030 §3(a) sms_otp + §3(b) sensitive_domains, gated to com.apple.MobileSMS / com.apple.mail (redaction::bundle_is_in_scope); wired in apps/agent/src/messages_ingest.rs BEFORE storage. | messages_plugin::tests::sms_otp_shape_is_redacted_but_ingested, bank_notification_shape_is_redacted_but_ingested, sensitive_url_in_body_drops; sms_otp::tests (A01–R05, 30+ shapes); redaction_corpus bin |
| S1 | Bank / sign-in / password-vault domain recognised in a message body or URL (backstops the Swift domain list with the Rust table). | PASS | ADR-0030 §3(b) — sensitive_domains table (include_str! compile-time TOML) | sensitive_domains::tests::matches_us_bank_exact, matches_us_bank_subdomain, matches_auth_provider, matches_oauth_callback_pattern, matches_magic_link_pattern |
| X1 | Cross-engine parity: the Swift helper (ICU/NSRegularExpression) and the Rust reader (regex crate) agree on the four §6 secret shapes, so cleaning the text for recall can never reveal a secret the helper let through. | PASS | Shared corpus core/brain/fixtures/ocr-secret-corpus.json + verbatim-string guard | reading.rs::the_guard_answers_the_shared_corpus_like_the_capture_helper, the_guard_uses_the_capture_helpers_four_pattern_strings_verbatim |

### Decisions observed this run (falsifiability record)

| # | Expected | Observed |
| - | -------- | -------- |
| 1 | suppress(secure-event-input) | suppress(secure-event-input) |
| 2 | suppress(ax-secure-subrole) | suppress(ax-secure-subrole) |
| 3 | suppress(denylist-source) for every bundle | all 15 suppressed(denylist-source) |
| 4 | suppress(denylist-source) | suppress(denylist-source) |
| 5 | suppress(denylist-source) | chrome=suppress(denylist-source); edge=suppress(denylist-source) |
| 6 | topBarFinding == privateWindow | incognito=privateWindow; private=privateWindow |
| 7 | suppress(denylist-source) | all suppressed(denylist-source) |
| 8 | topBarFinding == deniedSite; title route suppress(denylist-source) | topBar=deniedSite; title=suppress(denylist-source) |
| 9 | pixel allow; decideOcr suppress(ocr-time-secret) | pixel=allow; aws=suppress(ocr-time-secret); pat=suppress(ocr-time-secret) |
| 10 | decideOcr suppress(ocr-time-secret) | token=suppress(ocr-time-secret); api_key=suppress(ocr-time-secret); jwt=suppress(ocr-time-secret) |
| 11 | no §6 shape matches — the frame is stored | allow |
| 12 | no §6 shape matches — the frame is stored | allow |
| O2 | OTP -> [REDACTED:SMS_OTP]; bank alert -> [REDACTED:BANK_NOTIFICATION]; no source bytes survive; event still ingested | redacted + ingested |
| S1 | matches_sensitive_domain == true for US banks, fintech, auth providers, OAuth callbacks, magic-links | all matched |
| X1 | same verdict on the shared corpus; the four pattern strings appear verbatim in SuppressionCascade.swift | parity holds |

## Needs a person (confirm on a real Mac)

These cannot be settled headlessly. Each is a short, exact procedure. Use only throwaway test accounts and fake data.

### N1 — A private Safari or Arc window that shows no readable marker

The cascade catches a private window three ways: a private word in the title, a readable "Incognito"/"InPrivate"/"Private" badge in the top bar, or the browser's own answer (Automation, only for Chrome/Brave/Edge and only if you already allowed it). Safari and Arc are **not** in the Automation list, and Safari puts no private marker in the window title. So a private Safari/Arc window is skipped only if its top bar shows a word the reader recognises. Whether it does is a pixels question for a real Mac.

Steps:
1. Install the signed build. Grant Screen Recording. Let it capture for a minute on an ordinary page so you know capture works.
2. Open a Safari **private** window (Shift-Cmd-N) and go to a harmless page (e.g. example.com). Do the same in Arc (an incognito/private window).
3. In the menu bar, confirm whether the dot shows reading or skipped for that window.
4. Wait ~60s, then in the window (Ask) search for a unique word you can see on that page.
5. **Pass** = the page is not found (window was skipped). **Gap** = it is found. If it is a gap, that private window was read; file it per SECURITY.md and add its marker to the top-bar reader. Note: the four secret shapes (§6) still apply to whatever was on it.

### N2 — A one-time code shown on screen in an ordinary chat app (OCR path)

Row 11 proves the OCR gate does **not** catch a bare numeric code; the Messages/Mail deep-hook ingest (row O2) does. Confirm the on-screen behaviour and decide if it is acceptable for launch.

1. In a chat app that is **not** Apple Messages (e.g. a web Gmail, Slack, Discord), display a fake message "Your verification code is 123456".
2. Wait ~60s. In Ask, search "123456".
3. Expected (documented): it **can** be found — an on-screen OTP is not one of the four secret shapes (PRIVACY.md:72, SECURITY.md:29). Decide whether to broaden §6 or accept the documented limitation.

### N3 — A credit-card number typed into an ordinary app (OCR path)

Row 12 proves there is no card-number detector on the OCR path.

1. In TextEdit, type a **fake** card-shaped number: `4111 1111 1111 1111`.
2. Wait ~60s. In Ask, search `4111`.
3. Expected (documented gap): it **can** be found. Decide whether a Luhn/PAN redactor is a launch blocker; today only a soft prompt instruction to the local model discourages recording it (not a hard filter).

## Concerns / gaps (nothing hidden)

- **G1 — On-screen OTP (OCR path) is not redacted.** Real, documented (PRIVACY.md:72, SECURITY.md:29). A bare numeric code is not one of the four §6 shapes. Covered on the Messages/Mail ingest path only. Tracked by the ignored test `SecretMatrixTests.testGAP_onScreenOtpOnOcrPathIsNotRedacted` (skipped with a note; remove the skip when coverage lands).
- **G2 — Credit-card numbers are not redacted on any storage path.** Real, documented (PRIVACY.md:96). No Luhn/PAN detector exists; only `apps/mind/.../Prompts.swift:27` asks the local model not to record card numbers, which is not a hard filter. Tracked by the ignored test `SecretMatrixTests.testGAP_creditCardOnOcrPathIsNotRedacted`.
- **G3 — Launch copy understates the app denylist.** PRIVACY.md:67 and SECURITY.md:27 say "six password managers" are skipped and "others are read like any other app," but the code (`CaptureAdmissionPolicy.swift`) never-reads 66 password-manager/authenticator bundle-id families (Keeper, NordPass, Proton Pass, Enpass, KeePassXC, Yubico Authenticator, …), covering the 76 identifiers verified by `NeverReadPasswordManagersTests`. The code is **more** protective than the copy — the safe direction — but the two should be reconciled before launch. A person should decide the wording (this harness does not edit launch copy).
- **G4 — A stale rationale string in the allowlist.** `known-safe-apps.toml`'s `com.apple.MobileSMS` entry claims "§3(a) … gate the rendered text on every cascade-twice pass," but the Swift OCR pass runs only the four §6 patterns, not the SMS-OTP bank (that runs in the Rust ingest path). Under `.ordinaryApplications` the allowlist is dormant, so this is a documentation accuracy issue, not a behaviour gap. Flag for a person.
- **G5 — §6 is a backstop, not a guarantee.** By design (SecretBench, Basak et al. arXiv:2307.00714 — best detectors 52–88% recall) the four shapes lean to precision. A secret in a shape they do not match (a bare high-entropy token with no keyword, a non-US OTP format, a card number) can be stored. This is stated in PRIVACY.md:96 and is why the denylist / secure-input / private-window rules (which are not pattern-recall-limited) carry the load.

## What this proves, and what it does not

Proves (headless, repeatable, asserted): password fields (two ways), 66 password-manager and authenticator bundle-id families (76 verified identifiers), private browser windows that show a marker, bank/sign-in sites by URL and by address, and API keys/tokens/JWTs in a terminal or editor are each dropped by a named rule, and the Swift and Rust secret checks agree. The Messages/Mail ingest path redacts OTPs and bank alerts.

Does not prove (needs a person / out of scope here): the live Carbon/AX/ScreenCaptureKit pipeline on a real Mac (N1–N3), on-screen OTPs and card numbers (documented gaps G1–G2), and any secret in a shape §6 does not match (G5). None of these is hidden; each is a row or a concern above.

