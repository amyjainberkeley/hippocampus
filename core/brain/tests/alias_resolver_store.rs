//! V2-P6 — integration tests for the `AliasResolver` store path
//! (`list_resolvable_entities` / `entity_cooccurrences` /
//! `put_entity_identity` / `identity_members` / `identity_of_entity` /
//! `resolution_watermark`) against the production `SqlCipherBrainStore`,
//! plus the migration-0005 schema check and the end-to-end resolve →
//! persist → read-back round trip.
//!
//! Each test opens an ephemeral encrypted DB under `tempfile::tempdir()`
//! with an `InMemoryKeyWrap`-derived `DbKey` (test-only key wrap), mirroring
//! `tests/graph_store.rs`.
//!
//! # CSO sign-off notes (driver-authored mini-audit; schema escalation
//!   carried in the PR body)
//!
//! (a) The new table `entity_identities` (migration 0005) holds only
//!     attribution over ALREADY-extracted, post-cascade entities. No
//!     capture-scope change, no new IPC, no network surface — the
//!     zero-knowledge invariant is preserved by construction.
//! (b) `redaction_allowlist_excludes_redacted_token` proves a
//!     `redacted_token` entity never reaches the resolver inputs.
//! (c) Hermetic — every brain lives in a `tempfile::TempDir`.

use std::path::{Path, PathBuf};

use mci_brain::alias_resolver::AliasResolver;
use mci_brain::graph::{Entity, EntityIdentity, EntityMention};
use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};
use mci_core::crypto::{DbKey, InMemoryKeyWrap, KeyWrap};
use mci_core::store::{open as mci_core_open, Db};
use rusqlite::params;
use tempfile::TempDir;

fn tmp(name: &str) -> (TempDir, PathBuf) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join(name);
    (dir, path)
}

fn test_key() -> DbKey {
    let k = DbKey::generate().expect("csprng");
    let wrap = InMemoryKeyWrap;
    let wrapped = wrap.wrap(&k).expect("wrap");
    wrap.unwrap_key(&wrapped).expect("unwrap")
}

fn raw_open(path: &Path, key: &DbKey) -> Db {
    mci_core_open(path, key).expect("mci_core::store::open")
}

fn blank_event(ts_us: u64, text: &str) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: None,
        window_title: None,
        url: None,
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    }
}

fn make_entity(kind: &str, name: &str) -> Entity {
    Entity {
        id: Entity::derive_id(kind, name),
        kind: kind.to_string(),
        canonical_name: name.to_string(),
        summary: None,
        summary_embedding: None,
        content_hash: Entity::derive_content_hash(kind, name),
        created_ts_us: 1,
        updated_ts_us: 1,
    }
}

fn make_mention(entity: &Entity, event_id: EventId, extractor: &str) -> EntityMention {
    EntityMention {
        id: EntityMention::derive_id(&entity.id, event_id, extractor, None),
        entity_id: entity.id.clone(),
        event_id,
        mention_text: None,
        confidence: 1.0,
        extractor_kind: extractor.to_string(),
        ts_us: 1,
    }
}

/// Resolve the store's current entities + co-occurrence and reconcile the
/// `entity_identities` table to exactly that output (the exact logic the
/// idle worker runs). Returns the number of membership rows in the current
/// output.
fn resolve_and_persist(store: &SqlCipherBrainStore) -> usize {
    let entities = store.list_resolvable_entities().expect("entities");
    let cooccurrences = store.entity_cooccurrences().expect("cooccurrences");
    let resolved = AliasResolver::default().resolve(&entities, &cooccurrences);
    let rows: Vec<EntityIdentity> = resolved
        .iter()
        .flat_map(|identity| {
            identity.members.iter().map(move |member| EntityIdentity {
                id: EntityIdentity::derive_id(&identity.identity_id, &member.entity_id),
                entity_id: member.entity_id.clone(),
                identity_id: identity.identity_id.clone(),
                identity_kind: identity.identity_kind.clone(),
                identity_canonical_name: identity.canonical_name.clone(),
                rule: member.rule.clone(),
                confidence: member.confidence,
                ts_us: 42,
            })
        })
        .collect();
    store
        .reconcile_entity_identities(&rows)
        .expect("reconcile_entity_identities");
    rows.len()
}

fn entity_identities_count(path: &Path, key: &DbKey) -> i64 {
    let db = raw_open(path, key);
    db.conn()
        .query_row("SELECT COUNT(*) FROM entity_identities", [], |r| r.get(0))
        .expect("count entity_identities")
}

// ---------------------------------------------------------------------------
// 1. Migration 0005 creates the table + indexes and bumps the version
// ---------------------------------------------------------------------------

#[test]
fn migration_0005_creates_entity_identities() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    {
        let _store = SqlCipherBrainStore::new(&path, &key).expect("open");
    }
    let db = raw_open(&path, &key);
    let table_count: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='entity_identities'",
            [],
            |r| r.get(0),
        )
        .expect("query sqlite_master");
    assert_eq!(table_count, 1, "entity_identities table missing");
    for index in [
        "entity_identities_entity",
        "entity_identities_identity",
        "entity_identities_kind",
        "entity_identities_ts",
    ] {
        let count: i64 = db
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name=?1",
                params![index],
                |r| r.get(0),
            )
            .expect("query index");
        assert_eq!(count, 1, "{index} index missing");
    }
    let version: String = db
        .conn()
        .query_row(
            "SELECT value FROM meta WHERE key='brain_schema_version'",
            [],
            |r| r.get(0),
        )
        .expect("schema version");
    assert_eq!(version, "5");
}

// ---------------------------------------------------------------------------
// 2. End-to-end round trip: name + email + phone → one identity
// ---------------------------------------------------------------------------

#[test]
fn resolves_name_email_phone_into_one_identity() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    // Three events across three apps.
    let e1 = store.put_event(&blank_event(1_000, "slack")).unwrap();
    let e2 = store.put_event(&blank_event(2_000, "mail")).unwrap();
    let e3 = store.put_event(&blank_event(3_000, "messages")).unwrap();

    let name = make_entity("person_name", "Alice Smith");
    let mail = make_entity("email", "alice.smith@corp.com");
    let phone = make_entity("phone", "+1 555 123 4567");
    for ent in [&name, &mail, &phone] {
        store.put_entity(ent).unwrap();
    }
    // name in e1 (Slack); email in e2 (Mail); phone + name co-occur in e3.
    store
        .put_entity_mention(&make_mention(&name, e1, "ner"))
        .unwrap();
    store
        .put_entity_mention(&make_mention(&mail, e2, "regex"))
        .unwrap();
    store
        .put_entity_mention(&make_mention(&phone, e3, "regex"))
        .unwrap();
    store
        .put_entity_mention(&make_mention(&name, e3, "ner"))
        .unwrap();

    resolve_and_persist(&store);

    // The mail entity resolves to a person identity...
    let mail_membership = store.identity_of_entity(&mail.id).unwrap();
    assert_eq!(mail_membership.len(), 1, "email in exactly one identity");
    let identity_id = mail_membership[0].identity_id.clone();
    assert_eq!(mail_membership[0].identity_kind, "person");
    assert_eq!(mail_membership[0].identity_canonical_name, "Alice Smith");

    // ...and that identity walks to all three alias entities.
    let members = store.identity_members(&identity_id).unwrap();
    let member_ids: std::collections::BTreeSet<&str> =
        members.iter().map(|m| m.entity_id.0.as_str()).collect();
    assert!(member_ids.contains(name.id.0.as_str()), "name present");
    assert!(member_ids.contains(mail.id.0.as_str()), "email present");
    assert!(member_ids.contains(phone.id.0.as_str()), "phone present");
    assert_eq!(members.len(), 3);
}

// ---------------------------------------------------------------------------
// 3. Idempotence: re-resolving an unchanged store is a row-level no-op
// ---------------------------------------------------------------------------

#[test]
fn resolve_is_idempotent_row_level() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let e1 = store.put_event(&blank_event(1_000, "a")).unwrap();
    let name = make_entity("person_name", "Bob Jones");
    let mail = make_entity("email", "bob.jones@corp.com");
    store.put_entity(&name).unwrap();
    store.put_entity(&mail).unwrap();
    store
        .put_entity_mention(&make_mention(&name, e1, "ner"))
        .unwrap();
    store
        .put_entity_mention(&make_mention(&mail, e1, "regex"))
        .unwrap();

    let first = resolve_and_persist(&store);
    let count_after_first = entity_identities_count(&path, &key);
    // Snapshot the rows verbatim.
    let snapshot = |path: &Path, key: &DbKey| -> Vec<(String, String, String, String)> {
        let db = raw_open(path, key);
        let mut stmt = db
            .conn()
            .prepare("SELECT id, entity_id, identity_id, rule FROM entity_identities ORDER BY id")
            .unwrap();
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                ))
            })
            .unwrap();
        rows.map(Result::unwrap).collect()
    };
    let snap1 = snapshot(&path, &key);

    // Re-run on the unchanged store.
    let second = resolve_and_persist(&store);
    let count_after_second = entity_identities_count(&path, &key);
    let snap2 = snapshot(&path, &key);

    assert_eq!(first, second, "same number of put calls");
    assert_eq!(
        count_after_first, count_after_second,
        "re-resolve must not add rows (grow-only no-op)"
    );
    assert_eq!(snap1, snap2, "rows byte-identical across re-resolve");
    assert_eq!(count_after_first, 2, "Bob Jones identity has 2 members");
}

// ---------------------------------------------------------------------------
// 4. Redaction discipline: redacted_token never reaches the resolver
// ---------------------------------------------------------------------------

#[test]
fn redaction_allowlist_excludes_redacted_token() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let e1 = store.put_event(&blank_event(1_000, "x")).unwrap();
    // A redacted_token entity: canonical_name is the subkind label, NOT
    // the source bytes (Tier-1 redaction discipline).
    let redacted = make_entity("redacted_token", "jwt");
    let name = make_entity("person_name", "Carol White");
    store.put_entity(&redacted).unwrap();
    store.put_entity(&name).unwrap();
    store
        .put_entity_mention(&make_mention(&redacted, e1, "regex"))
        .unwrap();
    store
        .put_entity_mention(&make_mention(&name, e1, "ner"))
        .unwrap();

    let resolvable = store.list_resolvable_entities().unwrap();
    assert!(
        resolvable.iter().all(|e| e.kind != "redacted_token"),
        "redacted_token must be filtered from resolver inputs"
    );

    // And the co-occurrence read must not surface it either.
    let co = store.entity_cooccurrences().unwrap();
    let any_redacted = co
        .iter()
        .flat_map(|(_, ids)| ids.iter())
        .any(|id| *id == redacted.id);
    assert!(!any_redacted, "redacted_token absent from co-occurrence");

    resolve_and_persist(&store);
    assert!(
        store.identity_of_entity(&redacted.id).unwrap().is_empty(),
        "redacted_token never enters an identity"
    );
}

// ---------------------------------------------------------------------------
// 5. False-merge guard at the store level: distinct people stay separate
// ---------------------------------------------------------------------------

#[test]
fn distinct_people_never_share_identity() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let e1 = store.put_event(&blank_event(1_000, "a")).unwrap();
    let e2 = store.put_event(&blank_event(2_000, "b")).unwrap();

    let smith = make_entity("person_name", "Alice Smith");
    let smith_mail = make_entity("email", "alice.smith@corp.com");
    let chen = make_entity("person_name", "Alice Chen");
    let chen_mail = make_entity("email", "alice.chen@corp.com");
    let bare = make_entity("person_name", "Alice");
    for ent in [&smith, &smith_mail, &chen, &chen_mail, &bare] {
        store.put_entity(ent).unwrap();
    }
    store
        .put_entity_mention(&make_mention(&smith, e1, "ner"))
        .unwrap();
    store
        .put_entity_mention(&make_mention(&smith_mail, e1, "regex"))
        .unwrap();
    store
        .put_entity_mention(&make_mention(&chen, e2, "ner"))
        .unwrap();
    store
        .put_entity_mention(&make_mention(&chen_mail, e2, "regex"))
        .unwrap();
    store
        .put_entity_mention(&make_mention(&bare, e1, "ner"))
        .unwrap();

    resolve_and_persist(&store);

    let smith_id = store.identity_of_entity(&smith.id).unwrap();
    let chen_id = store.identity_of_entity(&chen.id).unwrap();
    assert_eq!(smith_id.len(), 1);
    assert_eq!(chen_id.len(), 1);
    assert_ne!(
        smith_id[0].identity_id, chen_id[0].identity_id,
        "two distinct people must never collapse into one identity"
    );
    // The Smith identity must not contain any Chen entity and vice-versa.
    let smith_members = store.identity_members(&smith_id[0].identity_id).unwrap();
    assert!(smith_members.iter().all(|m| m.entity_id != chen.id));
    assert!(smith_members.iter().all(|m| m.entity_id != chen_mail.id));
    // Bare "Alice" matches two cores → dropped → its own implicit identity.
    assert!(
        store.identity_of_entity(&bare.id).unwrap().is_empty(),
        "ambiguous bare first name must not merge"
    );
}

// ---------------------------------------------------------------------------
// 6. Watermark moves when entities/mentions change
// ---------------------------------------------------------------------------

#[test]
fn watermark_tracks_population_changes() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let empty = store.resolution_watermark().unwrap();
    assert_eq!(empty.entity_count, 0);

    let e1 = store.put_event(&blank_event(1_000, "a")).unwrap();
    let name = make_entity("person_name", "Dave Lee");
    store.put_entity(&name).unwrap();
    let after_entity = store.resolution_watermark().unwrap();
    assert_ne!(empty, after_entity, "adding an entity moves the watermark");

    store
        .put_entity_mention(&make_mention(&name, e1, "ner"))
        .unwrap();
    let after_mention = store.resolution_watermark().unwrap();
    assert_ne!(
        after_entity, after_mention,
        "adding a mention moves the watermark"
    );

    // Writing identities does NOT move the resolver watermark (so the
    // worker won't loop on its own output).
    resolve_and_persist(&store);
    let after_identities = store.resolution_watermark().unwrap();
    assert_eq!(
        after_mention, after_identities,
        "writing entity_identities must not change the watermark"
    );
}

// ---------------------------------------------------------------------------
// 7. Non-monotonic-leaf pruning: a stale membership from an earlier pass is
//    repaired once a colliding core appears (adversarial-workflow finding:
//    content-stability-drift). This is the production reconcile path.
// ---------------------------------------------------------------------------

#[test]
fn stale_leaf_pruned_when_core_becomes_ambiguous() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let e1 = store.put_event(&blank_event(1_000, "a")).unwrap();

    // PASS 1: only "Alice Smith" exists, so bare "Alice" attaches
    // unambiguously → an identity {Alice Smith, Alice}.
    let smith = make_entity("person_name", "Alice Smith");
    let bare = make_entity("person_name", "Alice");
    store.put_entity(&smith).unwrap();
    store.put_entity(&bare).unwrap();
    store
        .put_entity_mention(&make_mention(&smith, e1, "ner"))
        .unwrap();
    store
        .put_entity_mention(&make_mention(&bare, e1, "ner"))
        .unwrap();
    resolve_and_persist(&store);
    assert!(
        !store.identity_of_entity(&bare.id).unwrap().is_empty(),
        "pass 1: bare Alice attaches to the sole Alice * core"
    );

    // PASS 2: a SECOND "Alice Chen" core appears. Bare "Alice" is now
    // ambiguous (matches two cores) and the resolver drops it. The stale
    // pass-1 membership MUST be pruned by reconcile — a grow-only
    // INSERT-OR-IGNORE would strand it as a persisted false-merge.
    let e2 = store.put_event(&blank_event(2_000, "b")).unwrap();
    let chen = make_entity("person_name", "Alice Chen");
    store.put_entity(&chen).unwrap();
    store
        .put_entity_mention(&make_mention(&chen, e2, "ner"))
        .unwrap();
    resolve_and_persist(&store);

    assert!(
        store.identity_of_entity(&bare.id).unwrap().is_empty(),
        "pass 2: stale bare-Alice membership must be pruned"
    );
    // And no surviving identity wrongly contains bare Alice.
    assert_eq!(
        entity_identities_count(&path, &key),
        0,
        "both cores are now singletons → no memberships remain"
    );
}
