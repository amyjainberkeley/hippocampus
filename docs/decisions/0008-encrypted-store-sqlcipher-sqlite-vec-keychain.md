# ADR-0008 — Encrypted store: `rusqlite` + bundled SQLCipher + FTS5 + sqlite-vec; SE-gated, biometric-controlled, non-exportable Keychain-wrapped key

- Status: Accepted (2026-05-18; ratified by human CEO via /night-run cycle 2; implements ratified fork #4)
- Owner: CSO
- Reviewers: CEO; Director-Sync-Core (binding on every future `core/store/` and `core/crypto/` change)
- Phase: 0
- **Protected-set: yes** (AGENT_PROTOCOL §5 — at-rest crypto + key custody + the `mci.sqlite` store)

## Context

`docs/AGENT_QUESTIONS.md` fork #4 (verbatim Recommendation): "*A. Proven page encryption, native FTS5, sqlite-vec loadable, clean Keychain key-wrap. CSO signs the key-custody model in ADR-000X before the store module is written.*"

CRS Verification verdict (verbatim from `docs/AGENT_QUESTIONS.md` and `docs/RESEARCH_DIGEST.md` Stream D): "*Option A **CONFIRMED** — sqlite-vec is the **only** store that preserves the single-encrypted-file / zero-knowledge invariant (LanceDB/DuckDB/usearch break it; DuckDB-VSS persistence is crash-unsafe for an always-on daemon). Harden the key model: Secure-Enclave-gated, biometric-access-controlled, **non-exportable**, `…ThisDeviceOnly`.*"

DESIGN.md §9.2 (at-rest): "*the SQLite store + blob store encrypted with a device-held key (SQLCipher / OS keystore-backed key — Keychain on macOS, DPAPI/Credential Manager on Windows). Memory store is never plaintext on disk.*"

CEO ratified 2026-05-18.

## Decision

### Store engine

1. **One encrypted SQLite file (`mci.sqlite`)**, opened from Rust via `rusqlite` with the **bundled SQLCipher** feature. Page-level AES encryption is provided by SQLCipher. There is no fallback unencrypted mode; the store layer refuses to open an unencrypted database.
2. **FTS5** compiled into the same SQLite build (bundled-SQLCipher includes FTS5).
3. **`sqlite-vec`** loaded as a runtime extension at connection-open time. The extension binary is shipped inside the signed app bundle (macOS) / installer payload (Windows); the connection refuses to enable extension loading from arbitrary filesystem paths — only the bundled path is accepted.
4. **One file, one writer.** SQLite WAL mode; a single writer connection inside the agent process; readers (recall UI, agent loopback API) use separate read-only connections to the same encrypted file. Connection-open requires the unwrapped DB key (see below) and the bundled sqlite-vec extension path.
5. **Blob store.** Keyframe / segment blobs are content-addressed on disk under the user's app-support directory. Blob files are **separately encrypted** with a per-blob key derived from the DB master key (HKDF, per-blob salt = content hash). The `blobs` table holds only the hash + ciphertext path + metadata, never plaintext. This keeps the page-encryption story coherent for both the DB and the blob bucket.

### Key custody (the CSO-owned model)

1. **DB master key** = a random 256-bit key, generated at first run inside the Rust core's CSPRNG (the OS RNG via `getrandom`).
2. **At-rest wrapping:** the DB master key is **wrapped by a Keychain-stored wrapping key** with the following attributes (binding on the implementation):
   - **macOS:** Keychain item with `kSecAttrTokenID = kSecAttrTokenIDSecureEnclave` (Secure Enclave-backed key), `kSecAccessControlBiometryCurrentSet` + `kSecAccessControlPrivateKeyUsage` access-control flags (biometric / device-passcode gate; biometry-current-set so adding a fingerprint invalidates the wrap, not "biometry-any"), `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The Secure Enclave key is **non-exportable** — `kSecAttrIsPermanent = true`, no `kSecReturnData` ever. Unwrapping calls the SE via `SecKeyCreateDecryptedData` and never touches the wrapping key plaintext.
   - **Windows (Phase 8, recorded here for completeness, not implemented at Phase 0):** DPAPI-NG with a TPM-backed key + Windows Hello access control. The same non-exportable / `ThisUserOnly` discipline applies.
3. **In-memory key residency.** The unwrapped DB master key lives in a `secrecy::SecretVec<u8>`-equivalent buffer (or platform-locked memory where available). It is zeroized on agent shutdown, on screen-lock, after an idle timeout configurable by the user, and after the recall-UI window closes. The store layer never logs, never serializes, never sends to telemetry the unwrapped key. The literal byte string `postgresql://` and any DB URL form never appears in argv, env, or logs.
4. **Never in code / argv / env.** The DB master key has exactly two homes: (a) wrapped in the Keychain (rest), (b) inside the locked in-memory buffer (use). Any third place is a bug.
5. **First-run binding.** At first run the user authenticates via Touch ID / passcode, the Secure Enclave wrapping key is generated, the freshly-generated DB master key is wrapped, the wrap is stored in the Keychain. The user is shown the recovery posture (handled in ADR-0012: device-to-device authenticated enrollment for multi-device users; HSM-rate-limited recovery vault for catastrophic single-device loss).
6. **At rotation.** Rotation is rare but supported (e.g., on suspected device compromise the user can run "rekey memory"). Rotation re-encrypts the DB pages with a new master key in a background transaction; the old key is zeroized when the rotation transaction commits.

### What this ADR does NOT cover

This ADR is **at-rest only**. Transport-layer end-to-end encryption, the per-device keypair, device-to-device authenticated enrollment, recovery-vault design, the hash-chained delta log, the same-user-process threat model, and the process-hardening mitigations are all in **ADR-0012**. Both ADRs are protected-set; both are CSO-owned; they are written in concert and reference each other.

## Consequences

- Positive: page-level encryption on the **only** vector-store choice that keeps everything in one SQLCipher file. The zero-knowledge invariant for cloud sync (ADR-0001, ADR-0012) is preserved because the syncable artifact is a single ciphertext stream — no out-of-band index file to leak.
- Positive: the Secure-Enclave wrap with biometry-current-set and `ThisDeviceOnly` matches Apple ADP / WhatsApp HSM patterns (CRS Verification). A device-level attacker that steals the disk image cannot decrypt without the SE; a same-user attacker cannot exfiltrate the wrapping key (non-exportable).
- Positive: rotation is a real primitive, not just a wish. Crypto-shredding deletion (ADR-0012) becomes per-segment-key destruction backed by the same key model.
- Negative / tradeoffs: SQLCipher's bundled C build adds binary size + a non-trivial build configuration; CRS Security-Signal analyst auto-reviews any SQLCipher version bump (CVE adjacent). sqlite-vec is brute-force only — performance discipline lives in ADR-0011's scaling ladder.
- Negative / tradeoffs: SQLite WAL + a single writer + the bundled-SQLCipher build means tests cannot use an in-memory SQLite as a stand-in trivially; the test harness opens an ephemeral encrypted file with a test key, never an unencrypted memory DB.
- Forces (binding on every future `core/**` change):
  - The store module never opens a database with extension loading enabled for arbitrary paths.
  - The store module never accepts a DB key from argv, env, or a config file.
  - Any change to the Keychain access-control flags, the in-memory key buffer, the rotation path, or the blob-key derivation is a protected-set PR requiring CSO re-review (AGENT_PROTOCOL §5).
  - Any new dependency added to the `core/store/` or `core/crypto/` crates triggers a CRS Security-Signal CVE / supply-chain check before merge.

## Alternatives considered

- **B (`libsql` embedded with built-in encryption, future Turso sync path).** Rejected — sqlite-vec + FTS5 extension story is less proven on libsql; future Turso sync is irrelevant under MCI's zero-knowledge thesis (the sync server cannot be a feature provider). The Verification pass confirmed sqlite-vec on rusqlite+SQLCipher is the only option preserving the single-encrypted-file invariant.
- **C (plain `rusqlite` + app-layer field encryption).** Rejected — page-level cipher is the whole point; field-level leaks structure, indexes, FTS internals, and row counts. CRS Privacy stream's failure-mode analysis (Recall 2024) is a direct argument against this shape.

## References

- DESIGN.md §4 (architecture), §9 (privacy/encryption), §10 (runtime), §12 (data model), §13 (tech stack)
- docs/AGENT_PROTOCOL.md §4 (zero-knowledge invariant), §5 (CSO protected-set)
- docs/AGENT_QUESTIONS.md fork #4 (2026-05-18, ratified `accept recommendation`) + CRS Verification verdict
- docs/RESEARCH_DIGEST.md Stream D + Stream E + Verification pass
- ADR-0001 (privacy posture), ADR-0009 (384-d schema pin), ADR-0012 (transport-layer crypto + threat model + process-hardening + recovery)
