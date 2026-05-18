# ADR-0012 — Zero-knowledge spec: per-device SE-backed keys, authenticated enrollment, hash-chained delta log, same-user-process threat model, process-hardening, crypto-shred deletion, SSE = non-goal

- Status: Accepted (2026-05-18; ratified by human CEO via /night-run cycle 2; implements ratified fork #8)
- Owner: CSO
- Reviewers: CEO; Director-Sync-Core (binding on every future `core/crypto/`, `core/sync/`, `core/keymgmt/`, and `server/` change)
- Phase: 0
- **Protected-set: yes** (AGENT_PROTOCOL §5 — crypto, key-management, sync, sensitive-capture, entitlements, notarization)

## Context

`docs/AGENT_QUESTIONS.md` fork #8 (verbatim Recommendation): "*A. CSO owns and signs this into the Phase 0 crypto ADR before `core/` crypto/sync code is written (AGENT_PROTOCOL §5). Store engine fork #4 (Option A) is unaffected and confirmed.*"

The motivating finding (CRS Stream E, verified primary-source in the Verification pass): **Microsoft Recall is MCI's risk register; it failed publicly twice.**
- **2024:** plaintext SQLite + screenshots + no content filtering (captured passwords / CVVs; Krebs / Beaumont disclosures).
- **2025/26 redesign** (TotalRecall Reloaded, CSO Online 2026-04-16): vault sound but decrypted data handed to an **unprotected same-user process** (`AIXHost.exe`); same-user malware exfiltrates everything. The DB-at-rest model alone is insufficient.

DESIGN.md §9.2 ("*A user master key (derived from a passphrase + per-device keys; recovery-code backed)*") is too vague to implement safely. This ADR specifies the model concretely **before any `core/` crypto/sync code is written** (AGENT_PROTOCOL §5: protected-set; CSO-signed).

CEO ratified 2026-05-18.

## Decision

### 1. Key model (per-device, server-never-vouches)

1. Each device generates a **per-device asymmetric keypair** at first run.
   - **macOS:** Secure Enclave–backed key (`SecKeyCreateRandomKey` with `kSecAttrTokenIDSecureEnclave`), elliptic-curve P-256 (the SE-supported curve). Private key is **non-exportable**; access-controlled by `kSecAccessControlBiometryCurrentSet + .userPresence`, accessibility `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
   - **Windows (recorded for Phase 8):** TPM-backed key via DPAPI-NG or Microsoft Platform Crypto Provider; equivalent non-exportable / per-user-this-device-only discipline.
2. Each device additionally holds the wrapped DB master key from ADR-0008 (at-rest only). The two keys are distinct and serve different roles: ADR-0008's key protects the local SQLCipher file; this ADR's keypair protects the **transport-layer** zero-knowledge sync.
3. **The sync server has no role in key trust.** Server-side identity = an opaque per-user identifier issued at signup; the server never signs, vouches for, or verifies a device's identity. All device-to-device trust is bootstrapped without the server.

### 2. Device-to-device authenticated enrollment

When the user adds a second device:

1. The existing (already-trusted) device displays a short numeric / QR code derived from a freshly generated short-lived enrollment shared secret.
2. The new device collects the secret out-of-band (camera / typed) and uses it to authenticate a short PAKE-style exchange (e.g., CPace) directly over the sync transport — the server relays bytes but the protocol is end-to-end-authenticated.
3. The existing device **cross-signs the new device's public key** with its own SE-held private key. The cross-signature is appended to the user's device-key registry (itself stored in the encrypted delta log, §3 below).
4. The new device, on receiving the cross-signature, derives the **shared user master key** by combining its own SE-backed key with the existing device's contribution and the enrollment secret. Recovery of past memory follows §4.
5. The server **never sees** the enrollment secret, the cross-signature payload in plaintext, or the user master key. It sees ciphertext blobs and a delta log sequence.

The verified production precedents for this shape are **WhatsApp / Meta Encrypted Backups (engineering.fb.com 2026-05-01)** and **Apple Advanced Data Protection** — server-never-vouches device trust with HSM-backed recovery. Both confirmed in the CRS Verification pass.

### 3. Hash-chained, append-only, encrypted delta log

1. The sync protocol is an append-only **encrypted delta log**. Each entry: `seq, device_id, op, ciphertext, nonce, prev_hash, tag` where `prev_hash` is the BLAKE3 hash of the prior entry's `(seq || ciphertext || nonce || tag)` and `tag` is the AEAD authentication tag over the entry plus `prev_hash`.
2. **Hash-chaining defends against rollback, truncation, and key-substitution attacks** described in Backendal et al., CRYPTO 2024 (and its ACM CCS 2024 companion paper). Attribution erratum applied per the Verification pass: cite the **paper body and CCS-2024 companion**, not the abstract.
3. Each device verifies the chain from its last-known good `seq` forward on every sync round; an out-of-order or unsigned entry aborts the sync and surfaces a user-visible warning. The server cannot rewrite history without producing a chain that fails verification on every client.
4. The log is the only canonical state. Clients reconstruct the SQLite store by replaying entries; the local `mci.sqlite` is a materialized view, never the source of truth for sync purposes.

### 4. Recovery (catastrophic single-device loss)

1. The default recovery posture for users with **multiple devices** is just: enroll a new device from an existing trusted one (§2). No vault, no recovery code.
2. For users with **one device only**, the recovery posture is an **HSM-rate-limited recovery vault**:
   - At first-device setup the user opts into recovery and produces a 128-bit recovery secret (24-word BIP39-style or 6-group printable code; user choice). The recovery secret is **never stored on the device**; the user records it.
   - A blinded transform of the recovery secret (a *recovery handle*) is shipped to an HSM-backed recovery vault. The HSM holds a per-user counter and **self-destructs (zeroes) the wrapping after N=10 failed attempts** — same envelope as Apple ADP, where Apple's HSMs destroy the escrow after 10 attempts.
   - On recovery the user re-derives the handle from their recovery secret, the HSM verifies + decrements the counter, and a wrapped form of the user master key is returned. The unprotected wallet on the new device unwraps it locally.
   - **The recovery vault holds no plaintext key material** and cannot be compelled to reveal the wrapping after N failed attempts; mass-attempt attacks are bounded by the per-user counter + the HSM hardware envelope.
3. The recovery vault is the **only** path where the server has any role in key flow, and even there it is mediated by an HSM that we cannot subvert from server software alone.

### 5. Threat model addition (§9.1) — plaintext in MCI's own same-user-accessible process

DESIGN.md §9.1's existing list ("cloud sync server must never read user content; device-local attacker must not get plaintext at rest; user must have hard controls to not capture") is extended with:

> **Plaintext in an MCI same-user-accessible process while running.** MCI is an all-day daemon. Any other process running as the same user is, by default, able to read MCI's memory and IPC channels via standard OS APIs. A same-user attacker that did not have to break disk-at-rest encryption can still exfiltrate everything in the recall window. **This is exactly how Microsoft Recall's 2025/26 redesign failed** (`AIXHost.exe` unprotected-process leak, TotalRecall Reloaded, CSO Online 2026-04-16). MCI's at-rest model alone is insufficient.

### 6. Process-hardening mitigations (§10)

Binding on the agent shell (`apps/agent/`), the recall UI (`apps/recall-ui/`), and the macOS Swift helper (`adapters/macos/`):

1. **Hardened runtime on macOS.** All binaries are signed with the hardened runtime enabled and **library validation on** (`com.apple.security.cs.disable-library-validation = false`). No third-party library injection without an explicit signed entitlement.
2. **Notarization-pinned.** Each binary is notarized and the build pipeline refuses to release an un-notarized binary. The notarization team identifier is pinned in the agent's launch checks; a non-matching helper is refused.
3. **Re-authentication on recall-UI open.** The recall UI process requires a fresh Touch ID / passcode unlock before the wrapping key is unwrapped, regardless of system unlock state. The unlocked window is bounded by a configurable idle timeout (default 5 minutes).
4. **Buffer zeroization.** Every place plaintext (DB key, decrypted page text, decrypted images) lives is in a zero-on-drop buffer (`secrecy::SecretVec` or platform-locked memory). No `Vec<u8>` of plaintext in `core/**` may outlive a single recall-API call without an explicit review.
5. **Minimal plaintext residency.** The brain decrypts only what is currently in the active recall window (top-k results plus immediate temporal neighbors). Bulk-decrypt-to-working-set is forbidden. The retrieval pipeline computes scores on encrypted/redacted-index where possible and decrypts only on the materialization step.

### 7. SSE = explicit non-goal

**Searchable Symmetric Encryption is not on the roadmap.** Search runs on the user's own device against the device's own decrypted-in-memory index. SSE is designed for the threat model where a server holds an index and must answer queries without learning them; MCI has no such server. Adopting SSE would add the well-known leakage-abuse exposure (CCS 2023 / arXiv:2309.04697 family) for zero functional gain. This non-goal is binding: no PR may introduce server-side searchable encryption.

### 8. Deletion = crypto-shredding per-segment keys + tombstones

1. The encrypted delta log is segmented; each segment is encrypted with a **per-segment key** derived from the user master key plus a segment salt.
2. To delete a time range, MCI: (a) emits a tombstone entry to the delta log marking the range, (b) **destroys (zeroizes) the per-segment key** for every segment overlapping the range, (c) drops the local plaintext for those segments.
3. Server-side delete is **not trusted** as a privacy primitive — the server can claim to have deleted a blob it kept. The only durable delete primitive is destruction of the per-segment key. Once destroyed, the blob is ciphertext forever, with no key in any user's possession to recover it.
4. "Forget last hour" / range delete / full wipe all route through this primitive. Full wipe also destroys the user master key and the wrapped DB key in the Keychain (ADR-0008).

### 9. Secret-detection (defense in depth, not the guarantee)

The on-device redaction pass (DESIGN.md §9.3) is **defense-in-depth, never the guarantee**. Verified state of the art per the **Basak et al.** paper (arXiv:2307.00714 — *"A Comparative Study of Software Secrets Reporting by Secret Detection Tools"*; **"SecretBench" is the dataset name, not the paper title**, erratum applied) is best-tool **recall ≈ 52–88%**. The 12%–48% miss rate is why the load-bearing primitive is source-level capture suppression (denylist + incognito drop the frame before the pipeline; AGENT_PROTOCOL §4 / DESIGN.md R5) — not pattern matching on OCR output.

### 10. The Recall "4-digit PIN" claim is intentionally not load-bearing

CRS Verification erratum (applied): the claim that Microsoft Recall's biometric gate degrades to a 4-digit PIN is **weakly sourced** (not in the authoritative CSO Online / Computerworld coverage of TotalRecall Reloaded). It is intentionally not cited in this ADR. The **unprotected-same-user-process** argument (§5–§6 above) fully carries the process-hardening rationale on its own.

## DESIGN.md edits required by this ADR

Surgical edits in the same PR as this ADR:

- **§9.1 (Threat model)** — append "plaintext in an MCI same-user-accessible process while running" per §5 above.
- **§9.2 (Encryption)** — tighten the passphrase / per-device-key sketch to point at this ADR for the concrete model (per-device SE-backed keypair, device-to-device authenticated enrollment, HSM-rate-limited recovery vault, hash-chained log).
- **§9.3 (Sensitive-content controls)** — note that the redaction pass is defense-in-depth (≈52–88% recall, Basak et al. arXiv:2307.00714); source-level capture suppression is the load-bearing primitive.
- **§10 (Runtime architecture)** — append the process-hardening list (hardened runtime + library validation; notarization-pinned; re-auth on recall-UI open; zeroization; minimal plaintext residency).

(These edits land on `claude/cso/phase0-adrs` together with this ADR. The non-CSO-touching edits to §8/§12/§13 belong to ADR-0010/0011 on the sibling CTO branch and do not overlap.)

## Consequences

- Positive: every named Microsoft Recall failure mode now has a concrete mitigation written down before any code is authored. The "trust is the product" thesis becomes auditable, not aspirational.
- Positive: the cryptographic shape (per-device SE keys, authenticated enrollment, hash-chained log, HSM-rate-limited recovery) matches the two strongest production analogs (Apple ADP, WhatsApp Encrypted Backups) — both verified primary sources.
- Positive: crypto-shredding deletion makes "delete" a real guarantee, not a server promise.
- Negative / tradeoffs: process-hardening is a real engineering cost — the agent, the recall UI, and the Swift helper each carry signing + entitlements + notarization-pinned launch checks. CSO + CTO own that lane in the Phase-1 implementation PRs.
- Negative / tradeoffs: single-device recovery via an HSM vault is real infrastructure to operate. Phase 5 (sync) implementation may stage as multi-device-only first, with the recovery vault following.
- Forces (binding on every future `core/**` + `apps/**` + `server/**` change):
  - No code path bulk-decrypts beyond the active recall window.
  - No `Vec<u8>` of decrypted plaintext escapes a recall-API call without an explicit CSO note.
  - Any addition or change to entitlements, hardened-runtime flags, or notarization config is protected-set (AGENT_PROTOCOL §5) and requires fresh CSO review.
  - SSE may not be introduced; PRs proposing it are rejected at design.
  - Any "soft delete" path that does not destroy a per-segment key is rejected as not actually being delete.

## Alternatives considered

- **B — leave DESIGN §9 as-is and resolve during implementation.** Rejected. This is exactly the failure mode of Recall: cryptography designed ad hoc as code is written, with no spec to test against. Once `core/**` crypto code lands, restructuring the model is a forklift — unrecoverable cost.

## CSO sign-off

This ADR (and ADR-0008) are protected-set authorings owned by the CSO under AGENT_PROTOCOL §5. They are **binding on every future `core/**` crypto, key-management, sync, store, and entitlements / notarization change.** Any deviation by an implementer — a Director, an IC, or a future agent — requires a fresh CSO review and an amending ADR. The CSO veto on protected-set PRs is final unless the human CEO overrides.

— CSO, 2026-05-18

## References

- DESIGN.md §4 (architecture), §9 (threat model, encryption, sensitive controls), §10 (runtime + process model)
- docs/AGENT_PROTOCOL.md §4 (zero-knowledge invariant, sensitive-capture launch-blocker), §5 (CSO protected-set with veto)
- docs/AGENT_QUESTIONS.md fork #8 (2026-05-18, ratified `accept recommendation`) + CRS Verification verdict
- docs/RESEARCH_DIGEST.md Stream E + Verification pass items 13 (SecretBench citation), 14 (Backendal attribution), 15 (Recall PIN hedge)
- Backendal et al., CRYPTO 2024 (paper body + ACM CCS 2024 companion) — rollback / truncation / key-substitution taxonomy
- WhatsApp / Meta Encrypted Backups (engineering.fb.com, 2026-05-01) — HSM-rate-limited recovery vault precedent
- Apple Advanced Data Protection — Secure Enclave + HSM-after-N escrow precedent
- TotalRecall Reloaded (CSO Online / Computerworld, 2026-04-16) — Recall same-user-process failure mode
- Basak et al., arXiv:2307.00714 — secret-detection state of the art
- ADR-0001 (privacy posture), ADR-0008 (at-rest store + Keychain key custody — companion protected-set ADR)
