# ADR-0021 — Brain Key Portability (iCloud Keychain + Passphrase Option)

- Status: Accepted (2026-05-21; ratifies the brain-key portability decision from the CEO EOD discussion).
- Owners: **Director-Brain** (Keychain integration) + **Director-Sync-Core** (cross-device key availability) + **CSO** (crypto review)
- Reviewers: CSO (protected-set — key management, crypto); CTO (sequencing); CEO (ratification)
- Phase: 4 (onboarding UX) + 5 (cross-device key availability)
- **Protected-set: yes** (AGENT_PROTOCOL §5). Justification: key management and crypto. The brain encryption key's storage location and derivation method are the most security-critical choices in the local-only path. CSO veto-gate.

## Context

The brain encryption key (per ADR-0008) is currently generated and stored locally in the macOS Keychain. Users who reinstall macOS, replace their Mac, or add a second Mac lose access to their brain unless they have a manual backup. This is the #1 data-loss risk for personal-tier users.

iCloud Keychain syncs Keychain items across the user's Apple ID device chain automatically, with Apple's end-to-end encryption (Advanced Data Protection). This solves the portability problem for Apple-ecosystem users at zero additional infrastructure cost.

Users who distrust iCloud or use non-Apple platforms need an alternative. A passphrase-derived key (Argon2id KDF) provides a cross-platform, user-controlled option at the cost of passphrase management burden.

## Decision

### 1. Default: iCloud Keychain

The brain encryption key is stored as a Keychain item with iCloud sync enabled:

```
kSecClass:              kSecClassGenericPassword
kSecAttrService:        "com.hippocampus.brain-key"
kSecAttrAccount:        "default"
kSecAttrSynchronizable: true          // syncs via iCloud Keychain
kSecAttrAccessible:     kSecAttrAccessibleAfterFirstUnlock
```

`kSecAttrAccessibleAfterFirstUnlock` means the key is available after the first device unlock per boot cycle. This balances security (not available at boot before login) with usability (available to the background agent without requiring the user to open Hippocampus.app after every reboot).

### 2. Optional: Passphrase-derived key (Argon2id)

At onboarding (step 2, after TCC permissions), the user may choose "Use a passphrase instead of iCloud Keychain." This path:

1. Prompts for a passphrase (minimum 12 characters, zxcvbn strength ≥ 3).
2. Generates a 16-byte random salt.
3. Derives a 256-bit key via Argon2id with OWASP-recommended parameters:
   - Memory: 19456 KiB (19 MiB)
   - Iterations: 2
   - Parallelism: 1
4. Stores the salt in a header block prepended to the encrypted SQLite database file.
5. The derived key is used as the SQLCipher encryption key (same as the Keychain-stored key in the default path).

The passphrase is never stored. On every app launch, the user enters the passphrase to derive the key. A "remember for session" option keeps the derived key in memory until app quit (not persisted to disk or Keychain).

### 3. Onboarding choice is one-time, reversible

The choice between iCloud Keychain and passphrase is presented once at onboarding. It can be changed later in Settings → Brain → Encryption:

- **Keychain → Passphrase:** prompts for new passphrase, re-encrypts the database with the derived key, removes the Keychain item.
- **Passphrase → Keychain:** prompts for current passphrase, stores the existing key in Keychain, removes the salt header.

Re-encryption uses SQLCipher's `PRAGMA rekey` — an atomic operation that re-encrypts in place.

### 4. Migration of existing local-only keys

Users upgrading from a pre-ADR-0021 install have a local-only Keychain item (`kSecAttrSynchronizable = false`). On first launch after the update:

1. Hippocampus detects the non-synchronizable key.
2. Presents a one-time prompt: "Enable iCloud Keychain sync for your brain key? This lets you access your brain on other Apple devices. [Enable] [Keep Local]"
3. **Enable:** updates the Keychain item to `kSecAttrSynchronizable = true`.
4. **Keep Local:** no change. User can enable later in Settings.

No data migration or re-encryption is needed — the key value is identical; only the sync attribute changes.

### 5. Cross-platform key availability

For the personal sync tier (ADR-0023), iCloud Keychain provides automatic key availability across Mac, iPad, and iPhone — the key syncs with zero additional protocol.

For the enterprise/workspace tier, the per-workspace key (ADR-0019 §1.2) is separate from the brain key. The brain key protects the LOCAL brain; the workspace key protects UPLOADED briefs. They are independent. A user can have an iCloud-synced brain key for their personal brain AND a workspace key for their team.

### 6. What this ADR does NOT do

- **Does not change the brain key format.** Still a 256-bit symmetric key for SQLCipher. ADR-0008 is unchanged.
- **Does not introduce key escrow.** Neither Apple nor Hippocampus can recover the key. iCloud Keychain with ADP is E2E encrypted. Passphrase loss = brain loss.
- **Does not add key backup to the workspace server.** The brain key is personal-tier only. Workspace sync uses a separate per-workspace key (ADR-0019).
- **Does not support non-Apple platforms for the Keychain path.** Windows users (Phase 8) will use either passphrase or a platform-specific credential store (Windows Credential Manager — separate ADR when Phase 8 crypto lands).

## Consequences

- **Positive:** Users who reinstall macOS or move to a new Mac retain access to their brain automatically via iCloud Keychain. The #1 personal-tier data-loss risk is eliminated.
- **Positive:** Passphrase option provides a vendor-independent, cross-platform fallback that works without any cloud dependency.
- **Positive:** Zero-knowledge preserved. The key never leaves the user's device chain. iCloud Keychain with ADP is Apple's E2E encryption — Apple cannot read it. Hippocampus the company never sees it.
- **Negative / tradeoff:** iCloud Keychain dependency ties the default path to Apple's infrastructure. Users who disable iCloud Keychain fall back to local-only (pre-ADR-0021 behavior) or passphrase.
- **Negative / tradeoff:** Passphrase-derived keys add UX friction (enter passphrase on every launch unless "remember for session" is checked). Most users should use the Keychain default.
- **Negative / tradeoff:** `kSecAttrAccessibleAfterFirstUnlock` means the key is in the Keychain's in-memory cache after first unlock. An attacker with device access post-unlock could extract it. This matches the threat model of every other macOS Keychain-using app (1Password, Safari passwords, etc.).

## Alternatives considered

1. **Custom cloud key sync (our own server).** Rejected: adds server-side key storage, violates zero-knowledge for the personal tier. iCloud Keychain already solves this without us touching the key.
2. **Hardware key (YubiKey / FIDO2).** Rejected for v1.0: too much friction for a consumer product. Revisit for enterprise tier.
3. **QR code key transfer (scan from old Mac to new Mac).** Rejected: manual, error-prone, requires both devices online simultaneously. iCloud Keychain is strictly better for Apple users.

## CSO sign-off (placeholder — owed at first protected-set PR)

Key management change. iCloud Keychain with `kSecAttrSynchronizable = true` relies on Apple's ADP E2E encryption. Argon2id parameters follow OWASP 2024 recommendations. Both paths preserve zero-knowledge. Each PR carries the sign-off block.

— CSO, pending

## References

- **ADR-0008** — encrypted store, SQLCipher, Keychain storage (this ADR extends §1.5 with sync attribute).
- **ADR-0012** §9 — zero-knowledge spec tightening (key non-exportability; iCloud Keychain sync is Apple-managed, not MCI-managed export).
- **ADR-0019** §1.2 — per-workspace key (separate from brain key; this ADR does not affect workspace crypto).
- **ADR-0023** — multi-device sync model (personal tier relies on this ADR for key availability).
- Apple Developer Documentation: Keychain Services, `kSecAttrSynchronizable`, Advanced Data Protection.
- OWASP Password Storage Cheat Sheet 2024: Argon2id recommended parameters.
