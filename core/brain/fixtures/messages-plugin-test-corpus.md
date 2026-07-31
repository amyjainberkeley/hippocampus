# V2-P7 Messages.app deep-hook plugin redaction test corpus (synthetic)

**Maintainer:** Amy Jain.
**Date:** 2026-05-29
**Status:** Seed corpus for ADR-0030 §3(f) (per ADR-0032 §4). Living document.
**Provenance:** **ALL ENTRIES BELOW ARE SYNTHETIC.** No live Messages.app rows, no scraped chats, no user data. Every shape is reconstructed from public security writeups, vendor support pages, and the sibling corpus at `docs/research/sms-2fa-test-corpus-shapes.md`. The 6-digit codes are randomly generated for fixture purposes (`000000` excluded; nothing reveals a real OTP).

## Purpose

V2-P7 ships the Messages.app deep-hook plugin (`adapters/macos/mci-messages-reader/`) and the §3(f) cascade-equivalent at `core/brain/src/redaction/messages_plugin.rs`. ADR-0032 §4 binds the implementing PR to a 5-class corpus:

- **MS-** SMS-OTP shapes carried over a Messages chat.db row.
- **MB-** Bank-notification shapes (fraud alerts, transaction confirmations).
- **MU-** Sensitive URL or host inside the body.
- **MP-** Sensitive participant (e.g. `alerts@chase.com`).
- **MH-** Honey / adversarial entries that must NOT drop or redact.

The runner is `core/brain/src/bin/messages_plugin_corpus.rs`. The committed artifact is `docs/audit/2026-05-30-messages-plugin-corpus.md`. Per ADR-0032 §4 the gate is `(catch ≥99% on MS+MB+MU+MP) AND (FP ≤5% on MH)`.

## Corpus structure

Each entry has:

- `id` — stable identifier (`MS-NN`, `MB-NN`, `MU-NN`, `MP-NN`, `MH-NN`).
- `body` — the rendered message text (with synthetic digits).
- `participants` — pipe-separated list (`"+15551234567"`, `"alerts@chase.com"`, `…`).
- `expect` — `drop` | `redact` | `pass` — the cascade-equivalent's expected behavior.
- `source_shape` — short note on what real-world shape this fixture mirrors.

`drop` means the cascade-equivalent returns `drop_event = true` (participant or URL match). `redact` means it returns `drop_event = false` AND the §3(a) regex fired (fired_rules non-empty, body has replacement tokens). `pass` means neither — used only on the `MH-` honey class.

---

## MS — SMS-OTP shapes carried over a Messages row

These mirror the upstream `sms-2fa-test-corpus-shapes.md` A/C/D/E/R classes but the body is the entire `message.text` field. Expected behavior: `redact` (in-place substitution) and `drop_event = false`.

| id | body | participants | expect | source_shape |
|---|---|---|---|---|
| `MS-01` | `483921 is your Apple ID Verification Code. Don't share it with anyone.` | `+18001234567` | redact | Apple Support HT204915 |
| `MS-02` | `Your Apple ID Code is: 271845. Don't share it with anyone.` | `+18001234567` | redact | Apple Support HT204915 variant |
| `MS-03` | `Your Apple ID Verification Code is 309217.` | `+18001234567` | redact | Apple Support HT204915 short |
| `MS-04` | `Apple Pay: Use code 842915 to verify your card.` | `+18001234567` | redact | Apple Support HT203027 |
| `MS-05` | `Your iCloud verification code is 612083. Apple will never call to ask for this code.` | `+18001234567` | redact | Apple Support HT204145 |
| `MS-06` | `Your verification code is 482917.` | `+15551237777` | redact | NIST SP 800-63B §5.1.3.2 |
| `MS-07` | `Your code: 728103` | `+15551237777` | redact | minimalist short-code |
| `MS-08` | `Use code 583920 to verify your phone number.` | `+15551237777` | redact | enrollment SMS |
| `MS-09` | `OTP: 184273. Do not share.` | `+15551237777` | redact | terse OTP shape |
| `MS-10` | `Your one-time passcode is 920184.` | `+15551237777` | redact | common short-code template |
| `MS-11` | `Code: 274091. This code expires in 10 minutes.` | `+15551237777` | redact | OWASP ASVS §2.7.1 example |
| `MS-12` | `382716 - your security code.` | `+15551237777` | redact | Twilio default template |
| `MS-13` | `[#] 482910 is your verification code.` | `+15551237777` | redact | Android SMS Retriever API |
| `MS-14` | `<#> 829034 is your code @example.com #example` | `+15551237777` | redact | iOS WebKit autofill format |
| `MS-15` | `Don't share this code. 029184 is your verification code.` | `+15551237777` | redact | Twilio Verify default |
| `MS-16` | `Your Google verification code is 184729.` | `+15551237777` | redact | Google Support 185834 |
| `MS-17` | `G-018472 is your Google verification code.` | `+15551237777` | redact | Google G- prefix |
| `MS-18` | `Use verification code 728103 for Microsoft authentication.` | `+15551237777` | redact | Microsoft SMS-OTP |
| `MS-19` | `[GitHub] Your authentication code: 482910.` | `+15551237777` | redact | GitHub mobile-2FA SMS |
| `MS-20` | `Slack code: 274-019.` | `+15551237777` | redact | Slack workspace-sign-in SMS |
| `MS-21` | `Google Authenticator: github.com — 482910` | `+15551237777` | redact | Authenticator notification |
| `MS-22` | `Duo: 6-digit passcode 092184. Tap to copy.` | `+15551237777` | redact | Duo Push notification |
| `MS-23` | `To reset your Apple ID password, use code 482910.` | `+18001234567` | redact | Apple Support HT204145 |
| `MS-24` | `Your password reset code is 728103.` | `+15551237777` | redact | OWASP ASVS §2.5.1 |
| `MS-25` | `Your account recovery code is 482910. Never share with anyone calling you.` | `+15551237777` | redact | NIST SP 800-63B warning |

## MB — Banking notification shapes (Tier 4)

| id | body | participants | expect | source_shape |
|---|---|---|---|---|
| `MB-01` | `Bank of America: Did you make a charge for $482.19 at AMAZON? Reply YES or NO.` | `+18444321212` | redact | BofA fraud-alert SMS |
| `MB-02` | `Wells Fargo Fraud Alert: Did you authorize $1,204.00 at TARGET? Reply 1=YES 2=NO.` | `+18004112222` | redact | Wells Fargo fraud-alert |
| `MB-03` | `Chase: Use code 729103 to confirm a recent transaction. Reply STOP to opt out.` | `+18002429466` | redact | Chase transaction-verification |
| `MB-04` | `Capital One: We saw an unusual sign-in. Code: 174926 to confirm it was you.` | `+18002277377` | redact | Capital One sign-in anomaly |
| `MB-05` | `Citi: Did you recognize a recent transaction? Reply HELP or call us.` | `+18003744569` | redact | Citi fraud-alert |

## MU — Sensitive URL or host in body

The cascade-equivalent's predicate 6 walks whitespace-separated tokens and probes each against the §3(b) sensitive-domains table. Expected behavior: `drop_event = true` with reason `SensitiveUrlInBody`.

| id | body | participants | expect | source_shape |
|---|---|---|---|---|
| `MU-01` | `Open the verification page: https://secure.chase.com/verify` | `+15551237777` | drop | forwarded bank link |
| `MU-02` | `chase.com is down right now` | `+15551237777` | drop | bare bank host mention |
| `MU-03` | `Go to https://accounts.google.com/oauth/authorize?response_type=code` | `+15551237777` | drop | auth-provider URL |
| `MU-04` | `Resetting account at https://login.microsoftonline.com/common/oauth2/v2.0/authorize` | `+15551237777` | drop | Microsoft OAuth URL |
| `MU-05` | `Forwarded password reset: https://appleid.apple.com/reset` | `+15551237777` | drop | Apple ID reset URL |
| `MU-06` | `Open paypal.com to confirm` | `+15551237777` | drop | fintech bare host |
| `MU-07` | `Continue at https://venmo.com/account/security` | `+15551237777` | drop | fintech security URL |
| `MU-08` | `Open coinbase.com to verify` | `+15551237777` | drop | crypto exchange host |
| `MU-09` | `Sign in here https://www.wellsfargo.com/online-banking/sign-in/` | `+15551237777` | drop | bank sign-in URL |
| `MU-10` | `Open https://login.auth0.com/u/login/identifier` | `+15551237777` | drop | auth-provider URL |

## MP — Sensitive participant

A sender (or remote handle) whose email address matches a tracked sensitive domain. Expected behavior: `drop_event = true` with reason `SensitiveParticipantDomain`.

| id | body | participants | expect | source_shape |
|---|---|---|---|---|
| `MP-01` | `Your statement is available.` | `alerts@chase.com` | drop | bank email participant |
| `MP-02` | `New sign-in detected.` | `noreply@accounts.google.com` | drop | auth-provider email participant |
| `MP-03` | `Your one-time code has been sent.` | `noreply@appleid.apple.com` | drop | Apple ID email participant |
| `MP-04` | `Receipt for your recent payment.` | `service@paypal.com` | drop | fintech email participant |
| `MP-05` | `Your monthly summary is ready.` | `donotreply@wellsfargo.com` | drop | bank email participant |

## MH — Honey / adversarial entries (must NOT drop or redact)

Normal, benign messages that share surface features with sensitive shapes. The cascade-equivalent must NOT drop or redact these.

| id | body | participants | expect | source_shape |
|---|---|---|---|---|
| `MH-01` | `Hey, can you grab milk on the way home?` | `+15551111111` | pass | normal personal SMS |
| `MH-02` | `Meeting at 2:30pm. Don't be late.` | `+15551111111` | pass | benign meeting note |
| `MH-03` | `The package tracking number is 1Z999AA10123456784.` | `+15551111111` | pass | UPS tracking number |
| `MH-04` | `Address: 482 Elm St, apt 910.` | `+15551111111` | pass | street address |
| `MH-05` | `Flight UA482 departs at 19:10. Gate B17.` | `+15551111111` | pass | flight info |
| `MH-06` | `The score was 4-2. What a game.` | `+15551111111` | pass | sports score |
| `MH-07` | `Call me when you get a chance: 555-018-2734.` | `+15551111111` | pass | phone number |
| `MH-08` | `The book is on page 482. Look at paragraph 3.` | `+15551111111` | pass | reading reference |
| `MH-09` | `Pricing tier 1: $9, tier 2: $19, tier 3: $49.` | `+15551111111` | pass | pricing |
| `MH-10` | `Reading example.com for the article` | `+15551111111` | pass | benign URL |
| `MH-11` | `Open https://github.com/new-tandem/mci` | `+15551111111` | pass | dev URL (non-sensitive) |
| `MH-12` | `My order #28471 has shipped.` | `+15551111111` | pass | order confirmation |

---

## Coverage targets (per ADR-0032 §4)

- `MS+MB+MU+MP` catch rate ≥99%.
- `MH` false-positive rate ≤5%.
- The overall gate is `(catch ≥99%) AND (FP ≤5%)`.

The committed audit artifact (`docs/audit/2026-05-30-messages-plugin-corpus.md`) is the runner's output; the artifact reports per-class breakdown, overall gate, and per-entry outcomes.
