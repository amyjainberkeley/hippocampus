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
6. **§6 ocr-time-secret** — the OCR'd text matches one of the secret shapes (the four key/token regexes, a Luhn-valid credit-card number, or a one-time code next to a keyword); checked on the raw read, the reading-order text, and the exact stored text.
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
| 11 | One-time code shown on screen in a chat app and captured by OCR (e.g. "Your verification code is 123456") | PASS | Cascade §6 — OCR-time OTP rule (SuppressionCascade.containsOTP): a 4–8 digit run within ~40 bytes of an OTP keyword (one-time, verification/security/login/authentication/confirmation code, passcode, OTP, 2FA, …). Keyword required, so a bare number is kept. Cross-engine with the Rust reader. | SecretMatrixTests.testSecretMatrix, testOnScreenOtpOnOcrPathIsRedacted; ocr_secrets::tests::an_otp_needs_both_a_keyword_and_a_nearby_run; shared corpus |
| 12 | Credit-card number typed in a plain text editor and captured by OCR ("4111 1111 1111 1111 …") | PASS | Cascade §6 — OCR-time card rule (SuppressionCascade.containsCreditCard): a maximal 13–19 digit run (single space/hyphen groups) that passes the Luhn checksum. Luhn drops almost all ordinary numbers, so phone numbers / order ids / dates are kept. Cross-engine with the Rust reader. | SecretMatrixTests.testSecretMatrix, testCreditCardOnOcrPathIsRedacted; ocr_secrets::tests::real_test_cards_pass_luhn_and_look_alikes_do_not; shared corpus |
| O2 | One-time code / bank alert in a message, via the Messages or Mail **deep-hook ingest** (opt-in; the path that reads the Messages/Mail store directly, not OCR). E.g. "Your Apple ID code is 123456". | PASS | ADR-0030 §3(a) sms_otp + §3(b) sensitive_domains, gated to com.apple.MobileSMS / com.apple.mail (redaction::bundle_is_in_scope); wired in apps/agent/src/messages_ingest.rs BEFORE storage. | messages_plugin::tests::sms_otp_shape_is_redacted_but_ingested, bank_notification_shape_is_redacted_but_ingested, sensitive_url_in_body_drops; sms_otp::tests (A01–R05, 30+ shapes); redaction_corpus bin |
| S1 | Bank / sign-in / password-vault domain recognised in a message body or URL (backstops the Swift domain list with the Rust table). | PASS | ADR-0030 §3(b) — sensitive_domains table (include_str! compile-time TOML) | sensitive_domains::tests::matches_us_bank_exact, matches_us_bank_subdomain, matches_auth_provider, matches_oauth_callback_pattern, matches_magic_link_pattern |
| X1 | Cross-engine parity: the Swift helper (ICU/NSRegularExpression + hand-rolled Luhn/OTP scans) and the Rust reader (regex crate + the same scans) agree on every §6 secret shape, so cleaning the text for recall can never reveal a secret the helper let through. The 86-case shared corpus now includes the credit-card and OTP cases. | PASS | Shared corpus core/brain/fixtures/ocr-secret-corpus.json (86 cases) + verbatim-string guard | reading.rs::the_guard_answers_the_shared_corpus_like_the_capture_helper, the_guard_uses_the_capture_helpers_four_pattern_strings_verbatim; OCRReadingPrivacyTests.testSecretPatternsAnswerTheSharedCorpus |

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
| 11 | decideOcr suppress(ocr-time-secret); a bare number is allowed | otp=suppress(ocr-time-secret); bare=allow |
| 12 | decideOcr suppress(ocr-time-secret); a non-Luhn look-alike is allowed | card=suppress(ocr-time-secret); nonLuhn=allow |
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
5. **Pass** = the page is not found (window was skipped). **Gap** = it is found. If it is a gap, that private window was read; file it per SECURITY.md and add its marker to the top-bar reader. Note: the §6 secret shapes still apply to whatever was on it.

### N2 — A one-time code shown on screen in an ordinary chat app (OCR path)

Row 11 proves, headlessly, that the OCR gate now drops a one-time code shown next to a keyword. This step confirms it end-to-end on a real Mac and shows the precision boundary.

1. In a chat app that is **not** Apple Messages (e.g. a web Gmail, Slack, Discord), display a fake message "Your verification code is 123456".
2. Wait ~60s. In Ask, search "123456".
3. **Pass** = it is **not** found: the frame was dropped by §6 (`containsOTP`).
4. Now display a bare "123456" with no nearby keyword, wait ~60s, and search it. Expected: it **can** be found — precision-first, a lone number is kept. An OTP in a format the keywords don't name (e.g. a non-US bank's wording) may also be kept; that is G5, not a regression.

### N3 — A credit-card number typed into an ordinary app (OCR path)

Row 12 proves, headlessly, that a Luhn-valid card number is now dropped on the OCR path. This step confirms it end-to-end on a real Mac and shows the precision boundary.

1. In TextEdit, type a **fake** card-shaped number: `4111 1111 1111 1111`.
2. Wait ~60s. In Ask, search `4111`.
3. **Pass** = it is **not** found: the frame was dropped by §6 (`containsCreditCard`, Luhn-valid).
4. Now type a 16-digit number that fails Luhn (e.g. `1234 1234 1234 1234`), wait ~60s, and search it. Expected: it **can** be found — precision-first, only Luhn-valid runs are dropped. The soft model instruction in `apps/mind/.../Prompts.swift:27` remains as a second layer.

## Concerns / gaps (nothing hidden)

- **G1 — On-screen OTP (OCR path): CLOSED since this audit.** The OCR gate now drops a one-time code shown within ~40 bytes of an OTP keyword, in both engines (`containsOTP` / `contains_otp`). Precision-first, so a bare code with no keyword, or an OTP in a format the keywords don't name (e.g. a non-US bank's wording), can still be stored — see G5. Proven by `SecretMatrixTests.testOnScreenOtpOnOcrPathIsRedacted` (was the skipped GAP test) and the shared corpus.
- **G2 — Credit-card numbers (OCR path): CLOSED since this audit.** A maximal 13–19 digit run that passes the Luhn checksum is now dropped by the OCR gate, in both engines (`containsCreditCard` / `contains_credit_card`). Luhn keeps precision high: phone numbers, order ids, dates and timestamps rarely pass. A card OCR'd into double-spaced or letter-broken groups may be missed — see G5. Proven by `SecretMatrixTests.testCreditCardOnOcrPathIsRedacted` (was the skipped GAP test) and the shared corpus. The soft model instruction in `apps/mind/.../Prompts.swift:27` remains as a second layer.
- **G3 — Launch copy understates the app denylist.** PRIVACY.md:67 and SECURITY.md:27 say "six password managers" are skipped and "others are read like any other app," but the code (`CaptureAdmissionPolicy.swift`) never-reads 66 password-manager/authenticator bundle-id families (Keeper, NordPass, Proton Pass, Enpass, KeePassXC, Yubico Authenticator, …), covering the 76 identifiers verified by `NeverReadPasswordManagersTests`. The code is **more** protective than the copy — the safe direction — but the two should be reconciled before launch. A person should decide the wording (this harness does not edit launch copy).
- **G4 — A stale rationale string in the allowlist.** `known-safe-apps.toml`'s `com.apple.MobileSMS` entry claims "§3(a) … gate the rendered text on every cascade-twice pass," but the Swift OCR pass runs only the §6 OCR-time checks (the four patterns plus the Luhn-card and keyword-OTP rules), not the SMS-OTP bank (that runs in the Rust ingest path). Under `.ordinaryApplications` the allowlist is dormant, so this is a documentation accuracy issue, not a behaviour gap. Flag for a person.
- **G5 — §6 is a backstop, not a guarantee.** By design (SecretBench, Basak et al. arXiv:2307.00714 — best detectors 52–88% recall) the shapes lean to precision. A secret in a shape they do not match can still be stored: a bare high-entropy token with no keyword, a one-time code in a format the keywords don't name (e.g. a non-US bank's wording), or a card whose digits OCR'd too poorly to form a clean 13–19 run. This is stated in PRIVACY.md and is why the denylist / secure-input / private-window rules (which are not pattern-recall-limited) carry the load.

## What this proves, and what it does not

Proves (headless, repeatable, asserted): password fields (two ways), 66 password-manager and authenticator bundle-id families (76 verified identifiers), private browser windows that show a marker, bank/sign-in sites by URL and by address, API keys/tokens/JWTs in a terminal or editor, Luhn-valid credit-card numbers, and one-time codes shown next to a keyword are each dropped by a named rule, and the Swift and Rust secret checks agree on the 86-case corpus. The Messages/Mail ingest path redacts OTPs and bank alerts.

Does not prove (needs a person / out of scope here): the live Carbon/AX/ScreenCaptureKit pipeline on a real Mac (N1–N3 are now end-to-end confirmations, not gaps), and any secret in a shape §6 does not match — a bare high-entropy token with no keyword, a one-time code in a wording the keywords don't name, a badly-OCR'd card (G5). None of these is hidden; each is a row or a concern above.

