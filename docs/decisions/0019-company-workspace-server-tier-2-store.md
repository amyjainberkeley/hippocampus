# ADR-0019 — Company Workspace Server + Tier-2 Encrypted Store (F-STRAT-002 server side)

- Status: Proposed (2026-05-20 afternoon; CEO+CSO draft pending human CEO ratification). Protected-set authoring (AGENT_PROTOCOL §5) because this ADR introduces MCI's first server-side surface, the first place brief content crosses a network boundary, and the first multi-party trust relationship in the system.
- Owners: **CSO** (binding — per-workspace key model + zero-knowledge enforcement + Cure53 audit scope) + **Director-Sync-Core** (server impl + client sync protocol + IPC seam from `mci-agent` to the workspace) + **CTO** (sequencing + cross-Director arbitration)
- Reviewers: **CSO** (veto-gate, every PR); CEO (ratification + entity-formation decisions); COO (pricing tier + sales motion + Cure53 RFQ); Director-Brain (brief authoring path that produces the upload inputs — ADR-0018); CRS Security-Signal analyst (CVE-watch on new crates the server pulls)
- Phase: 5 (between Phase 4 privacy controls / brief authoring per ADR-0017+ADR-0018 and Phase 6 agent-API extension). Lands AFTER ADR-0018 brief authoring PRs (P4.x.1..P4.x.5).
- **Protected-set: yes** (AGENT_PROTOCOL §5). Justification: this is the highest-stakes ADR in the project. It opens MCI's first server-side surface; defines the multi-party key model; commits the company to a vendor-blind architectural promise that the Cure53 audit will measure. Every PR below MUST carry a CSO sign-off block; the audit firm independently reviews this ADR + the implementation before v1.0 ships.
- Relationship: consumes the `Approved` brief artifacts ADR-0018 produces. Does NOT redefine the brief lifecycle. Adds the upload + cross-device + cross-member + retention paths. F-STRAT-002 dual-market depends on this ADR; no B2B revenue is possible without it.

## Context

F-STRAT-002 (2026-05-20 afternoon, ratified by CEO) committed MCI to a dual-market product with two privacy tiers. ADR-0018 specs Tier-2 brief authoring locally. **This ADR specs everything that happens AFTER the user clicks Approve.**

The architectural promise the COO GTM doc + CEO pitch make:

> "Approved briefs sync to your team's workspace under per-workspace end-to-end encryption. The workspace key wraps every brief; only enrolled team members hold it. Our sync server holds ciphertext we cannot decrypt — across devices, across people, across time. The team can query the workspace brain; we can't."

This ADR makes that paragraph implementable + audit-survivable. The Cure53 v1.0 audit (per COO GTM doc + F-STRAT-001b) reviews this ADR + the resulting server code; a clean audit is a launch blocker.

The trust model this ADR commits us to:

- **Vendor-blind:** Hippocampus the company (MCI's external brand) **cannot read user briefs** — not in transit, not at rest, not ever. Structural, not policy.
- **Team-readable:** members of a workspace **can read approved briefs** other members of the same workspace have uploaded. Cross-workspace read is impossible by construction.
- **User-controlled:** the user is the sole authority on what gets uploaded (per ADR-0018 §4.1). The server enforces no policy that could override this.
- **Crypto-shreddable:** deletion at any level (per-brief, per-user, per-workspace) destroys keys so ciphertext becomes unreadable, even from backups.

## Decision

### 1. Architecture — three trust roles, two key tiers

#### 1.1 Trust roles

- **Vendor** (Hippocampus the company): operates the sync server. Has root access to ciphertext + per-row metadata (who uploaded, when, which workspace). Has NO access to brief content. **Vendor cannot decrypt anything by construction.**
- **Workspace admin** (a customer's designated admin user): controls workspace enrollment (who can join, who is removed). Holds the workspace-key wrap key (along with all enrolled members). Cannot read brief content beyond what enrollment grants.
- **Workspace member** (an end user, individual contributor): holds the workspace key after enrollment. Can read every brief uploaded to the workspace. Can upload briefs they've authored.

#### 1.2 Key tiers

- **Per-device key** (per ADR-0008 + ADR-0012 §9 tightening): unchanged. Lives in Secure Enclave. Non-exportable.
- **Per-workspace key** (new, this ADR): 256-bit AES-256 (ChaCha20-Poly1305 for AEAD). Generated client-side on workspace creation by the admin. Stored:
  - On every enrolled member's device, **wrapped by that device's per-device key**. Unwrapped only in-memory at workspace-open.
  - On the server, NEVER (vendor-blind invariant).
- **Per-brief key** (new): each brief is encrypted under a per-brief 256-bit key that is itself wrapped by the workspace key. Per-brief keys exist for **crypto-shred-per-brief deletion** — destroying the per-brief key destroys access without rotating the workspace key.

This is the same shape as Signal / WhatsApp / Apple ADP — a well-trodden zero-knowledge architecture. The Cure53 audit reviews against this published model.

#### 1.3 Server architecture

```
┌──────────────────────────────────────────────────────────┐
│  Hippocampus Workspace Server (vendor-operated)          │
│                                                          │
│  workspaces table:                                       │
│    id, name, created_at, admin_member_id, audit_log_ptr  │
│                                                          │
│  members table:                                          │
│    id, workspace_id, device_pubkey, enrolled_at,         │
│    enrolled_by_member_id, role (admin|member),           │
│    removed_at (null if active)                           │
│                                                          │
│  briefs table:                                           │
│    id, workspace_id, uploaded_by_member_id,              │
│    uploaded_at, ts_brief, ciphertext_blob_path,          │
│    deleted_at (null if active), shred_after              │
│                                                          │
│  audit_log table:                                        │
│    id, workspace_id, action (enroll|remove|upload|delete │
│       |query|admin_action), actor_member_id, ts,         │
│       target_id (brief_id or member_id), client_ip_hash  │
│                                                          │
│  blob store:                                             │
│    content-addressed encrypted brief ciphertext          │
│    (server holds; cannot decrypt)                        │
└──────────────────────────────────────────────────────────┘
```

The server runs the simplest possible logic:
- Accept enrolled-member uploads (verify signature against `members.device_pubkey`).
- Serve ciphertext to enrolled members.
- Enforce member removal (after `removed_at`, member's device-key cannot decrypt new briefs because new per-brief keys are wrapped under a rotated workspace key — see §2 enrollment lifecycle).
- Maintain audit log.
- Run retention (delete `briefs` rows + ciphertext after `shred_after` timestamp).

**Server is NOT a relay-and-forget design** — it must enforce membership (signature verify on every upload + read). But the membership enforcement is on metadata (signed by per-device keys); the content stays encrypted.

#### 1.4 Server tech stack

- **Rust** (consistent with the portable core + F-STRAT-001b "audit-survivable closed source" stance — Rust's memory safety + cargo-audit story is easier to audit than Go/Node).
- **Postgres** for relational data (workspaces / members / briefs / audit_log). Server-side encrypted at rest via cloud provider's KMS (this is at-rest encryption of metadata, not content — content is already client-encrypted before upload).
- **S3-compatible object storage** for ciphertext blobs. Server holds path; never holds plaintext.
- **HTTPS + TLS 1.3** on the wire; mutual-TLS for client-to-server (client cert = per-device key — adds defense against TLS-stripping attacks).
- **No analytics / telemetry beyond audit log.** The audit log itself is content-free (action types + member IDs + timestamps; no brief content; no query content).
- **Hosted where?** Decision deferred to COO at Phase 5 entry. Likely options: AWS us-east-1 (default), Vercel (no — Vercel doesn't fit the server-side persistence story), Fly.io (good for distributed), Hetzner (cheap, EU jurisdiction — appeals to privacy-conscious buyers). Multi-region with workspace pinning at v1.0 is out of scope; single-region v1.0.

### 2. Workspace lifecycle

#### 2.1 Workspace creation

1. Admin user (someone with a Hippocampus Personal install + a paid Teams subscription) clicks "Create Workspace" in the desktop app.
2. Client generates a 256-bit workspace key locally + wraps it with the admin's per-device key.
3. Client sends to server: `(workspace_name, admin_device_pubkey)`. **No key material crosses the wire.**
4. Server creates `workspaces` row + `members` row (admin role) + signed enrollment record.
5. Admin is enrolled. Workspace key lives on admin's device only.

#### 2.2 Member enrollment

Adding a member to a workspace requires the workspace key to reach the new member's device — this is the moment a vendor-blind enrollment becomes a problem (the server can't help because it can't see the key).

Pattern: **existing-member-vouches**, modeled on Signal device-linking + Apple ADP recovery contacts.

1. Admin invites new member by email → server sends new member an enrollment invitation (link or QR code).
2. New member installs Hippocampus + signs in with the invite token.
3. **Out-of-band channel** to receive the workspace key:
   - **Default:** new member's client generates an ephemeral public key + posts to the server. An online admin or any existing enrolled member opens an "Approve Enrollment" prompt, verifies the new member's fingerprint (out-of-band — e.g., reading 6 emoji over Slack/Zoom, mirroring Signal's safety-number pattern), and the existing-member's client wraps the workspace key under the new member's ephemeral key + posts back. Server forwards the wrapped key. New member's client unwraps with the matching ephemeral private key + re-wraps with their per-device key for at-rest storage.
   - **Backup:** out-of-band paper code / QR code printed by the admin at workspace creation. New member can self-enroll with the code (admin re-shares manually). Less secure (paper code is the only secret) but works asynchronously.
4. Server's audit log records the enrollment action + which existing member approved.

This is the **highest-friction part of the UX** (Cure53 should pay extra attention here). The friction is intentional — silently-enrolled members are the exfiltration failure mode this design is engineered against.

#### 2.3 Member removal

When an admin removes a member:
1. Server marks `members.removed_at = now()`.
2. Server emits a "rotation needed" signal to all remaining enrolled members.
3. **Workspace key rotates.** Each remaining member's client generates a new workspace key + re-wraps every previously-uploaded brief's per-brief key under the new workspace key. Re-wrapped per-brief keys are uploaded to the server (replacing the old wrapped keys). **Old workspace key is destroyed on every device.**
4. The removed member's device still has the OLD workspace key. They cannot decrypt briefs whose per-brief keys are now wrapped under the new workspace key.
5. The removed member's device may have cached plaintext briefs they previously read; this is acceptable per the threat model (a former member retaining what they already saw is unavoidable; the protection is against NEW briefs after removal).

#### 2.4 Workspace deletion

Admin clicks "Delete Workspace":
1. Server marks `workspaces.deleted_at`.
2. All `briefs` rows for the workspace are marked `deleted_at` + scheduled for shred.
3. After a 30-day grace period, the server crypto-shreds: deletes ciphertext blobs + deletes `briefs` rows.
4. Admin can configure shorter grace (down to 0 days for immediate delete) or longer (up to 7 years for compliance scenarios) at workspace settings.
5. Member devices clear cached workspace keys + briefs on next sync.

### 3. Brief upload protocol

When a user clicks Approve on a brief (per ADR-0018):

1. Client generates a 256-bit per-brief key.
2. Client encrypts the brief content (markdown + source-event-IDs) under the per-brief key (AES-256-GCM or ChaCha20-Poly1305).
3. Client wraps the per-brief key with the workspace key.
4. Client signs the upload metadata (`workspace_id`, `member_id`, `ts_brief`, `wrapped_per_brief_key`, `ciphertext_hash`) with the per-device key.
5. Client POSTs `(metadata, signature, ciphertext_blob)` to server.
6. Server verifies signature, stores blob in object storage, inserts `briefs` row, emits audit log entry.
7. Other enrolled members fetch on next sync (push notification or poll; v1 uses polling).

**Per-brief key NEVER touches the server unwrapped.** Workspace key NEVER touches the server at all.

### 4. Privacy invariants — LOAD-BEARING (CSO veto-gate; Cure53 audit subject)

1. **Vendor cannot decrypt brief content.** The server never holds the workspace key or any per-brief key in plaintext. Verifiable by reading the server source code + the production deployment configuration (Cure53 reviews both).
2. **Server-side decryption is structurally impossible.** The server never instantiates a decryption primitive over brief ciphertext. The crate that handles ciphertext has no decrypt method; only encrypt + ferry. Audit by reading `Cargo.toml` + source.
3. **Per-workspace key rotation on member removal.** A removed member's old workspace key cannot decrypt new briefs because they're wrapped under the new key. Structural; tested.
4. **Audit log is content-free.** Action types + member IDs + timestamps only. No brief content, no query content, no workspace name in plaintext (workspace name itself is encrypted under the workspace key at the server — server holds only a hash).
5. **Member enrollment requires out-of-band fingerprint verification by an existing member.** No silent enrollment. CSO veto on any path that adds a "skip verification" option.
6. **Workspace deletion crypto-shreds.** After grace period, ciphertext blobs are destroyed. Even if backups exist, the per-brief keys are destroyed.
7. **Per-device key NEVER leaves the device.** Per ADR-0008 §1.5 + ADR-0012 §9. Server only sees device PUBLIC keys.
8. **The server logs no PII beyond what's structurally necessary.** Client IP is hashed (HMAC with a server-side rotating key; per-day rotation so cross-day correlation is bounded). User agent string is dropped. Geolocation is not logged.
9. **Compliance retention is user-/admin-controlled, NOT vendor-mandated.** Default 30-day grace on delete; admin configurable. Cure53 verifies vendor cannot extend retention silently.
10. **No backdoor key.** Hippocampus the company DOES NOT hold a master / recovery / escrow key. There is no key the vendor controls that can decrypt any brief. Workspace lockout (all admins lose their devices simultaneously) results in PERMANENT workspace loss. This is the strongest possible zero-knowledge promise and the one Cure53 audits hardest.

### 5. Workspace lockout / recovery

Per §4.10 — vendor holds no master key, so a workspace where all enrolled members lose their device-keys simultaneously is **unrecoverable**. The contents become unreadable forever.

Mitigations on the user side:

- **Multi-member admin requirement** — workspaces above N members (default 5) require ≥2 admins. Reduces lockout risk to "two admins simultaneously lose their devices."
- **Paper backup code** — at workspace creation, admin gets a printable code that, in concert with vendor-held metadata, can re-enroll a new admin device. The code IS sensitive (treat like a Bitcoin seed phrase); user-owned, never vendor-held. Lost paper code = permanent workspace loss.
- **Recovery via a designated existing member** — admin can pre-authorize specific members as recovery contacts. A recovery contact can vouch for a new admin device through the same fingerprint-verify pattern as §2.2.

These are user-side resilience patterns, not vendor-side escrow. The promise that vendor cannot recover stays intact.

### 6. PR sequence — Phase 5

Six PRs in `server/` (new repo subdirectory) + two PRs in the desktop client. Each protected-set; CSO sign-off blocks required.

- **P5.1 — `server/` repo scaffold.** New Cargo workspace member at `server/`. Rust + axum or actix-web. Empty handlers. Cargo.toml deps (audited): `axum`, `tokio`, `sqlx`, `serde`, `tracing`. Docker image build. 1 cycle.
- **P5.2 — Database schema + migrations.** `workspaces` / `members` / `briefs` / `audit_log` tables. Postgres migrations via `sqlx::migrate!`. Idempotent. 1 cycle.
- **P5.3 — Workspace + member enrollment endpoints.** `/workspaces POST`, `/workspaces/:id/members POST` (existing-member-vouches flow). Per-device-pubkey verification. 1 cycle.
- **P5.4 — Brief upload + read endpoints.** `/workspaces/:id/briefs POST` (signed upload), `/workspaces/:id/briefs GET` (list), `/workspaces/:id/briefs/:id GET` (ciphertext fetch). Object-store integration (S3-compatible). 1 cycle. **CSO-heavy** — this is the trust-boundary PR for the server.
- **P5.5 — Audit log + retention worker.** `audit_log` writes on every action. Background worker that scans for expired `shred_after` briefs + deletes. 1 cycle.
- **P5.6 — Client-side sync** in `apps/agent/` Rust crate. Pull on launch + every 5min. Push on Approve (per ADR-0018). Per-workspace key local persistence (wrapped by per-device key). Re-wrap on workspace-key rotation. 1 cycle. **CSO-heavy** — this is the trust-boundary PR for the client.
- **P5.7 — Workspace UX in recall UI.** Workspace settings panel (create / invite / remove / delete). Workspace-brain view (read team briefs). 1 cycle.
- **P5.8 — Cure53 audit prep.** Audit-readiness doc consolidating §4 invariants + threat model + per-PR review trail. Cure53 engagement begins. NOT a code PR; a coordination PR with the COO doing the firm onboarding.

### 7. Out of scope (deferred)

- **SSO / SAML / Workspace IdP integration** — Phase 6+. v1.0 uses email-invite + device-pubkey enrollment.
- **Compliance certifications** (SOC2 Type II, ISO 27001) — needed for enterprise sales; out of v1.0 scope. v1.1+ track.
- **Multi-region workspace pinning** — v1.0 single-region.
- **Cross-workspace federation** — out of scope. Each workspace is an island.
- **Workspace export** (download all briefs as a plaintext archive for the workspace admin) — Phase 9 retention/compaction.
- **Server-side search** — out of scope. Server is dumb ciphertext storage; querying is client-side (member's device decrypts all briefs they have access to, then runs FTS5 + sqlite-vec locally). For workspaces with very large brief volumes (10k+ briefs), Phase 9 considers cursor-paginated incremental sync.
- **Brief comments / annotations / threads** — Phase 6+. v1.0 ships read-only briefs.
- **Anonymous workspaces / Tor / proxy support** — out of scope for v1.0.

## Consequences

- Positive: F-STRAT-002 B2B revenue surface becomes engineering-implementable. Per-seat licensing has a thing to license.
- Positive: the "vendor-blind" trust narrative becomes audit-survivable. Cure53 reviews this ADR + the implementation; a clean report is the v1.0 launch credential.
- Positive: the per-workspace-key model is the same zero-knowledge architecture WhatsApp + Signal + Apple ADP use — well-trodden, publicly-audited at scale, builder confidence is high.
- Negative / tradeoff: workspace lockout is **permanent** (no vendor recovery). This is the cost of the zero-knowledge promise. UX must be very clear about backup codes + recovery contacts. CSO writes a "what we can't do for you" page that lives next to /security.
- Negative / tradeoff: existing-member-vouches enrollment is friction-ful (Signal-pattern verification). For enterprise buyers used to "IT admin adds a user, done," this is a real adoption barrier. Mitigations: paper-code self-enroll backup; SSO/SAML at v1.1+.
- Negative / tradeoff: Cure53 audit cost ($50-100K per COO GTM doc) is a real expense before v1.0 launch. Without it, the trust narrative is unsupported.
- Negative / tradeoff: 8-PR Phase 5 sequence + audit prep means Phase 5 is the longest single-phase scope in the project. COO GTM doc 2026-09 target needs to plan for this.
- Forces (binding):
  - No backdoor key (§4.10).
  - Server source code stays auditable (Cure53 must review).
  - Per-workspace key rotation on member removal (§2.3).
  - No silent enrollment (§4.5).

## CSO sign-off (placeholder — owed at first protected-set PR)

§4 invariants binding. Each PR carries the sign-off block. The Cure53 engagement formally audits both this ADR + the implementation. Vendor-blind promise is the load-bearing structural claim.

— CSO, pending (owed at PR P5.1)

## References

- **F-STRAT-002** + **ADR-0018** — the dual-market commit + Tier-2 brief authoring this ADR consumes.
- **ADR-0008** (encrypted store), **ADR-0012** (zero-knowledge spec — extends to multi-party here), **ADR-0014** (rustix supply-chain audit pattern — extended to all server deps), **ADR-0001** (privacy posture — local-first; this ADR extends to "vendor-blind in cloud").
- `docs/business/2026-05-20-gtm-positioning.md` — COO GTM doc (Cure53 RFQ section + pricing model).
- `docs/website/security.md` — the public-facing "How MCI protects you" page (this ADR's invariants are what that page promises).
- Signal protocol documentation (Asynchronous Ratchet Tree, prekey enrollment).
- WhatsApp Encrypted Backups white paper (HSM-rate-limited key recovery — pattern for our paper-code path).
- Apple ADP technical specification (per-device key + HSM destruction after N attempts — pattern for our recovery-contact path).
- Cure53 published audit reports (1Password / ProtonMail / Mullvad / Bitwarden — reference for what a clean report looks like in our market).
