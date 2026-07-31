# SMS 2FA / OTP / banking-notification text-shape test corpus (synthetic)

**Maintainer:** Amy Jain.
**Date:** 2026-05-28
**Status:** Seed corpus for ADR-0030 §3(a). Living document — maintainers add real-world-observed shapes as they surface; the labels and the regex set in ADR-0030 evolve together.
**Provenance:** **ALL ENTRIES BELOW ARE SYNTHETIC.** No live SMS, no scraped messages, no user data. Every shape is reconstructed from public security writeups, vendor support pages, NIST SP 800-63B examples, OWASP ASVS authentication-test fixtures, and bank/issuer help-center documentation. The 6-digit codes are randomly generated for fixture purposes (`000000` excluded; nothing reveals a real OTP).

## Purpose

Phase 3 OCR pipeline (ADR-0016) needs a defense-in-depth redaction layer for SMS-shape and banking-notification strings that surface in **rendered Messages or Mail content** captured by SCStream. The ADR-0013 cascade's `.secureInput` arm fires only during password-prompt focus — not during plaintext display of received messages. This corpus drives the OCR-time regex set that ADR-0030 §3(a) gates on.

**Catch-rate requirement (ADR-0030 §3(e) gate):** The regex set must classify ≥99% of the entries in this corpus as "redact" before `com.apple.MobileSMS` or `com.apple.mail` may be added to `known-safe-apps.toml`.

## Corpus structure

Each entry has:

- `id` — stable identifier (`A-NN` Apple, `B-NN` banking, `C-NN` carrier/generic, `D-NN` developer/SaaS, `E-NN` auth-app, `R-NN` password-reset, `H-NN` adversarial honey).
- `text` — the exact shape, with synthetic digits.
- `must_redact` — true / false. (Honey entries are `false`; everything else is `true`.)
- `source_shape` — what public document the shape is reconstructed from.

A corpus runner script (owed at the ADR-0030 implementation PR; lives in `core/brain/eval/redaction/run_corpus.rs`) loads this file, applies the §3(a) regex set, and reports `caught / missed / false-positive`. Gate: `caught/(caught+missed) ≥ 0.99` and `false-positive/(false-positive+true-negative) ≤ 0.05`.

---

## A — Apple-issued (Apple ID, Apple Pay, iCloud, FaceTime)

| id | text | must_redact | source_shape |
|---|---|---|---|
| A-01 | `483921 is your Apple ID Verification Code. Don't share it with anyone.` | true | Apple Support HT204915 (Apple ID two-factor authentication) — canonical shape |
| A-02 | `Your Apple ID Code is: 271845. Don't share it with anyone.` | true | Apple Support HT204915 variant (older) |
| A-03 | `Your Apple ID Verification Code is 309217.` | true | Apple Support HT204915 (post-iOS 17 shorter variant) |
| A-04 | `Apple Pay: Use code 842915 to verify your card.` | true | Apple Support HT203027 (Apple Pay card-verification SMS) |
| A-05 | `Your iCloud verification code is 612083. Apple will never call to ask for this code.` | true | Apple Support HT204145 (iCloud sign-in) |

## B — US bank / financial institution shapes

Sources: each issuer's public security/help-center page on enrolled-device OTP delivery. FFIEC Authentication Guidance 2021 §III.B (Authenticators) lists OTP-via-SMS as a category; per-issuer text reconstructed from each bank's support docs. Top US banks by assets per FDIC institution list (`fdic.gov/resources/bankers/data-tools/`).

| id | text | must_redact | source_shape |
|---|---|---|---|
| B-01 | `JPMORGAN CHASE: Your verification code is 384029. Don't share this code.` | true | Chase secure-message-center docs (`chase.com/digital/security`) |
| B-02 | `Chase: Use code 729103 to confirm a recent transaction. Reply STOP to opt out.` | true | Chase transaction-verification SMS |
| B-03 | `BofA: Verification code 218074. Never share. Reply HELP for help.` | true | Bank of America security center (`bankofamerica.com/security-center/sms`) |
| B-04 | `Bank of America: Did you make a charge for $482.19 at AMAZON? Reply YES or NO.` | true | BofA fraud-alert SMS (issued via short code 39872 historically) |
| B-05 | `WELLS FARGO: Your one-time access code is 408216. Code expires in 10 min.` | true | Wells Fargo enhanced-security SMS template |
| B-06 | `Wells Fargo Fraud Alert: Did you authorize $1,204.00 at TARGET? Reply 1=YES 2=NO.` | true | Wells Fargo fraud-alert short-code shape |
| B-07 | `Capital One: 583902 is your security code. Do not share.` | true | Capital One sign-in verification SMS |
| B-08 | `CapitalOne: We saw an unusual sign-in. Code: 174926 to confirm it was you.` | true | Capital One sign-in-anomaly SMS |
| B-09 | `Citi: Authorization code 920485. Use it within 5 minutes.` | true | Citibank enhanced security SMS |
| B-10 | `Citi Identification Code: 638247. We will never call to ask for it.` | true | Citi identification-code SMS |
| B-11 | `US Bank: Your code is 290183. Do not share.` | true | U.S. Bank security SMS |
| B-12 | `PNC: Use 471802 to verify. Reply STOP to end.` | true | PNC online-banking verification SMS |
| B-13 | `Truist Alert: Code 138204 to sign in. Never share with anyone.` | true | Truist online-banking verification (post BB&T/SunTrust merge shape) |
| B-14 | `TD Bank: Your verification code is 805193. Expires in 10 min.` | true | TD Bank online-banking SMS |
| B-15 | `Goldman Sachs: Your Marcus security code is 472918.` | true | Marcus by Goldman Sachs sign-in SMS |
| B-16 | `APPLECARD: 619204 is your verification code. Don't share it.` | true | Apple Card (Goldman-issued) — Apple Support HT209218 |
| B-17 | `Discover: Code 274013 to access your account. Never share.` | true | Discover online-banking SMS |
| B-18 | `Amex: Your verification code is 528617. Don't share it with anyone.` | true | American Express SafeKey OTP shape |
| B-19 | `Charles Schwab: Verification code 718203 — do not share.` | true | Schwab security-code SMS |
| B-20 | `Fidelity: Use 091825 to verify your identity.` | true | Fidelity NetBenefits / brokerage SMS |
| B-21 | `Venmo: NEVER share. Your code is 472901.` | true | Venmo (PayPal-owned) verification SMS |
| B-22 | `Cash App: Your sign-in code is 308172.` | true | Cash App (Square/Block) sign-in code |
| B-23 | `PayPal: 184039 is your security code. Don't share it.` | true | PayPal account-verification SMS |
| B-24 | `Zelle: 6-digit code 904821 to enroll your account.` | true | Zelle (Early Warning Services) enrollment SMS |
| B-25 | `Coinbase: 482103 is your verification code. Don't share it.` | true | Coinbase OTP SMS |
| B-26 | `Kraken: Your sign-in code is 273918.` | true | Kraken OTP SMS |
| B-27 | `Robinhood: Verification code 081726. Never share.` | true | Robinhood SMS shape |
| B-28 | `Ally Bank: Your one-time code is 528391.` | true | Ally Bank online-banking SMS |
| B-29 | `USAA: Code 614209 to access your account.` | true | USAA OTP SMS |
| B-30 | `Navy Federal: 731029 is your code. Never share.` | true | Navy Federal Credit Union OTP SMS |

## C — Generic carrier / short-code OTP shapes (the residual)

| id | text | must_redact | source_shape |
|---|---|---|---|
| C-01 | `Your verification code is 482917.` | true | NIST SP 800-63B §5.1.3.2 OTP-via-SMS example |
| C-02 | `Your code: 728103` | true | minimalist short-code SMS |
| C-03 | `Use code 583920 to verify your phone number.` | true | enrollment SMS, common across vendors |
| C-04 | `OTP: 184273. Do not share.` | true | terse OTP shape (common with prepaid carriers) |
| C-05 | `Your one-time passcode is 920184.` | true | common short-code template |
| C-06 | `Code: 274091. This code expires in 10 minutes.` | true | OWASP ASVS §2.7.1 example shape |
| C-07 | `382716 - your security code.` | true | leading-digits shape (Twilio default template) |
| C-08 | `[#] 482910 is your verification code.` | true | Android SMS Retriever API-compatible format |
| C-09 | `<#> 829034 is your code @example.com #example` | true | iOS SMS-autofill app-domain-bound code shape (Apple WebKit docs) |
| C-10 | `Don't share this code. 029184 is your verification code.` | true | Twilio Verify default English template |

## D — Developer / SaaS account verification (high-value-target shapes)

| id | text | must_redact | source_shape |
|---|---|---|---|
| D-01 | `Your Google verification code is 184729.` | true | Google account-recovery SMS (Google Support 185834) |
| D-02 | `G-018472 is your Google verification code.` | true | Google `G-` prefix shape (Google Support docs) |
| D-03 | `Use verification code 728103 for Microsoft authentication.` | true | Microsoft account SMS-OTP shape |
| D-04 | `Microsoft account security code: 920184.` | true | Microsoft account security SMS |
| D-05 | `[GitHub] Your authentication code: 482910.` | true | GitHub mobile-2FA SMS (deprecated but still supported) |
| D-06 | `Slack code: 274-019.` | true | Slack workspace-sign-in SMS shape |
| D-07 | `Stripe: Your verification code is 184729.` | true | Stripe dashboard-2FA SMS |
| D-08 | `LinkedIn: 482910 is your verification code.` | true | LinkedIn security-step SMS |
| D-09 | `Twitter / X verification code: 728103.` | true | X (formerly Twitter) account-recovery SMS |
| D-10 | `Your Facebook security code is 920184.` | true | Meta account-security SMS |
| D-11 | `Instagram: 482910 is your security code.` | true | Meta-property account-security SMS |

## E — Auth-app / TOTP generator shapes (when displayed in a notification mirror)

When auth-app codes surface in macOS notifications mirrored from iPhone (Continuity), or in lock-screen previews captured by SCStream during foreground use, they share a recognizable shape.

| id | text | must_redact | source_shape |
|---|---|---|---|
| E-01 | `Google Authenticator: github.com — 482910` | true | Google Authenticator notification shape |
| E-02 | `Authy: 1Password — 728103` | true | Authy notification preview |
| E-03 | `1Password: One-Time Password 482-910` | true | 1Password OTP-display shape |
| E-04 | `Duo: 6-digit passcode 092184. Tap to copy.` | true | Duo Push notification shape |
| E-05 | `Microsoft Authenticator: Code 728103 for example.com` | true | Microsoft Authenticator notification |

## R — Password-reset / account-recovery SMS

| id | text | must_redact | source_shape |
|---|---|---|---|
| R-01 | `To reset your Apple ID password, use code 482910.` | true | Apple Support HT204145 password-reset SMS |
| R-02 | `Your password reset code is 728103.` | true | OWASP ASVS §2.5.1 password-reset shape |
| R-03 | `Click here to reset your password: https://example.com/reset?t=abc123def456` | true | password-reset URL shape (OWASP) |
| R-04 | `Verify identity to recover account: code 920184.` | true | account-recovery SMS shape |
| R-05 | `Your account recovery code is 482910. Never share with anyone calling you.` | true | NIST SP 800-63B social-engineering-warning shape |

## H — Adversarial / honey entries (must NOT be flagged false-positive)

These are normal SMS/Mail content that share surface features (digits, "code", URLs) with 2FA shapes but are NOT secrets. The regex set must NOT classify these as "redact" — the corpus tracks false-positive rate alongside catch rate.

| id | text | must_redact | source_shape |
|---|---|---|---|
| H-01 | `Hey, can you grab milk on the way home?` | false | normal personal SMS — no digits |
| H-02 | `Meeting at 2:30pm. Door code is the building, not a secret.` | false | digit-adjacent "code" mention in non-secret context |
| H-03 | `The package tracking number is 1Z999AA10123456784.` | false | UPS tracking number (digit-rich, "number" keyword, NOT a secret) |
| H-04 | `Address: 482 Elm St, apt 910.` | false | street address with digits |
| H-05 | `Your order #28471 has shipped. Tracking: https://example.com/track/28471` | false | order-confirmation URL — not auth |
| H-06 | `Flight UA482 departs at 19:10. Gate B17.` | false | flight info — digit-rich, not a secret |
| H-07 | `The score was 4-2. What a game.` | false | sports score |
| H-08 | `Call me when you get a chance: 555-018-2734.` | false | a phone number (digit-rich; common false-positive trigger) |
| H-09 | `The book is on page 482. Look at paragraph 3.` | false | reading reference |
| H-10 | `Pricing tier 1: $9, tier 2: $19, tier 3: $49.` | false | pricing — multi-digit |

---

## Regex set draft (ADR-0030 §3(a) — locked at ADR ratification, evolves with the corpus)

The implementation lives at `core/brain/redaction/sms_otp.rs` (owed by the follow-on PR). The regex set below is **draft for review** — the ADR-0030 implementation PR commits the final form alongside the corpus runner.

```rust
// Tier 1: explicit OTP shapes — high precision, anchored on a keyword
//   - "verification code is <digits>"
//   - "your code is <digits>"
//   - "OTP: <digits>"
//   - "passcode <digits>"
//   - "security code <digits>"
//   - "Apple ID ... <digits>"
//   - "G-<digits>" Google prefix
//   - bank-name + "code <digits>" combination (per B-NN entries)
// Tier 2: "<digits 4-8> ... within Nminute window of (code|verify|OTP|PIN|verification|passcode|one-time)"
//   - 20-char proximity, both directions
// Tier 3: Apple WebKit autofill format: `<#> <digits> is your code @<domain> #<hash>`
// Tier 4: U.S. bank short-code numerical sender + any digit run
//   - The cascade has access to "From:" / sender on the Messages capture side;
//     when sender matches a tracked short-code list (39872 BofA, 36273 Chase, etc.)
//     the entire message body becomes redact-by-default.
```

**Coverage projection (against this corpus, by tier):**

| Tier | Catches in A–R | Adversarial in H |
|---|---|---|
| Tier 1 | ~70% (most issuer-prefixed shapes) | 0 |
| Tier 1 + 2 | ~95% (adds proximity-rule shapes like C-01, C-05) | ≤ 1 (H-02 mentions "code", proximity may trigger — under review) |
| Tier 1 + 2 + 3 + 4 | target ≥ 99% | target ≤ 5% |

The implementation PR runs the corpus and reports actuals; this projection is informational.

## Update cadence

Quarterly refresh (per ADR-0030 §3(b)) — same cycle as `sensitive-domains.toml`. Maintainer (CSO seat) tracks:

- New issuer-prefix shapes (e.g., a new fintech enters Top-50 — add to `B-NN`).
- New auth-provider shapes (e.g., a new auth0/clerk competitor surfaces).
- Real-world adversarial false-positives reported by the CRS Telemetry-Gap analyst (`ocr_text_secret_match_count` regressions get triaged into `H-NN`).

A quarterly PR-of-this-file is the audit trail. CSO sign-off on each refresh asserts: no entry weakens the corpus's coverage promise.

## References

- **OWASP Application Security Verification Standard v4.0.3** §2 (Authentication) — `owasp.org/www-project-application-security-verification-standard`.
- **NIST SP 800-63B** §5.1.3 (Out-of-Band Authenticators) — `pages.nist.gov/800-63-3/sp800-63b.html`. Key reference for SMS-OTP threat model.
- **FFIEC Authentication and Access to Financial Institution Services and Systems** (2021) §III.B — `ffiec.gov/press/PDF/FFIEC_authentication.pdf`. The category-level guidance behind the B-NN issuer shapes.
- **Apple Support HT204915** (Two-factor authentication for Apple ID) — `support.apple.com/en-us/HT204915`. Canonical Apple-shape A-01.
- **Apple Support HT204145** (Reset your Apple ID password) — `support.apple.com/en-us/HT204145`. Apple-shape R-01.
- **Apple Support HT209218** (Apple Card security) — `support.apple.com/en-us/HT209218`. Apple-Card issuer shape B-16.
- **Apple WebKit / iOS SMS autofill format** — `developer.apple.com/news/?id=z6tcoq3y`. C-09 shape.
- **Android SMS Retriever API** — `developers.google.com/identity/sms-retriever/overview`. C-08 shape.
- **Twilio Verify default templates** — `twilio.com/docs/verify` (default English template). C-07, C-10 shapes.
- **Krebs on Security** — "SIM Swapping" and "The Case for a National Privacy Act" series — supporting threat-model documentation for the corpus's existence (why SMS-OTP-by-display is sensitive).
- **`docs/research/recall-coverage-gap-2026-05-26.md` §6 ⚠️ block** — the memo that mandated this corpus.
- **ADR-0013** (cascade) + **ADR-0016 §1.6** (cascade-twice for OCR) + **ADR-0030** (this corpus's gating ADR).
