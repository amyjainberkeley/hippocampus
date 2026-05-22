# ADR-0023 — Multi-Device Sync Model (Personal + Enterprise Tiers)

- Status: Accepted (2026-05-21; ratifies the multi-device sync decision from the CEO EOD discussion).
- Owners: **Director-Sync-Core** (sync protocol + CloudKit + server) + **CSO** (trust model)
- Reviewers: CSO (protected-set — sync protocol, key management, cross-device trust); CTO (sequencing); CEO (ratification); Director-Brain (local brain merge on incoming sync)
- Phase: 5 (enterprise sync via workspace server, already scaffolded per ADR-0019) + 9 (personal CloudKit sync, iOS/Watch targets)
- **Protected-set: yes** (AGENT_PROTOCOL §5). Justification: sync protocol, key management, cross-device trust model. Data crosses device boundaries. CSO veto-gate.

## Context

Users want their brain on all their devices. The product has two tiers with fundamentally different sync requirements:

- **Personal tier:** single user, Apple ecosystem (Mac + iPad + iPhone). The user already has iCloud. No MCI server infrastructure needed.
- **Enterprise/workspace tier:** multiple users, mixed fleet managed by IT. Requires a managed server (ADR-0019) for cross-member brief sharing.

A single sync model cannot serve both. CloudKit is free, zero-infrastructure, and Apple-E2E-encrypted — perfect for personal. But CloudKit cannot enforce workspace membership policies or cross-member access control — that requires the workspace server.

## Decision

### 1. Personal tier: CloudKit private database

Personal-tier sync uses CloudKit's private database (`CKContainer.default().privateCloudDatabase`).

#### 1.1 Transport

- Each sync delta is a `CKRecord` in a custom record type `MCISyncDelta`.
- Record fields: `delta_id` (string), `ciphertext` (CKAsset, encrypted delta blob), `ts` (date), `schema_version` (int).
- Private database = Apple handles storage + E2E encryption (with ADP enabled). MCI server is never involved.
- Push: `CKModifyRecordsOperation` on each brain write (debounced, max 1 push per 30 seconds).
- Pull: `CKFetchRecordZoneChangesOperation` with a server change token on app launch + every 5 minutes + on `CKSubscription` push notification.

#### 1.2 Key management

The brain encryption key travels via iCloud Keychain (ADR-0021). CloudKit carries only ciphertext — the key is never in a `CKRecord`.

#### 1.3 Conflict resolution

- Events are immutable after capture — no conflict possible for event rows.
- Annotations use last-writer-wins by `created_at` timestamp. If two devices annotate the same event simultaneously, both annotations are kept (they have different `id`s).
- Settings/preferences use last-writer-wins by `modified_at`.

#### 1.4 What syncs (personal tier)

- Events (screen captures, context signals, media consumption entries).
- Annotations.
- Agent logs.
- Episodes (segmentation metadata).
- Embeddings (pre-computed vectors — avoids re-embedding on each device).
- Denylist configuration.
- Retention policy configuration.

What does NOT sync: raw keyframe blobs (too large; syncing multi-GB video frames over iCloud is impractical). Keyframes are local-only. The recall timeline on a second device shows event text + metadata but not the original screenshot. A "View original" action prompts: "Original screenshot is on your Mac."

### 2. Enterprise tier: workspace server

Enterprise sync uses the workspace server (ADR-0019 §3).

#### 2.1 Transport

- Deltas uploaded to the workspace server as encrypted brief payloads.
- Per-workspace key wraps content (ADR-0019 §1.2). Server holds ciphertext only.
- Push: HTTPS POST on brief approval (ADR-0018).
- Pull: polling every 5 minutes (v1); push notifications via WebSocket (v1.1+).

#### 2.2 What syncs (enterprise tier)

- Approved briefs ONLY. Raw events, annotations, agent logs, and keyframes do NOT sync to the workspace server. The workspace sees only what the user explicitly approves for sharing (per ADR-0018 §4.1).
- Cross-member visibility depends on workspace monitoring mode (ADR-0027).

#### 2.3 Dual sync

A user can have BOTH personal sync (their own devices) AND enterprise sync (their workspace) active simultaneously. These are independent:

- Personal sync: full brain (events + annotations + agent logs) across the user's Apple devices via CloudKit.
- Enterprise sync: approved briefs only, to the workspace server.
- The user's local brain is the union. Incoming workspace briefs from other members appear in the local brain as read-only events (tagged `source: workspace`).

### 3. Offline-first

The local brain is always authoritative. Sync is eventually-consistent push/pull.

- If a device is offline for days, it accumulates local changes. On reconnect, all pending deltas sync.
- No "sync required" gate on any local operation. The brain works fully offline.
- Sync failures are retried with exponential backoff (1s, 2s, 4s, ... max 5min).
- Sync status is visible in the menu bar: a small sync icon shows "synced", "syncing", or "offline (N pending)".

### 4. Delta format

Sync deltas are content-addressed, append-only records:

```
DeltaRecord {
    delta_id:       UUID,
    device_id:      UUID,       // originating device
    ts:             DateTime,
    op:             Insert | Update | Delete,
    table:          "events" | "annotations" | "agent_logs" | "episodes" | ...,
    row_id:         TEXT,
    ciphertext:     Vec<u8>,    // AES-256-GCM encrypted row payload
    schema_version: u16,
}
```

Deltas are encrypted before leaving the device. The encryption key is:
- Personal tier: brain key (ADR-0021, via iCloud Keychain).
- Enterprise tier: per-workspace key (ADR-0019 §1.2).

### 5. Phase 9 scope: iOS and watchOS

- **iOS app** (Phase 9): read-only initially. Query brain, view timeline, search. Full capture on iOS = Phase 10+ (requires iOS screen recording API, which is heavily restricted).
- **watchOS app** (Phase 9): complications + glanceable recall ("last 3 events" complication, "what was I doing at 2pm" voice query).
- Both pull from the personal-tier CloudKit sync. No direct connection to the workspace server from iOS/watchOS in v1.

## Consequences

- **Positive:** Personal-tier users get multi-device brain access with zero server infrastructure from Hippocampus. CloudKit is Apple's cost, not ours.
- **Positive:** Enterprise tier uses the existing workspace server (ADR-0019) — no new server infrastructure.
- **Positive:** Dual sync means a user's personal brain and team workspace coexist without conflict.
- **Positive:** Offline-first means sync failures never block local usage.
- **Negative / tradeoff:** Keyframe blobs don't sync (too large). Second devices show text-only recall without original screenshots. Acceptable for v1; revisit with selective keyframe sync in Phase 10.
- **Negative / tradeoff:** CloudKit ties personal sync to Apple ecosystem. Android/Windows personal sync requires a different transport (future ADR). Enterprise sync via workspace server is platform-agnostic.
- **Negative / tradeoff:** Dual sync increases local storage — the user's brain holds their own events PLUS incoming workspace briefs. Covered by the storage budget (ADR-0024).
- **Negative / tradeoff:** iOS read-only is a deliberate scope cut. Users will want to capture on iPhone eventually, but iOS screen recording APIs are too restricted for v1.

## Alternatives considered

1. **Single sync protocol for both tiers (our own server for everything).** Rejected: forces personal-tier users onto MCI server infrastructure. Violates the zero-server personal-tier promise. CloudKit is free and Apple-encrypted.
2. **iCloud Drive file sync (share the SQLite file).** Rejected: SQLite is not safe for concurrent multi-device writes via file sync. CloudKit record-level sync is the correct abstraction.
3. **No personal sync — enterprise only.** Rejected: personal-tier multi-device is a top user request. "My brain should be on my phone" is a product requirement.
4. **Full keyframe sync via CloudKit.** Rejected for v1: a power user generates 5-10 GB/month of keyframes. iCloud storage is user-paid and limited. Text + metadata sync is sufficient for recall; keyframes are a nice-to-have.

## CSO sign-off (placeholder — owed at first protected-set PR)

Sync protocol introduces cross-device data flow. Personal tier: ciphertext via CloudKit (Apple E2E with ADP). Enterprise tier: ciphertext via workspace server (ADR-0019 §4 invariants). Brain key via iCloud Keychain (ADR-0021). Zero-knowledge preserved in both paths. Each PR carries the sign-off block.

— CSO, pending

## References

- **ADR-0008** — encrypted store (brain key protects sync deltas in personal tier).
- **ADR-0019** — workspace server (enterprise sync transport + per-workspace key).
- **ADR-0021** — brain key portability (iCloud Keychain provides key for personal sync).
- **ADR-0026** — bundled app architecture (iOS/watchOS targets are Phase 9).
- **ADR-0027** — workspace monitoring model (determines cross-member visibility in enterprise sync).
- Apple Developer Documentation: CloudKit, CKRecord, CKFetchRecordZoneChangesOperation, CKSubscription.
