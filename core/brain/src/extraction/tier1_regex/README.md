# Tier1 regex bank — V2-P4

Cheap, deterministic regex extractors for the entity kinds that don't need
NER. One regex per kind, evaluated in declared order against the
cascade-cleared text of every ingested event.

**Scope:** structural / unambiguous-shape entities only. Anything that
needs a model (person names, project names, free-form topics) is **out of
scope** for Tier1 and ships in V2-P5 (Qwen NER).

**Provenance tag** on every emitted `entity_mentions` row: `extractor_kind
= "regex"` (V2-P3 schema, migration 0004 + `EntityMention::extractor_kind`).

---

## Cascade discipline

Tier1 runs **POST-cascade**:

- Pixel-time §1–§5/§7 cascade arms have already dropped the frame
  (`Drop` decisions never reach the brain — `BrainStore::put_event`
  rejects `cascade_reason != 0` per ADR-0016 §4.3).
- OCR-time §6 redaction (`core/brain/src/redaction/sms_otp.rs` +
  `sensitive_domains.rs`) has already replaced sensitive byte ranges
  with `[REDACTED:SMS_OTP]` / `[REDACTED:BANK_NOTIFICATION]` /
  `[REDACTED:SENSITIVE_DOMAIN_URL]`.

So a frame containing `Your code is 482039` becomes
`Your code is [REDACTED:SMS_OTP]` *before* Tier1 sees it. The phone /
OTP shapes inside the redacted span are gone by the time the regex bank
scans. The `[REDACTED:…]` token itself is a recognisable pattern, and
Tier1 emits a `RedactedToken` entity for it so the brain knows a
cascade-redaction happened on this event (cross-app trace evidence for
V2-P11's privacy-moments surface) without storing the underlying bytes.

---

## Token-shape entities — REDACTED in place

Every entity in the **`redacted_token`** kind is stored as a
**subkind-only** entity. The mention text is replaced with the subkind
string (`"jwt"`, `"aws_access_key"`, `"github_pat"`, etc.) and the
**source bytes never persist**. The downstream graph can ask "was a
JWT present in this event?" without ever holding the JWT.

| Subkind             | Why we never store the bytes                                                      |
| ------------------- | --------------------------------------------------------------------------------- |
| `jwt`               | Bearer credential — replay grants impersonation.                                  |
| `aws_access_key`    | Cloud credential — replay grants account access.                                  |
| `github_pat`        | Cloud credential — replay grants repo access.                                     |
| `stripe_api_key`    | Cloud credential — replay grants payment surface.                                 |
| `bitcoin_wif`       | Private key — replay drains funds.                                                |
| `cascade_redacted`  | Already-redacted span — the marker itself, no source bytes recoverable.           |

The subkind is the canonical name. Two events containing two different
JWTs converge on the same `(kind="redacted_token", canonical_name="jwt")`
entity, with two distinct `entity_mentions` rows (separated by
`event_id`) — exactly the schema discipline V2-P3 ships.

---

## Bank (declaration order = evaluation order)

Tier1 evaluates **token-shape (REDACT) patterns first** so a JWT inside
a longer URL-shaped string never falls through to the URL extractor and
get stored as a URL.

### 1. `cascade_redacted` (subkind of `redacted_token`)

Pattern: `\[REDACTED:[A-Z_]+\]`

Marker that the OCR-time cascade replaced a sensitive span. Capturing
this as an entity gives the V2-P11 privacy-moments surface a
cross-app-edge anchor without re-deriving the cascade rule.

FP shapes accepted: none — the literal `[REDACTED:` prefix is the
cascade's own emission.

Fixture: `fixtures/cascade_redacted.txt`.

### 2. `jwt` (subkind of `redacted_token`)

Pattern: `\beyJ[A-Za-z0-9_=-]{8,}\.[A-Za-z0-9_=-]{8,}\.[A-Za-z0-9_=-]{4,}\b`

JWT compact serialization: three base64url segments separated by `.`.
Header almost always starts `eyJ` (base64url of `{"`). The 8/8/4 length
floors keep nonsense `a.b.c` strings out.

FP shapes accepted: none in practice (the `eyJ` prefix + three-segment
shape is very specific).

Fixture: `fixtures/jwt.txt`.

### 3. `aws_access_key` (subkind of `redacted_token`)

Pattern: `\b(?:AKIA|ASIA)[0-9A-Z]{16}\b`

AWS access key ID — 20 chars total, deterministic `AKIA` (long-lived)
or `ASIA` (session) prefix.

FP shapes accepted: none — the prefix is reserved by AWS.

Fixture: `fixtures/aws_access_key.txt`.

### 4. `github_pat` (subkind of `redacted_token`)

Pattern: `\bgh[pousr]_[A-Za-z0-9]{36,255}\b`

GitHub personal access token (`ghp_`), OAuth (`gho_`), user-to-server
(`ghu_`), server-to-server (`ghs_`), refresh (`ghr_`).

FP shapes accepted: none — GitHub reserves the `gh[pousr]_` prefix.

Fixture: `fixtures/github_pat.txt`.

### 5. `stripe_api_key` (subkind of `redacted_token`)

Pattern: `\b(?:sk|pk|rk)_(?:test|live)_[A-Za-z0-9]{24,}\b`

Stripe API key — secret (`sk_`), publishable (`pk_`), restricted
(`rk_`), in test or live mode.

FP shapes accepted: none — the `(sk|pk|rk)_(test|live)_` prefix is
Stripe-specific.

Fixture: `fixtures/stripe_api_key.txt`.

### 6. `bitcoin_wif` (subkind of `redacted_token`)

Pattern: `\b[5KL][1-9A-HJ-NP-Za-km-z]{50,51}\b`

Bitcoin Wallet-Import-Format private key. Starts with `5` (uncompressed)
or `K`/`L` (compressed); 51 / 52 base58 chars total.

FP shapes accepted: rare base58 strings starting with `5/K/L` of the
exact length. Acceptable — false positive cost is one phantom
`bitcoin_wif` mention; false negative cost is a private key landing in
the entity table.

Fixture: `fixtures/bitcoin_wif.txt`.

### 7. `url`

Pattern: `\bhttps?://[^\s<>"'\)\]\}]+`

HTTP / HTTPS URL — stop at whitespace, angle brackets, quotes, closing
brackets. We do not parse query strings (the URL is whatever the user
saw).

Canonical name normalisation: lowercase scheme + host; preserve
path/query exactly. Strip a trailing `.`, `,`, `;`, `:`, `!`, `?`
(punctuation the regex over-captures from sentence-final URLs).

FP shapes accepted: very rare — `http://` followed by gibberish lands
as a URL entity. The recall UX renders it as a link the user can
hover to verify.

Fixture: `fixtures/url.txt`.

### 8. `email`

Pattern: `\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b`

RFC 5322 simplified — local part = alnum + `._%+-`, domain = alnum + `.-`,
TLD ≥ 2 alpha chars.

Canonical name normalisation: lowercase the entire address.

FP shapes accepted: identifier-shaped strings with an `@` (Twitter
handles like `user@example`, where `example` lacks a TLD). The `\.[A-Za-z]{2,}`
floor blocks bare-domain false positives.

Fixture: `fixtures/email.txt`.

### 9. `phone`

Pattern: `(?:\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b`

Conservative US + international shape. Optional country code `+1` /
`+44` etc., optional area-code parens, three groups separated by
`-`/`.`/space.

Canonical name normalisation: strip every non-digit. `(415) 555-1234`
and `4155551234` and `415.555.1234` all converge on the same entity.

FP shapes accepted: 10-digit numbers in non-phone context (e.g. order
IDs that look like phones). Tier2 NER can re-classify; the brain holds
the canonical shape regardless.

Fixture: `fixtures/phone.txt`.

### 10. `ip_address`

IPv4 pattern: `\b(?:25[0-5]|2[0-4]\d|[01]?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|[01]?\d?\d)){3}\b`

Tight `0-255` octet check via the regex itself — no post-pass
range-validation needed.

IPv6 pattern: `(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}`

Full-form only; we skip `::` compressed shapes for V2-P4 (Tier2 NER
or a follow-on can widen the recognizer). The full form covers the
canonical logging output most apps emit.

Canonical name normalisation: lowercase; preserve dotted/colon shape
exactly.

FP shapes accepted: version strings like `10.15.7.0` (macOS) land as
IPv4 — acceptable noise.

Fixture: `fixtures/ip_address.txt`.

### 11. `crypto_address`

Three sub-patterns, evaluated in order:

- BTC bech32: `\b(?:bc1|tb1)[a-z0-9]{25,62}\b`
- BTC base58 (P2PKH / P2SH): `\b[13][a-km-zA-HJ-NP-Z1-9]{25,34}\b`
- ETH: `\b0x[a-fA-F0-9]{40}\b`
- SOL base58: `\b[1-9A-HJ-NP-Za-km-z]{43,44}\b`

Canonical name normalisation: preserve case for ETH (the checksummed
mixed-case shape is itself part of the address) and SOL; lowercase the
bech32 prefix; preserve base58 BTC as-is.

FP shapes accepted: the SOL shape is the most permissive — 43-44 char
base58 is a common shape for any arbitrary token. Acceptable noise;
Tier2 NER can re-classify.

Fixture: `fixtures/crypto_address.txt`.

### 12. `github_ref`

Pattern: `(?:^|[\s\(\[\{])#(\d{1,8})\b`

GitHub PR / issue reference — `#N` where N is 1–8 digits. Anchored
to start-of-string or whitespace/bracket so identifiers like
`abc#123` don't trigger.

Canonical name normalisation: just the digits — `#42` and ` #42 ` and
`(#42)` converge on the same canonical name `42`.

FP shapes accepted: any `#N` in non-GitHub context (e.g. `Issue #42`
in a non-repo note). Acceptable — the recall UX renders it as a
`github_ref` link that the user can hover.

Fixture: `fixtures/github_ref.txt`.

### 13. `uuid`

Pattern: `\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b`

RFC 4122 8-4-4-4-12 hex with dashes. We do not version-check (UUIDv1
through v8 all match) — any 36-char hyphenated hex shape converges on
the same `uuid` kind.

Canonical name normalisation: lowercase.

FP shapes accepted: none in practice — the shape is specific.

Fixture: `fixtures/uuid.txt`.

### 14. `ulid`

Pattern: `\b[0-9A-HJKMNP-TV-Z]{26}\b`

Crockford-base32 26-char ULID. The alphabet excludes `ILOU` (Crockford
ambiguity prevention) — a strict match keeps non-ULID 26-char
alphanumeric strings out.

Canonical name normalisation: uppercase (Crockford is case-insensitive
on input but ULID canonical is uppercase).

FP shapes accepted: a 26-char alphanumeric string composed only of the
Crockford alphabet — rare in non-ULID text.

Fixture: `fixtures/ulid.txt`.

### 15. `file_path`

Pattern: `(?:^|[\s\(\[\{])(/(?:[A-Za-z0-9._-]+/)+[A-Za-z0-9._-]+)\b`

Unix absolute path — leading `/`, one or more path segments, anchored
to start or whitespace/bracket. We require at least two segments
(`/foo/bar` not `/foo`) to keep simple terminal markers like `/`
out.

Canonical name normalisation: preserve as-is (paths are case-sensitive
on every OS we ship to).

FP shapes accepted: anything with multiple `/` segments — URL paths
without scheme (`/api/v1/users`) land here. Tier2 NER or a future
pass can re-classify.

Fixture: `fixtures/file_path.txt`.

---

## Anti-patterns (deliberately skipped in Tier1)

- **Person names**: V2-P5 Qwen NER.
- **Topics / project names**: V2-P5 Qwen NER.
- **Generic API tokens** (random 32-64 char alnum): too many false
  positives in OCR text (CSS class names, hashes, IDs). The named
  vendor-prefix tokens above cover the high-value cases.
- **Compressed IPv6** (`::1`, `fe80::a`): Tier2 / future tier.
- **Phone numbers with extension** (`x123` suffix): rare in typical
  capture; Tier2 / future tier.
- **Mailto URLs** (`mailto:foo@bar`): the embedded email match still
  fires; the `mailto:` scheme is informational.

---

## Footprint discipline (Footprint SLO §2 — G2 ≤10–15% / ≤2 GB)

The bank is **compiled once per process** via `OnceLock`. Each scan
walks the input text **once per regex** — `regex::RegexSet` would
collapse to one pass but we keep separate `Regex` so the per-kind
span info is available. The text is allocated as a single `String`
per match (no allocator churn beyond mention storage); the
extractor borrows the input.

Steady-state cost on a 4 KB OCR event with ~5 matches: <500 µs on
M1, dominated by regex DFA execution. Well inside the per-event
burst budget.
