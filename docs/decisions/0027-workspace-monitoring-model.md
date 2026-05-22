# ADR-0027 — Workspace Monitoring Model (Org Transparency)

- Status: Accepted (2026-05-21; ratifies the workspace monitoring model decision from the CEO EOD discussion. Follows the Meta-MCI pattern).
- Owners: **Director-Sync-Core** (server-side workspace policy) + **CSO** (trust model review)
- Reviewers: CSO (protected-set — changes the trust model for workspace members); CTO (sequencing); CEO (ratification); COO (enterprise positioning implications)
- Phase: 5 (workspace server already has enrollment per ADR-0019) + 7 (workspace creation UX)
- **Protected-set: yes** (AGENT_PROTOCOL §5). Justification: introduces a monitoring mode that changes the trust relationship between workspace members. In `transparent` mode, members can see each other's approved briefs. This is a material change to the privacy model for workspace users. CSO veto-gate.

## Context

Enterprise customers want team visibility ("what is my team working on," "who covered this topic last week"). Privacy-conscious organizations want sync without surveillance. One model does not serve both.

Meta's internal tool (the product MCI is modeled on) had org-wide transparent monitoring — employees were informed that their screen activity was visible to the org. Our implementation generalizes this to a per-workspace choice made at creation time.

The key tension: MCI's brand is privacy-first, but enterprise buyers often need team visibility to justify the purchase. The hybrid model lets the workspace creator choose, and ensures employees are always informed.

## Decision

### 1. Two monitoring modes, chosen at workspace creation

When creating a workspace (ADR-0019 §2.1), the admin selects one of two modes:

#### 1.1 `transparent` mode

- All approved briefs from all workspace members are queryable by all workspace members.
- Brief content is E2E encrypted with the per-workspace key (ADR-0019 §1.2). The server still cannot read it. But all key-holders (enrolled workspace members) can.
- Use case: teams that want shared context, meeting notes, project visibility. The Meta-MCI pattern.

#### 1.2 `private` mode

- Approved briefs sync for the uploading user's own cross-device access only.
- Other workspace members cannot query or view another member's briefs.
- The workspace key still wraps content (for future policy changes and for consistent crypto architecture), but the server enforces per-user access control on read requests.
- Use case: organizations that want managed key distribution and IT policy without cross-member surveillance.

### 2. Immutable after creation

The monitoring mode is set at workspace creation and CANNOT be changed afterward:

```
POST /workspaces
{
  "name": "encrypted-workspace-name",
  "monitoring_mode": "transparent" | "private",
  "admin_device_pubkey": "..."
}
```

Immutability prevents bait-and-switch:
- An admin cannot create a `private` workspace to attract privacy-conscious employees, then flip to `transparent` after enrollment.
- An admin cannot create a `transparent` workspace and downgrade to `private`, which would be confusing (members who already saw others' briefs can't un-see them).

If an organization wants to change modes, they create a new workspace and re-enroll members. This is intentionally high-friction — mode changes are trust-model changes and should be deliberate.

### 3. Employee notification on workspace join

When a user accepts a workspace enrollment invitation (ADR-0019 §2.2), a clear, non-dismissible modal appears:

**For `transparent` workspaces:**
```
┌─────────────────────────────────────────────────────┐
│  Workspace: Acme Engineering                        │
│  Monitoring mode: Transparent                       │
│                                                     │
│  In this workspace:                                 │
│  ✓ Your approved briefs WILL be visible to all      │
│    workspace members.                               │
│  ✓ You can see other members' approved briefs.      │
│  ✗ Raw screen captures and unapproved events        │
│    NEVER leave your device.                         │
│                                                     │
│  You choose what to approve (brief by brief).       │
│  Nothing is shared without your explicit action.    │
│                                                     │
│  [Join Workspace]         [Decline]                 │
└─────────────────────────────────────────────────────┘
```

**For `private` workspaces:**
```
┌─────────────────────────────────────────────────────┐
│  Workspace: Acme Engineering                        │
│  Monitoring mode: Private                           │
│                                                     │
│  In this workspace:                                 │
│  ✓ Your approved briefs sync across YOUR devices    │
│    only.                                            │
│  ✗ Other members CANNOT see your briefs.            │
│  ✗ Raw screen captures and unapproved events        │
│    NEVER leave your device.                         │
│                                                     │
│  [Join Workspace]         [Decline]                 │
└─────────────────────────────────────────────────────┘
```

The modal is non-dismissible — the user must explicitly click "Join Workspace" or "Decline." There is no "Don't show this again" checkbox.

### 4. Informed, not opt-out

In `transparent` mode, employees are INFORMED that monitoring exists as a condition of workspace membership. They cannot opt out of brief visibility within the workspace — if they approve a brief, all members can see it. The control point is the Approve action itself (ADR-0018 §4.1): the user chooses what to approve, brief by brief.

This mirrors the Meta-MCI pattern: at Meta, employees were informed that the internal tool captured their screen activity for org-wide visibility. Individual capture was still local; sharing was the norm.

### 5. Personal tier: always private

Users without a workspace (personal tier) have zero monitoring by construction:
- No workspace key exists.
- No server is involved.
- No data leaves the device (except optional CloudKit personal sync to the user's own devices per ADR-0023).
- There is no mechanism for anyone else to see personal-tier data.

### 6. Server-side enforcement

The workspace server enforces monitoring mode on every brief read request:

```rust
fn authorize_brief_read(
    reader: &Member,
    brief: &Brief,
    workspace: &Workspace,
) -> Result<(), AuthError> {
    match workspace.monitoring_mode {
        MonitoringMode::Transparent => {
            // Any enrolled member can read any brief in the workspace
            require_enrolled(reader, workspace)?;
        }
        MonitoringMode::Private => {
            // Only the uploader can read their own briefs
            require_enrolled(reader, workspace)?;
            require_uploader(reader, brief)?;
        }
    }
    Ok(())
}
```

This is enforced server-side (the server gates ciphertext delivery) AND client-side (the client filters displayed briefs by ownership in `private` mode). Defense in depth.

### 7. Audit trail

- Workspace creation logs the chosen monitoring mode in the audit log (ADR-0019 §1.3).
- Every brief read logs `(reader_member_id, brief_id, ts)` in the audit log.
- If we ever allow mode changes (currently: we do not), the change would be logged immutably and require CSO review of the immutability constraint relaxation.

### 8. Meta-MCI reference

Meta's internal tool operated in what this ADR calls `transparent` mode:
- Employees were informed that screen activity was captured and visible org-wide.
- Individual capture was local (on the employee's workstation).
- Aggregated activity was visible to the org (managers could see what teams worked on).

Our model generalizes this: Meta's tool was `transparent`-only. We offer `transparent` OR `private`, per-workspace, chosen by the workspace admin. This positions MCI for both Meta-style orgs (who want visibility) and privacy-first orgs (who want managed sync without surveillance).

## Consequences

- **Positive:** Enterprise buyers who need team visibility get it (`transparent` mode) without MCI's brand being "surveillance software" — the workspace creator makes the choice, not Hippocampus the company.
- **Positive:** Privacy-conscious enterprise buyers get `private` mode — sync + managed keys without cross-member visibility. This is a differentiator vs. competitors who default to org-wide monitoring.
- **Positive:** Immutability prevents bait-and-switch. Employees can trust the mode they saw at enrollment time.
- **Positive:** The Approve gate (ADR-0018) means even in `transparent` mode, the user controls what is shared. Raw captures never leave the device.
- **Negative / tradeoff:** Immutability means organizations that want to change modes must create a new workspace and re-enroll. This is intentional friction but may frustrate IT admins.
- **Negative / tradeoff:** `transparent` mode may deter privacy-sensitive employees from joining, even though the Approve gate gives them control. The perception of monitoring may be stronger than the reality.
- **Negative / tradeoff:** `private` mode workspaces pay for infrastructure (workspace server, key management) but get less value than `transparent` workspaces (no shared context). Pricing should reflect this — COO decision.
- **Negative / tradeoff:** Two modes double the test surface for workspace features. Every workspace feature must be tested in both modes.

## Alternatives considered

1. **Transparent-only (Meta-MCI pattern exactly).** Rejected: too narrow. Privacy-conscious enterprises would not adopt. The hybrid model serves both markets.
2. **Private-only (no cross-member visibility).** Rejected: eliminates the enterprise value proposition. "What is my team working on" is the #1 enterprise use case.
3. **Per-member opt-in within transparent workspaces.** Rejected: creates inconsistent visibility (some members visible, some not). The workspace-level choice is cleaner. The Approve gate (per-brief control) provides sufficient individual agency.
4. **Mutable mode with member notification.** Rejected: even with notification, a mode change after enrollment breaks the trust contract the employee agreed to. Immutability is the correct default. Revisit only if enterprise demand is overwhelming and with CSO-gated process.

## CSO sign-off (placeholder — owed at first protected-set PR)

Trust model change for workspace members. `transparent` mode enables cross-member brief visibility (within the E2E encryption boundary — server still cannot read). `private` mode maintains per-user isolation. Immutability prevents bait-and-switch. Employee notification is non-dismissible. Each PR carries the sign-off block.

— CSO, pending

## References

- **ADR-0018** §4.1 — brief authoring Approve gate (user controls what is shared, brief by brief).
- **ADR-0019** — workspace server (enrollment, per-workspace key, audit log — this ADR extends workspace creation with `monitoring_mode`).
- **ADR-0023** — multi-device sync (§2.2 enterprise sync cross-member visibility depends on this ADR).
- Meta-MCI internal tool reference (see `memory/meta-mci-reference-permission-model.md`).
- `docs/STATE.md` — "Org monitoring: HYBRID at workspace creation by CEO (Meta-MCI pattern)."
