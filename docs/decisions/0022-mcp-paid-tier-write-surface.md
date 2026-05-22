# ADR-0022 — MCP Paid-Tier Write Surface

- Status: Accepted (2026-05-21; ratifies the MCP write-tier decision from the CEO EOD discussion).
- Owners: **Director-Brain** (MCP tool implementation) + **Director-Sync-Core** (entitlement check) + **COO** (pricing — explicitly TBD)
- Reviewers: CSO (protected-set — writes to mci.sqlite store); CTO (sequencing); CEO (ratification)
- Phase: 5 (server-side entitlement infrastructure) + post-launch (pricing decision)
- **Protected-set: yes** (AGENT_PROTOCOL §5). Justification: introduces write paths to the mci.sqlite store via MCP. New tables (`annotations`, `agent_logs`) are user content stored on disk. CSO veto-gate.

## Context

The MCP server (ADR-0016 §6, PRs #96/#110/#128) currently exposes 5 read-only tools:

- `mci_recall` — natural-language search over the brain
- `mci_events_since` — events after a timestamp
- `mci_stats` — aggregate statistics
- `mci_episodes` — episode listing
- `mci_events_by_app` — events filtered by application

These are free forever. AI agents (Claude Code, Cursor, Windsurf, etc.) can query MCI's brain at no cost.

Write access is the monetization lever. Power users and enterprises want agents that can annotate events ("this meeting was important"), log structured agent activity ("deployed v2.3 to staging"), and build on top of MCI's brain as a platform. This is higher-value usage that justifies a paid tier.

## Decision

### 1. Free tier: read-only (unchanged)

The 5 existing MCP tools remain free. No entitlement check on read paths. Any MCP client can connect and query.

### 2. Paid tier: two new write tools

#### 2.1 `mci_annotate`

Adds a text annotation to an existing event by `event_id`.

```json
{
  "tool": "mci_annotate",
  "input": {
    "event_id": "evt_abc123",
    "text": "Key decision made in this meeting — approved Q3 roadmap",
    "author": "claude-code"
  }
}
```

- Stored in a new `annotations` table: `(id, event_id, text, author, created_at)`.
- Annotations are embedded and indexed like event text — they appear in `mci_recall` search results.
- Multiple annotations per event are allowed.
- Annotations are soft-deletable via a future `mci_delete_annotation` tool (not in v1 scope).
- Event must exist; returns error if `event_id` is invalid.

#### 2.2 `mci_agent_log`

Writes a structured agent activity log entry.

```json
{
  "tool": "mci_agent_log",
  "input": {
    "agent_id": "claude-code-session-xyz",
    "action": "deployed",
    "context": "Deployed mci-server v2.3 to fly.io production",
    "metadata": {"commit": "abc123", "env": "production"}
  }
}
```

- Stored in a new `agent_logs` table: `(id, agent_id, action, context, metadata_json, created_at)`.
- `context` field is embedded and indexed — queryable via `mci_recall` ("what did my agent do yesterday").
- `metadata` is stored as JSON, not indexed (structured data for programmatic access).
- `agent_id` is caller-provided, not enforced (MCP has no auth in v1; entitlement check is per-connection).

### 3. Entitlement check

Write tools require a valid entitlement. The check is local and offline-capable:

- **Local license file:** `~/Library/Application Support/MCI/license.json` containing a signed entitlement token. The token is signed by Hippocampus's public key (bundled in the app). Verification is offline — no network call per write.
- **Workspace enrollment token:** for enterprise users, the workspace enrollment (ADR-0019 §2.2) doubles as a write entitlement. If the user is enrolled in a workspace, write tools are enabled.
- **Fallback:** if neither license file nor workspace enrollment exists, write tools return a structured error: `{"error": "write_entitlement_required", "message": "MCP write tools require a Hippocampus Pro license. Read-only tools are free."}`.

The entitlement check runs once at MCP connection init, not per-call. The result is cached for the connection lifetime.

### 4. Rate limiting

100 writes per minute per MCP connection. Prevents runaway agent loops from filling the brain with noise.

- Tracked per-connection with a sliding window.
- Exceeding the limit returns `{"error": "rate_limited", "retry_after_seconds": N}`.
- The limit applies to `mci_annotate` + `mci_agent_log` combined.

### 5. Pricing: EXPLICITLY TBD

The CEO has NOT decided the price point. This ADR locks the **surface** (what write tools exist and how they work), not the **price** ($/mo, per-seat, usage-based, etc.).

Open questions for COO + CEO:
- Monthly subscription vs. one-time license?
- Personal Pro vs. Team tier bundling?
- Free trial period for write tools?
- Usage-based pricing (per-write) vs. flat rate?

These are business decisions, not architectural ones. The entitlement system (§3) supports any pricing model — the license file is a signed token with an expiry and a tier field.

### 6. Zero-knowledge preserved

Write tools write to the LOCAL brain only. Annotations and agent logs are stored in `mci.sqlite` alongside events, encrypted at rest by SQLCipher (ADR-0008).

If workspace sync is enabled (ADR-0019), annotations sync like events — E2E encrypted with the per-workspace key. The sync server holds ciphertext only.

### 7. Schema additions

```sql
CREATE TABLE annotations (
    id          TEXT PRIMARY KEY,
    event_id    TEXT NOT NULL REFERENCES events(id),
    text        TEXT NOT NULL,
    author      TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    deleted_at  TEXT
);

CREATE TABLE agent_logs (
    id            TEXT PRIMARY KEY,
    agent_id      TEXT NOT NULL,
    action        TEXT NOT NULL,
    context       TEXT NOT NULL,
    metadata_json TEXT,
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX idx_annotations_event_id ON annotations(event_id);
CREATE INDEX idx_agent_logs_agent_id ON agent_logs(agent_id);
CREATE INDEX idx_agent_logs_created_at ON agent_logs(created_at);
```

Both tables are included in FTS5 indexing and the embedding pipeline (chunker treats annotation text and agent_log context as embeddable content).

## Consequences

- **Positive:** Monetization path for MCI as a platform. AI agents writing structured data into the brain creates a flywheel — the more agents annotate, the more valuable recall becomes.
- **Positive:** Free read-only tier ensures adoption. No barrier to agents querying MCI. Write tools are the upsell.
- **Positive:** Offline entitlement check means no phone-home per write. Privacy-preserving monetization.
- **Negative / tradeoff:** Two new tables increase brain store complexity and storage usage. Mitigated by storage budget (ADR-0024).
- **Negative / tradeoff:** Rate limiting (100/min) may be too restrictive for bulk-import scenarios. Revisit if enterprise users need higher limits.
- **Negative / tradeoff:** Pricing is TBD — the product can ship write tools technically before the business model is decided, but the entitlement system needs a license-issuance backend before paid users can actually activate.
- **Negative / tradeoff:** MCP has no built-in auth. The entitlement check is per-connection, not per-user. A malicious local process could reuse another process's MCP connection. Acceptable for v1 (local-only threat model; the attacker already has local access).

## Alternatives considered

1. **All tools free, monetize elsewhere (support, hosting).** Rejected: MCP write access is the clearest value differentiation. Read-only is table stakes; writes are platform.
2. **Per-write micropayments.** Rejected for v1: too complex, requires payment infrastructure. Flat subscription is simpler.
3. **Server-side write tools (write to workspace server).** Rejected: writes are local-first per the zero-knowledge thesis. Server-side writes would require the server to see content.

## CSO sign-off (placeholder — owed at first protected-set PR)

New write paths to mci.sqlite. `annotations` and `agent_logs` tables contain user content (annotation text, agent context). Encrypted at rest by SQLCipher. Rate limiting prevents abuse. Each PR carries the sign-off block.

— CSO, pending

## References

- **ADR-0008** — encrypted store (SQLCipher protects both new tables at rest).
- **ADR-0016** §6 — MCP server architecture (this ADR extends it with write tools).
- **ADR-0019** — workspace server (enterprise entitlement path; annotation sync).
- **ADR-0024** — storage budget (annotations + agent_logs count toward the 25 GB cap).
- PRs #96, #110, #128 — existing MCP read-only tools.
