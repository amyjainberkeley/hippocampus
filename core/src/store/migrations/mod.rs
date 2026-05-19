//! Schema migrations for the encrypted MCI store.
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5. Each migration bumps
//! `meta.schema_version` by exactly one. Migrations are append-only:
//! never edit a landed migration; add a new one. The Phase-1 store-init
//! code applies any migration whose `to_version` is greater than the
//! database's recorded `meta.schema_version`, inside one transaction
//! per migration, in `MIGRATIONS` order.
//!
//! Phase-0 ships [`crate::store::SCHEMA_VERSION`] = 1 (no migrations
//! needed for a fresh DB). Phase-1 introduces V0002 to carry the
//! ADR-0013 §4 `events.redaction_reason` column.
//!
//! **CSO sign-off (binding):** adding a migration that ALTERs a
//! protected-set table (events, episodes, `event_text`, `event_vectors`,
//! chunks, blobs, `sync_log`, denylist, redactions, deletions, meta)
//! requires a fresh CSO review. The migrations below are the audit
//! record of every schema change ever applied to a live MCI store.

pub mod v0002_events_redaction_reason;

pub use v0002_events_redaction_reason::V0002;

/// A single forward-only schema migration.
///
/// `from_version` → `to_version` MUST always be `n` → `n + 1`. Multi-step
/// jumps are forbidden because a half-applied multi-statement migration
/// is unrecoverable; one transaction per `+1` keeps the recovery path
/// simple.
#[derive(Debug, Clone, Copy)]
pub struct Migration {
    /// `meta.schema_version` value the DB must currently have for this
    /// migration to apply.
    pub from_version: u32,
    /// `meta.schema_version` value the DB will have after this migration
    /// commits. Always `from_version + 1`.
    pub to_version: u32,
    /// Short slug identifying the migration. Used for log lines + audit
    /// trails; never parsed.
    pub name: &'static str,
    /// SQL statements to execute, in order, inside one transaction. The
    /// migration applicator also writes
    /// `INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '<to_version>')`
    /// at the end of the same transaction — that side-effect is implicit
    /// and is NOT included in `statements` (so it stays consistent across
    /// all migrations).
    pub statements: &'static [&'static str],
}

/// The append-only migration ledger.
///
/// Order matters: applied top-down. The applicator picks up at the
/// first migration whose `from_version == meta.schema_version` and
/// runs forward.
pub const MIGRATIONS: &[Migration] = &[V0002];

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::SCHEMA_VERSION;

    /// Every migration is exactly +1. Multi-step jumps are forbidden.
    #[test]
    fn migrations_are_single_step() {
        for m in MIGRATIONS {
            assert_eq!(
                m.to_version,
                m.from_version + 1,
                "migration {} jumps from v{} to v{}",
                m.name,
                m.from_version,
                m.to_version
            );
        }
    }

    /// Migrations form an unbroken chain starting at the Phase-0
    /// baseline (v1) and ending at the current [`SCHEMA_VERSION`].
    /// A gap between the Phase-0 schema and the first migration would
    /// silently leave a DB unupgradable.
    #[test]
    fn migration_chain_is_contiguous_from_phase0() {
        const PHASE_0_BASELINE: u32 = 1;
        let mut expected_from = PHASE_0_BASELINE;
        for m in MIGRATIONS {
            assert_eq!(
                m.from_version, expected_from,
                "migration {} expected from_version {}, got {}",
                m.name, expected_from, m.from_version
            );
            expected_from = m.to_version;
        }
        // After walking all migrations, expected_from is the cumulative
        // to-version we'd land at if a fresh-from-Phase-0 DB ran them
        // all. That MUST equal SCHEMA_VERSION (which a fresh `all_ddl`
        // DB initializes directly to, skipping migrations).
        assert_eq!(
            expected_from, SCHEMA_VERSION,
            "migration chain ends at v{expected_from}, SCHEMA_VERSION = {SCHEMA_VERSION}"
        );
    }

    /// Migration names are non-empty and unique.
    #[test]
    fn migration_names_are_unique_and_non_empty() {
        let mut seen: Vec<&str> = Vec::new();
        for m in MIGRATIONS {
            assert!(!m.name.is_empty(), "empty migration name");
            assert!(
                !seen.contains(&m.name),
                "duplicate migration name {}",
                m.name
            );
            seen.push(m.name);
        }
    }

    /// Every migration carries at least one DDL statement (else why
    /// bother bumping the version).
    #[test]
    fn migrations_have_at_least_one_statement() {
        for m in MIGRATIONS {
            assert!(
                !m.statements.is_empty(),
                "migration {} has no statements",
                m.name
            );
            for s in m.statements {
                assert!(
                    !s.trim().is_empty(),
                    "migration {} has an empty statement",
                    m.name
                );
            }
        }
    }

    /// The current target schema version is `SCHEMA_VERSION` for a
    /// fresh DB, or the last migration's `to_version` for a DB that's
    /// upgraded through every migration. These MUST agree — the
    /// schema constant in `super::SCHEMA_VERSION` is the canonical
    /// target the store-init code asserts after running the
    /// migrations.
    #[test]
    fn last_migration_targets_current_schema_version() {
        if let Some(last) = MIGRATIONS.last() {
            assert_eq!(
                last.to_version, SCHEMA_VERSION,
                "MIGRATIONS chain ends at v{} but SCHEMA_VERSION = {}",
                last.to_version, SCHEMA_VERSION
            );
        } else {
            assert_eq!(
                SCHEMA_VERSION, 1,
                "no migrations should mean SCHEMA_VERSION == 1 (Phase-0 baseline)"
            );
        }
    }
}
