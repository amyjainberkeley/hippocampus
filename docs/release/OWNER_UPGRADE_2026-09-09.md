# September 9 Owner Upgrade

This procedure covers the private `fb73f77` candidate, not public distribution.
The installer, digest and Apple receipts are in [STATUS](../STATUS.md).
The currently installed app is `fe90a3d`. No private backup or migration has
been performed at this checkpoint.

## Why The Update Needs Care

Schema 10 adds measured activity and deletion barriers in a transaction. The
existing evidence and encryption key remain in place. An older writer or Recall
build does not know how to delete this new data, and its migration can restamp
the schema as version 9. Do not run the old build against an upgraded database.

## Controlled Installation

1. In the Hippocampus menu-bar menu, choose **Quit Hippocampus**, not Restart,
   Pause or merely closing its window. Verify the parent, helper and owned
   writer exit. Separately verify Recall exits: its shutdown request is not
   awaited by the parent. A failed quit is a stop condition, not permission to
   erase a lock file or reset capture consent.
2. Keep clients idle during the short maintenance window. Confirm no import,
   enrichment, backfill, brief or other one-shot writer remains. Existing MCP
   readers must not be mistaken for the owned capture writer. Do not kill all
   `mci-agent` processes by name.
3. Only while the store is quiescent, make a private ciphertext recovery copy
   of `mci.sqlite`, any `mci.sqlite-wal` and `mci.sqlite-shm`, and the matching
   `blobs` directory as one set. Use a nonsynced location outside the repository,
   a mode-0700 enclosing directory, enough free space, and verify completeness
   locally. Do not expose contents or keys. A live sequential file copy is not
   a consistent backup; a text export is not an encrypted recovery backup.
4. Preserve the old application for provenance, then replace the entire
   `/Applications/Hippocampus.app` with the verified candidate. Check its nested
   signature and provenance again after copying. Leave Keychain, permissions,
   capture policy and existing memory intact.
5. Launch the exact installed path. Let the owner respond to any ordinary
   macOS prompt after reviewing it. Verify the new parent, helper, writer and
   Recall mappings; confirm visible startup/capture state. Do not infer working
   capture merely because the processes exist or event counts rise.
6. Perform the [screen-only proof](../../scripts/live-capture/screen-proof-window.md)
   and the [remaining observable gates](../audits/2026-09-07-observable-gates.md).
   Measured activity begins with this helper; do not invent historical hours.

## Recovery

If the candidate fails, stop it and preserve the schema-10 store for forward
repair. Do not automatically relaunch `fe90a3d`, remove writer/crash markers,
or restore the older backup. Restoring a snapshot can resurrect information
deleted afterward. Any restore requires a deliberate owner decision that
accounts for post-backup deletions and data loss.

The source supports the additive migration and deletion paths; this document
does not claim that the owner's live upgrade or second-Mac recovery has passed.

Source references: `core/brain/migrations/0010_measured_activity.sql`,
`core/brain/src/sqlcipher_brain_store.rs`,
`apps/hippocampus/Sources/HippocampusKit/ApplicationTerminationCoordinator.swift`,
`SupervisorProcessShutdown.swift`, and `ProcessSupervisor.swift`.
