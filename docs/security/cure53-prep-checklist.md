# Cure53 Pre-Audit Preparation Checklist

- **Author:** Director-Sync-Core (2026-05-21)
- **Status:** Draft — CSO reviews before RFQ; COO owns vendor engagement.
- **Audience:** CSO (scope sign-off), COO (RFQ packaging), Cure53 engagement lead, CEO (ratification).
- **Relationship:** Operationalizes the audit commitment from F-STRAT-001b (trust-by-audit) + the COO GTM doc (`docs/business/2026-05-20-gtm-positioning.md` §"Published third-party security audit").

## 1. Engagement overview

| Field | Value |
|---|---|
| Audit firm | **Cure53** (Berlin; audited 1Password, ProtonMail, Mullvad VPN, Bitwarden) |
| Engagement type | White-box source-code audit + architecture review |
| Budget estimate | $50K–$100K (refine on RFQ; COO owns) |
| Target start | After Phase 5 packaging completes (~2026-07–08) |
| Report publishes | Alongside v1.0 launch (~2026-09) |
| Report format | Full PDF, published on `mci.com/security` (URL TBD) + written MCI responses to every finding |
| Follow-up audit | Trail of Bits at v1.1+ (post-Phase 5 sync + Phase 7 browser extension) |

## 2. Scope — what Cure53 reviews

### 2.1 The protected set (AGENT_PROTOCOL §5)

These are the surfaces where a bug = user data leaks. Highest priority.

| Surface | ADR | Key files / crates | What to verify |
|---|---|---|---|
| **Suppression cascade** | ADR-0013 | `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Cascade/` | Cascade ordering (§1→§7); fail-closed default (§3); `.suppress` fires before any pixel crosses IPC; no stored suppressed frame; privacy tombstone emission |
| **Cascade-twice for OCR** | ADR-0016 §1.6 | Same cascade + `OCRPostAllowEmitter` | After OCR completes, OCR'd text re-enters cascade; text containing secret/PII patterns is suppressed post-OCR even if the pixel was `.allow`'d |
| **`.mediaConsumption` path** | ADR-0020 | Cascade + `streaming-apps.toml` | Captures strictly LESS than `.allow`; no pixel keyframe; no OCR; two-condition gate enforced; curated list not user-extensible |
| **Encrypted store** | ADR-0008 | `core/store/` | SQLCipher page-level encryption; 256-bit `DbKey` zeroization; SE-gated `KeyWrap`; no plaintext residue on `close()` |
| **Key custody** | ADR-0012 §9 | `core/crypto/` + `adapters/macos/` Keychain integration | Per-device key SE-backed, non-exportable, biometric-gated; key never in env/argv/code; `InMemoryKeyWrap` compile-error tripwire in release |
| **IPC wire schema** | ADR-0014 + wire PRs | `core/src/ipc/wire.rs` + `Wire.swift` | Payload-strict-consumption (no trailing-byte tolerance); `SCM_RIGHTS` receive-path hardened; lock-step version bump across Swift/Rust/Python |
| **Per-workspace key model** | ADR-0019 §1.2 | `server/` (Phase 5) | Vendor-blind invariant; workspace key NEVER on server; per-brief key wrap; existing-member-vouches enrollment; NO BACKDOOR KEY |
| **Brief upload protocol** | ADR-0019 §3 | `server/` + `apps/agent/` sync client | Per-brief key never touches server unwrapped; signature verification on upload; audit log content-free |
| **Crypto-shredding** | ADR-0019 §2.4 | `server/` retention worker | Deletion destroys per-brief keys → ciphertext unreadable from backups |
| **Zero-network thesis** | ADR-0016 §4.4 | All `core/` + `adapters/macos/` | No network calls in capture pipeline, OCR pipeline, embed pipeline, brain store, or retrieval. Verifiable by `lsof` + code audit |

### 2.2 Threat model coverage

Source: ADR-0012 §9 (tightened), ADR-0013, ADR-0019 §4.

| Threat | MCI defense | Cure53 verifies |
|---|---|---|
| **Plaintext at rest** | SQLCipher whole-file encryption; SE-gated key; no off switch | Key can't be read by another process; no plaintext residue in WAL/journal/temp |
| **Plaintext in same-user process** (the Recall failure mode) | Library validation; hardened runtime; minimal plaintext residency; buffer zeroization; re-auth on recall-UI open | No unprotected process can read decrypted brain content; `mci-agent` process hardening |
| **Capture of sensitive surface** | 7-layer cascade (ADR-0013 §1–§7) + cascade-twice (ADR-0016 §1.6) | No pixel/text from suppressed events reaches store; tombstone covers every suppression; fail-closed |
| **IPC wire tampering** | Strict payload consumption; version-locked frames; fd-pass hardened | Malformed wire frame rejected; no partial parse; ancillary fd bounded |
| **Supply-chain (dependencies)** | Zero net-new crates on critical path (verified per-PR); `cargo-audit` in CI; CRS Security-Signal analyst watches | Dependency tree audit; no known CVEs in tree; no typosquat risk |
| **Auto-updater hijack** | Sparkle 2.x + EdDSA + HTTPS-only (Phase 5) | No HTTP fallback; EdDSA signature verified before install; no RSA-only path |
| **Vendor exfiltration (server)** | Vendor-blind by construction (ADR-0019 §4.1); no decrypt primitive in server crate | Server source code has no decrypt method; workspace key never on server; audit log content-free |
| **Silent enrollment** | Out-of-band fingerprint verification required (ADR-0019 §4.5) | No code path adds a member without existing-member approval |
| **Workspace lockout → vendor recovery** | NO BACKDOOR KEY (ADR-0019 §4.10) | No master/escrow/recovery key in server source or deployment config |
| **Rollback / truncation / key-substitution** | Hash-chained append-only encrypted delta log (ADR-0012 §9; Backendal CRYPTO 2024) | Sync log detects tampered/truncated history; key-substitution rejected |

### 2.3 Prior art — what went wrong elsewhere (Cure53 should test against these)

| Product | Failure | MCI structural defense | Cure53 test |
|---|---|---|---|
| **Microsoft Recall (2024)** | Plaintext screenshots on disk; no capture-time filtering | SQLCipher encryption default-on; cascade before encode | Attempt to read `mci.sqlite` without key; verify no plaintext in WAL/temp |
| **Microsoft Recall (2026 — TotalRecall Reloaded)** | `AIXHost.exe` unprotected process leaks decrypted screenshots to same-user attacker | Library validation; hardened runtime; re-auth on recall-UI | Attempt cross-process read of `mci-agent` decrypted memory |
| **screenpipe issue #3467** | Unauthenticated log-share URL leaks screen data | No network sharing in v1; server is ciphertext-only | Verify no HTTP endpoint exposes brain content |
| **Recall "4-digit PIN" degradation** | Biometric gate degraded to weak PIN | SE-backed key; biometric-only access control; no PIN fallback | Verify no fallback auth weakens key access |

## 3. In-scope vs out-of-scope

### In-scope (v1.0 audit)

- All code in `core/` (Rust portable core — store, crypto, brain, IPC wire, agent)
- All code in `adapters/macos/MCICaptureHelper/` (Swift capture helper — cascade, OCR, context providers)
- All code in `server/` (Rust workspace server — Phase 5)
- `apps/agent/` sync client (Phase 5 upload/download path)
- `apps/recall-ui/` (FFI boundary to brain store; re-auth gate)
- `streaming-apps.toml` + `known-safe-apps.toml` (curated lists)
- Build/signing pipeline (`scripts/build-release.sh`, notarization config)
- Auto-update configuration (Sparkle 2.x appcast + EdDSA key)
- Wire protocol (all versions: 0x01→current)
- Deployment configuration (server Dockerfile, env vars, secrets management)

### Out-of-scope (deferred to Trail of Bits v1.1+ audit)

- Browser extension (`extensions/<browser>/`) — Phase 7; not shipped at v1.0
- Windows adapter (`adapters/windows/`) — Phase 8; not shipped at v1.0
- SSO / SAML / IdP integration — Phase 6+
- Mobile clients — not planned
- Third-party integrations (Slack bot, etc.) — Phase 6+
- CI/CD pipeline security (GitHub Actions) — separate engagement

## 4. Privacy invariants table (hand to Cure53 as acceptance criteria)

Each invariant is a PASS/FAIL criterion for the audit. A FAIL on any is a launch blocker.

| # | Invariant | Source ADR | Test method |
|---|---|---|---|
| P1 | Vendor cannot decrypt brief content | ADR-0019 §4.1 | Read server source; verify no decrypt primitive over brief ciphertext |
| P2 | Server never holds workspace key | ADR-0019 §4.1 | Search server codebase for key derivation/storage; verify only public keys |
| P3 | Per-workspace key rotates on member removal | ADR-0019 §2.3 | Simulate removal; verify old key cannot decrypt new briefs |
| P4 | Audit log is content-free | ADR-0019 §4.4 | Read audit_log schema + writes; verify no brief content / query content / plaintext workspace name |
| P5 | No silent enrollment | ADR-0019 §4.5 | Attempt enrollment without existing-member approval; must fail |
| P6 | No backdoor key | ADR-0019 §4.10 | Search entire codebase + deployment config for master/escrow/recovery key patterns |
| P7 | Cascade fires before pixel crosses IPC | ADR-0013 §2 | Trace `.suppress` path in Swift helper; verify no surface handle passed to Rust core |
| P8 | Unknown element → redact (fail-closed) | ADR-0013 §3 | Present helper with unknown AX element; verify `.suppress(reason=7)` emitted |
| P9 | Cascade-twice suppresses secret in OCR'd text | ADR-0016 §1.6 | OCR a frame containing a password; verify text is masked before brain store |
| P10 | `.mediaConsumption` stores no pixel/OCR | ADR-0020 §4.1 | Trigger `.mediaConsumption` path; verify no keyframe blob, no OCR invocation |
| P11 | Encrypted store has no plaintext residue | ADR-0008 | Close + reopen `mci.sqlite` without key; verify zero readable content in file + WAL + temp |
| P12 | Per-device key never leaves device | ADR-0008 §1.5 | Verify SE non-exportable flag; verify server only sees public key |
| P13 | Zero network calls in pipeline | ADR-0016 §4.4 | Run capture+OCR+embed+store under network monitor; verify zero egress |
| P14 | Crypto-shredding destroys access | ADR-0019 §2.4 | Delete brief; verify per-brief key destroyed; verify ciphertext unreadable |
| P15 | Auto-updater verifies EdDSA signature | GTM doc §5.2 | Serve tampered appcast; verify update rejected |

## 5. Deliverables MCI owes before engagement starts

| # | Deliverable | Owner | Status |
|---|---|---|---|
| D1 | This prep checklist (reviewed by CSO) | Director-Sync-Core | Draft (this file) |
| D2 | ADR ladder complete through Phase 5 (ADR-0001..0020) | CTO + Directors | ADR-0001..0019 on main; ADR-0020 in flight |
| D3 | Phase 5 server code complete + tested | Director-Sync-Core | Not started (Phase 5) |
| D4 | Phase 5 client sync code complete + tested | Director-Sync-Core | Not started (Phase 5) |
| D5 | Build/signing pipeline operational | Director-Sync-Core | Not started (Phase 5) |
| D6 | Sparkle 2.x auto-updater configured | Director-Sync-Core | Not started (Phase 5) |
| D7 | Threat model document (this §2.2 expanded) | CSO | Draft (this file) |
| D8 | Test harness for auditor (build instructions, test commands, env setup) | CTO | Not started |
| D9 | RFQ sent to Cure53 | COO | Not started |
| D10 | Cure53 NDA + SOW signed | COO + CEO | Not started |

## 6. Engagement logistics

- **Access model:** Cure53 gets read-only access to the private GitHub repo for the engagement duration. Access revoked after report delivery. No commit access.
- **Communication:** Dedicated Slack channel (or email thread) for findings-in-progress. CSO is primary MCI contact; COO handles scheduling/billing.
- **Finding classification:** Cure53's standard severity scale (Critical / High / Medium / Low / Info). MCI commits to fix all Critical + High before v1.0 launch; Medium addressed in v1.0 or v1.0.1 with timeline; Low + Info tracked as backlog.
- **Report publication:** Full PDF on `mci.com/security`. No redactions (strongest trust signal). MCI appends written responses to each finding.
- **Re-test:** Cure53 re-tests Critical + High fixes before report finalizes. Budget includes one re-test cycle.
