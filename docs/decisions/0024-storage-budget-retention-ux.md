# ADR-0024 — Storage Budget + Retention UX

- Status: Accepted (2026-05-21; ratifies the storage budget decision from the CEO EOD discussion).
- Owners: **Director-Brain** (storage accounting + purge logic) + **Director-Recording** (onboarding UX + menu bar warning)
- Reviewers: CTO (sequencing); CEO (ratification)
- Phase: 4 (retention purger already landed, PR #127) + 7 (onboarding UX for initial cap choice)
- **Protected-set: no.** No crypto, sync, or sensitive-capture change. Normal review process.

## Context

MCI is an always-on screen recorder. At default capture rates (adaptive FPS, ~2-5 keyframes/min with dedupe), a typical workday generates:

- ~500-1500 events with OCR text + metadata
- ~200-600 keyframe blobs (HEIC, ~50-200 KB each)
- ~100-300 MB/day of brain growth (events + embeddings + blobs)

Over months, this accumulates. An unmanaged brain fills the user's disk without warning. The retention purger (PR #127, implementing ADR-0017 §4) already exists but has no budget trigger — it only runs on explicit schedule.

Users need a clear, non-surprising storage budget with agency over the tradeoff between brain size and retention depth.

## Decision

### 1. Default cap: 25 GB

The local brain store (mci.sqlite + blob directory) has a default cap of 25 GB. This provides approximately:

- ~3-6 months of typical usage at default capture rates
- Enough history to be useful for "what was I working on last month" queries
- Small enough to not surprise users on 256 GB base-model MacBooks (< 10% of disk)

### 2. Storage accounting

Storage is measured as:

```
brain_size = sqlite_size + blob_dir_size

sqlite_size = PRAGMA page_count * PRAGMA page_size   // mci.sqlite
blob_dir_size = du -s ~/Library/Application Support/MCI/blobs/
```

Measured on each brain write, cached for 60 seconds to avoid I/O overhead. The cached value is exposed via `mci_stats` MCP tool and the menu bar tooltip.

### 3. Warning at 90% (22.5 GB)

When `brain_size` exceeds 90% of the cap:

1. **macOS notification** via UserNotifications framework: "Your Hippocampus brain is 22.5 GB of 25 GB. Open settings to manage storage."
2. **Menu bar icon state change**: yellow dot overlay on the Hippocampus status item.
3. Notification fires once per 24-hour period (not on every write past 90%).

### 4. Cap-hit behavior: user chooses

When `brain_size` reaches 100% of the cap, new captures continue (never silently stop recording) but a modal appears:

```
Your brain is full.
───────────────────
Your Hippocampus brain has reached 25 GB.

[Grow to 50 GB]     — No limit on your storage. Your disk, your choice.
[Keep 25 GB + Prune] — Auto-prune oldest events to stay under 25 GB.
```

- **Grow:** doubles the cap. User can grow indefinitely (their disk, their choice). No hard maximum.
- **Prune:** enables auto-prune mode. The retention purger (PR #127) runs with oldest-first ordering until brain size is under 80% of the cap (20 GB). Respects the 1-hour safety floor (ADR-0017 §4) — events less than 1 hour old are never purged.

The modal is dismissable but re-appears after every 1 GB of additional growth if the user neither grows nor prunes.

### 5. Auto-prune mechanics

When auto-prune is enabled:

1. Events are deleted oldest-first by `created_at`.
2. Associated keyframe blobs are deleted with each purged event.
3. Annotations and agent logs referencing purged events are cascade-deleted.
4. Embeddings for purged events are removed from sqlite-vec.
5. FTS5 index entries for purged events are removed.
6. Purge runs until `brain_size < 80%` of cap (hysteresis to avoid purge-on-every-write).
7. `VACUUM` runs after bulk purge (> 100 events purged) to reclaim SQLite free pages.
8. Purge is logged: `purged N events (oldest: YYYY-MM-DD, newest: YYYY-MM-DD), reclaimed X MB`.

### 6. Onboarding integration

Onboarding step 4 (after TCC permissions + key setup) presents the storage budget:

```
Storage Budget
──────────────
Hippocampus will use up to 25 GB for your brain.
That's about 3-6 months of typical usage.

You can change this anytime in Settings.

[Continue with 25 GB]    [Choose a different size...]
```

"Choose a different size" offers: 10 GB, 25 GB (default), 50 GB, 100 GB, Unlimited.

### 7. Enterprise: workspace-managed caps

Workspace admins can set a fleet-wide default cap via workspace policy:

```json
{
  "storage_cap_gb": 50,
  "allow_user_grow": true,
  "allow_user_shrink_below_fleet": false
}
```

- `allow_user_grow`: users can grow above the fleet default locally.
- `allow_user_shrink_below_fleet`: users cannot set a cap below the fleet minimum (prevents users from accidentally purging data the workspace expects to be available for brief authoring).

### 8. Blob cleanup detail

When events are purged:

1. The purger collects all `blob_path` values from the events being deleted.
2. Blob files are `unlink`ed from the blob directory.
3. If a blob is referenced by multiple events (unlikely but possible with dedupe), it is only deleted when the last referencing event is purged.
4. The blob directory is not `VACUUM`ed (it's a filesystem directory, not SQLite) — `unlink` reclaims space immediately.

## Consequences

- **Positive:** Users are never surprised by disk usage. Clear budget, clear warning, clear choice.
- **Positive:** "Grow" option respects user agency — no artificial cap. The default just prevents surprise.
- **Positive:** Auto-prune reuses the existing retention purger (PR #127) — no new deletion infrastructure.
- **Positive:** Hysteresis (purge to 80%, warn at 90%, modal at 100%) prevents purge thrashing.
- **Negative / tradeoff:** 25 GB default may be too small for power users or too large for users on small SSDs. Configurable at onboarding mitigates this.
- **Negative / tradeoff:** `VACUUM` after bulk purge is expensive (rewrites the entire SQLite file). Mitigated by only running after 100+ event purges and running in background thread.
- **Negative / tradeoff:** Enterprise fleet caps add configuration complexity. Acceptable for the enterprise tier.

## Alternatives considered

1. **No cap (unlimited by default).** Rejected: users on 256 GB MacBooks would be surprised by a 50+ GB brain after a year. Explicit budget is more trustworthy.
2. **Time-based retention only (keep last N days).** Rejected: storage grows at different rates depending on usage patterns. A GB-based cap is more predictable for disk planning.
3. **Cloud offload (move old events to server).** Rejected: violates zero-knowledge for personal tier. The personal brain is local-only.
4. **Compression before cap check.** Rejected for v1: SQLCipher + HEIC blobs are already compressed. Further compression yields diminishing returns and adds CPU cost.

## References

- **ADR-0017** §4 — retention policy, 1-hour safety floor (this ADR builds on it).
- **PR #127** — retention purger implementation (reused by auto-prune).
- **ADR-0024** is referenced by ADR-0022 (annotations + agent logs count toward cap) and ADR-0023 (incoming workspace briefs count toward cap).
