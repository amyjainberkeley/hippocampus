//! Deterministic, transactional projection of immutable memory deltas.

use rusqlite::{params, OptionalExtension, Transaction};

use crate::episode_segmenter::EpisodeId;
use crate::memory_delta::{
    ClaimStatus, ClaimStatusRecord, ClaimTransition, EvidenceId, EvidenceRef, ExpandedEvidence,
    ExpansionBudget, MemoryClaim, MemoryClaimId, MemoryDelta, MemoryExpansion, MemoryRetraction,
};
use crate::{EntityId, EventId, IdentityId, SqlCipherBrainStore, StoreError};
use std::collections::BTreeSet;

/// Apply one fully materialized delta in a single transaction.
///
/// This function performs only deterministic validation and SQL. It does not
/// call a model, embedder, network, filesystem, or clock.
pub fn project_event(store: &SqlCipherBrainStore, delta: &MemoryDelta) -> Result<(), StoreError> {
    store.project_memory_delta(delta)
}

/// Append retraction transitions for claims evidenced by one event.
pub fn retract_event(
    store: &SqlCipherBrainStore,
    retraction: &MemoryRetraction,
) -> Result<(), StoreError> {
    store.retract_memory_event(retraction)
}

pub(crate) fn apply_delta(tx: &Transaction<'_>, delta: &MemoryDelta) -> Result<(), StoreError> {
    require_event(tx, delta.source_event_id)?;
    validate_nonempty("projector_version", &delta.projector_version)?;

    tx.execute(
        "INSERT OR IGNORE INTO memory_deltas
         (id, source_event_id, asserted_at_us, projector_version)
         VALUES (?1, ?2, ?3, ?4)",
        params![
            delta.id,
            to_i64(delta.source_event_id.0, "source_event_id")?,
            to_i64(delta.asserted_at_us, "asserted_at_us")?,
            delta.projector_version,
        ],
    )
    .map_err(db_error("insert memory delta"))?;

    for claim in &delta.claims {
        validate_claim(tx, delta, claim)?;
        for evidence in &claim.evidence {
            insert_evidence(tx, evidence)?;
        }
        insert_claim(tx, delta.source_event_id, claim)?;
        for evidence in &claim.evidence {
            tx.execute(
                "INSERT OR IGNORE INTO memory_claim_evidence (claim_id, evidence_id)
                 VALUES (?1, ?2)",
                params![claim.id.0, evidence.id.0],
            )
            .map_err(db_error("link claim evidence"))?;
        }
        if let Some(previous) = &claim.supersedes_claim_id {
            let transition = ClaimTransition::new(
                previous.clone(),
                ClaimStatus::Superseded,
                delta.asserted_at_us,
                claim.valid_from_us,
                &format!("superseded by {}", claim.id.0),
                delta.source_event_id,
                &delta.projector_version,
            );
            insert_transition(tx, &transition)?;
        }
    }
    for transition in &delta.transitions {
        validate_transition(tx, delta, transition)?;
        insert_transition(tx, transition)?;
    }
    Ok(())
}

pub(crate) fn apply_retraction(
    tx: &Transaction<'_>,
    retraction: &MemoryRetraction,
) -> Result<(), StoreError> {
    require_event(tx, retraction.target_event_id)?;
    require_event(tx, retraction.retraction_event_id)?;
    validate_nonempty("retraction reason", &retraction.reason)?;
    validate_nonempty("projector_version", &retraction.projector_version)?;

    let mut stmt = tx
        .prepare(
            "SELECT DISTINCT ce.claim_id
             FROM memory_claim_evidence ce
             JOIN memory_evidence e ON e.id = ce.evidence_id
             WHERE e.event_id = ?1
             ORDER BY ce.claim_id ASC",
        )
        .map_err(db_error("prepare event retraction"))?;
    let rows = stmt
        .query_map(
            params![to_i64(retraction.target_event_id.0, "target_event_id")?],
            |row| row.get::<_, String>(0),
        )
        .map_err(db_error("query event retraction"))?;
    let mut claim_ids = Vec::new();
    for row in rows {
        claim_ids.push(MemoryClaimId(
            row.map_err(db_error("read event retraction claim"))?,
        ));
    }
    drop(stmt);

    for claim_id in claim_ids {
        let transition = ClaimTransition::new(
            claim_id,
            ClaimStatus::Retracted,
            retraction.asserted_at_us,
            retraction.effective_at_us,
            &retraction.reason,
            retraction.retraction_event_id,
            &retraction.projector_version,
        );
        insert_transition(tx, &transition)?;
    }
    Ok(())
}

fn validate_claim(
    tx: &Transaction<'_>,
    delta: &MemoryDelta,
    claim: &MemoryClaim,
) -> Result<(), StoreError> {
    for (name, value) in [
        ("subject", claim.subject.as_str()),
        ("predicate", claim.predicate.as_str()),
        ("object", claim.object.as_str()),
        ("scope", claim.scope.as_str()),
        ("projector_version", claim.projector_version.as_str()),
    ] {
        validate_nonempty(name, value)?;
    }
    if !claim.confidence.is_finite() || !(0.0..=1.0).contains(&claim.confidence) {
        return invalid("claim confidence must be finite and inside [0, 1]");
    }
    if claim
        .valid_to_us
        .is_some_and(|end| end < claim.valid_from_us)
    {
        return invalid("claim valid_to_us precedes valid_from_us");
    }
    if !matches!(claim.status, ClaimStatus::Proposed | ClaimStatus::Active) {
        return invalid("new claims may only start proposed or active");
    }
    if claim.status == ClaimStatus::Active && claim.evidence.is_empty() {
        return invalid("active claims require extant evidence");
    }
    if claim.status == ClaimStatus::Active
        && !claim
            .evidence
            .iter()
            .any(|evidence| evidence.event_id == delta.source_event_id)
    {
        return invalid("active claim evidence must include its delta source_event_id");
    }
    for evidence in &claim.evidence {
        validate_evidence(evidence)?;
        require_event(tx, evidence.event_id)?;
    }

    if let Some(previous_id) = &claim.supersedes_claim_id {
        let previous = read_claim(tx, previous_id)?.ok_or_else(|| {
            StoreError::InvalidInput(format!("unknown superseded claim {}", previous_id.0))
        })?;
        if previous.subject != claim.subject || previous.predicate != claim.predicate {
            return invalid("a correction must preserve subject and predicate");
        }
        if !scope_is_same_or_narrower(&previous.scope, &claim.scope) {
            return invalid("a correction cannot broaden claim scope");
        }
        if previous
            .attribution
            .as_deref()
            .is_some_and(|a| !a.is_empty())
            && claim.attribution.as_deref().is_none_or(str::is_empty)
        {
            return invalid("a correction cannot remove attribution");
        }
        if claim.status != ClaimStatus::Active {
            return invalid("a superseding correction must be source-backed and active");
        }
    }

    if claim.asserted_at_us != delta.asserted_at_us {
        return invalid("claim asserted_at_us must equal its delta timestamp");
    }
    Ok(())
}

fn validate_evidence(evidence: &EvidenceRef) -> Result<(), StoreError> {
    for (name, value) in [
        ("source_kind", evidence.source_kind.as_str()),
        ("source_locator", evidence.source_locator.as_str()),
        ("source_scope", evidence.source_scope.as_str()),
        ("content_hash", evidence.content_hash.as_str()),
    ] {
        validate_nonempty(name, value)?;
    }
    Ok(())
}

fn validate_transition(
    tx: &Transaction<'_>,
    delta: &MemoryDelta,
    value: &ClaimTransition,
) -> Result<(), StoreError> {
    if read_claim(tx, &value.claim_id)?.is_none() {
        return invalid("claim transition references an unknown claim");
    }
    require_event(tx, value.source_event_id)?;
    validate_nonempty("transition reason", &value.reason)?;
    validate_nonempty("projector_version", &value.projector_version)?;
    if matches!(value.status, ClaimStatus::Proposed | ClaimStatus::Active) {
        return invalid("a transition cannot promote a claim to active or reset it to proposed");
    }
    if value.asserted_at_us != delta.asserted_at_us {
        return invalid("transition asserted_at_us must equal its delta timestamp");
    }
    Ok(())
}

fn insert_evidence(tx: &Transaction<'_>, value: &EvidenceRef) -> Result<(), StoreError> {
    tx.execute(
        "INSERT OR IGNORE INTO memory_evidence
         (id, event_id, source_kind, source_locator, source_scope, observed_at_us, content_hash)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            value.id.0,
            to_i64(value.event_id.0, "evidence event_id")?,
            value.source_kind,
            value.source_locator,
            value.source_scope,
            to_i64(value.observed_at_us, "observed_at_us")?,
            value.content_hash,
        ],
    )
    .map_err(db_error("insert memory evidence"))?;
    Ok(())
}

fn insert_claim(
    tx: &Transaction<'_>,
    source_event_id: EventId,
    value: &MemoryClaim,
) -> Result<(), StoreError> {
    tx.execute(
        "INSERT OR IGNORE INTO memory_claims
         (id, source_event_id, subject, predicate, object, scope, attribution,
          confidence, asserted_at_us, valid_from_us, valid_to_us,
          projector_version, initial_status, supersedes_claim_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
        params![
            value.id.0,
            to_i64(source_event_id.0, "claim source_event_id")?,
            value.subject,
            value.predicate,
            value.object,
            value.scope,
            value.attribution,
            f64::from(value.confidence),
            to_i64(value.asserted_at_us, "claim asserted_at_us")?,
            to_i64(value.valid_from_us, "claim valid_from_us")?,
            value
                .valid_to_us
                .map(|v| to_i64(v, "claim valid_to_us"))
                .transpose()?,
            value.projector_version,
            value.status.as_str(),
            value.supersedes_claim_id.as_ref().map(|id| id.0.as_str()),
        ],
    )
    .map_err(db_error("insert memory claim"))?;
    Ok(())
}

fn insert_transition(tx: &Transaction<'_>, value: &ClaimTransition) -> Result<(), StoreError> {
    tx.execute(
        "INSERT OR IGNORE INTO memory_claim_transitions
         (id, claim_id, status, asserted_at_us, effective_at_us, reason,
          source_event_id, projector_version)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            value.id,
            value.claim_id.0,
            value.status.as_str(),
            to_i64(value.asserted_at_us, "transition asserted_at_us")?,
            to_i64(value.effective_at_us, "transition effective_at_us")?,
            value.reason,
            to_i64(value.source_event_id.0, "transition source_event_id")?,
            value.projector_version,
        ],
    )
    .map_err(db_error("insert claim transition"))?;
    Ok(())
}

pub(crate) fn read_claims_as_of(
    tx: &Transaction<'_>,
    valid_at_us: u64,
    asserted_as_of_us: u64,
    limit: usize,
) -> Result<Vec<MemoryClaim>, StoreError> {
    if limit == 0 {
        return Ok(Vec::new());
    }
    let mut stmt = tx
        .prepare(
            "SELECT c.id, c.subject, c.predicate, c.object, c.scope, c.attribution,
                    c.confidence, c.asserted_at_us, c.valid_from_us, c.valid_to_us,
                    c.projector_version, c.initial_status, c.supersedes_claim_id
             FROM memory_claims c
             WHERE c.asserted_at_us <= ?1
               AND c.valid_from_us <= ?2
               AND (c.valid_to_us IS NULL OR c.valid_to_us >= ?2)
               AND COALESCE(
                   (SELECT t.status FROM memory_claim_transitions t
                    WHERE t.claim_id = c.id
                      AND t.asserted_at_us <= ?1
                      AND t.effective_at_us <= ?2
                    ORDER BY t.asserted_at_us DESC, t.effective_at_us DESC, t.id DESC
                    LIMIT 1),
                   c.initial_status) = 'active'
             ORDER BY c.subject ASC, c.predicate ASC, c.object ASC, c.id ASC
             LIMIT ?3",
        )
        .map_err(db_error("prepare current memory claims"))?;
    let rows = stmt
        .query_map(
            params![
                to_i64(asserted_as_of_us, "asserted_as_of_us")?,
                to_i64(valid_at_us, "valid_at_us")?,
                i64::try_from(limit).unwrap_or(i64::MAX)
            ],
            claim_row,
        )
        .map_err(db_error("query current memory claims"))?;
    let mut claims = Vec::new();
    for row in rows {
        claims.push(row.map_err(db_error("read current memory claim"))?);
    }
    drop(stmt);
    for claim in &mut claims {
        claim.evidence = read_evidence(tx, &claim.id)?;
    }
    Ok(claims)
}

pub(crate) fn read_claim_history(
    tx: &Transaction<'_>,
    claim_id: &MemoryClaimId,
) -> Result<Vec<ClaimStatusRecord>, StoreError> {
    let initial: Option<(String, i64, i64, i64)> = tx
        .query_row(
            "SELECT initial_status, asserted_at_us, valid_from_us, source_event_id
             FROM memory_claims WHERE id = ?1",
            params![claim_id.0],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()
        .map_err(db_error("read claim initial status"))?;
    let Some((status, asserted, effective, source)) = initial else {
        return Ok(Vec::new());
    };
    let mut out = vec![ClaimStatusRecord {
        status: parse_status(&status)?,
        asserted_at_us: to_u64(asserted, "claim asserted_at_us")?,
        effective_at_us: to_u64(effective, "claim valid_from_us")?,
        reason: "asserted".into(),
        source_event_id: EventId(to_u64(source, "claim source_event_id")?),
    }];
    let mut stmt = tx
        .prepare(
            "SELECT status, asserted_at_us, effective_at_us, reason, source_event_id
             FROM memory_claim_transitions WHERE claim_id = ?1
             ORDER BY asserted_at_us ASC, effective_at_us ASC, id ASC",
        )
        .map_err(db_error("prepare claim history"))?;
    let rows = stmt
        .query_map(params![claim_id.0], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, i64>(4)?,
            ))
        })
        .map_err(db_error("query claim history"))?;
    for row in rows {
        let (status, asserted, effective, reason, source) =
            row.map_err(db_error("read claim history"))?;
        out.push(ClaimStatusRecord {
            status: parse_status(&status)?,
            asserted_at_us: to_u64(asserted, "transition asserted_at_us")?,
            effective_at_us: to_u64(effective, "transition effective_at_us")?,
            reason,
            source_event_id: EventId(to_u64(source, "transition source_event_id")?),
        });
    }
    Ok(out)
}

pub(crate) fn expand_memory(
    tx: &Transaction<'_>,
    seed_claim_ids: &[MemoryClaimId],
    budget: ExpansionBudget,
) -> Result<MemoryExpansion, StoreError> {
    let mut seeds = seed_claim_ids.to_vec();
    seeds.sort();
    seeds.dedup();

    let mut claim_ids = Vec::new();
    let mut evidence_out = Vec::new();
    let mut episodes = BTreeSet::new();
    let mut entities = BTreeSet::new();
    let mut identities = BTreeSet::new();
    let mut nodes_used = 0usize;
    let mut edges_used = 0usize;
    let mut tokens_used = 0usize;
    let mut truncated = false;

    for claim_id in seeds {
        if read_claim(tx, &claim_id)?.is_none() {
            continue;
        }
        if nodes_used == budget.max_nodes {
            truncated = true;
            continue;
        }
        nodes_used += 1;
        claim_ids.push(claim_id.clone());

        for evidence in read_evidence(tx, &claim_id)? {
            if evidence_out.len() == budget.max_evidence || edges_used == budget.max_edges {
                truncated = true;
                continue;
            }
            let event_row: Option<(String, Option<i64>)> = tx
                .query_row(
                    "SELECT text, episode_id FROM events WHERE id = ?1",
                    params![to_i64(evidence.event_id.0, "evidence event_id")?],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()
                .map_err(db_error("read expansion event"))?;
            let Some((text, episode_id)) = event_row else {
                continue;
            };
            let token_count = text.split_whitespace().count();
            if token_count > budget.max_tokens.saturating_sub(tokens_used) {
                truncated = true;
                continue;
            }
            tokens_used += token_count;
            edges_used += 1;
            evidence_out.push(ExpandedEvidence {
                evidence: evidence.clone(),
                excerpt: crate::EventRecord::truncate_snippet(&text),
                token_count,
            });

            if let Some(raw_episode) = episode_id {
                let episode = EpisodeId(to_u64(raw_episode, "episode_id")?);
                admit_node(
                    episode,
                    &mut episodes,
                    &mut nodes_used,
                    &mut edges_used,
                    budget,
                    &mut truncated,
                );
            }

            let mut stmt = tx
                .prepare(
                    "SELECT em.entity_id, ei.identity_id
                     FROM entity_mentions em
                     LEFT JOIN entity_identities ei ON ei.entity_id = em.entity_id
                     WHERE em.event_id = ?1
                     ORDER BY em.entity_id ASC, ei.identity_id ASC",
                )
                .map_err(db_error("prepare expansion graph"))?;
            let rows = stmt
                .query_map(
                    params![to_i64(evidence.event_id.0, "graph event_id")?],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
                )
                .map_err(db_error("query expansion graph"))?;
            let mut graph_rows = Vec::new();
            for row in rows {
                graph_rows.push(row.map_err(db_error("read expansion graph"))?);
            }
            drop(stmt);
            for (entity, identity) in graph_rows {
                admit_node(
                    EntityId(entity),
                    &mut entities,
                    &mut nodes_used,
                    &mut edges_used,
                    budget,
                    &mut truncated,
                );
                if let Some(identity) = identity {
                    admit_node(
                        IdentityId(identity),
                        &mut identities,
                        &mut nodes_used,
                        &mut edges_used,
                        budget,
                        &mut truncated,
                    );
                }
            }
        }
    }

    Ok(MemoryExpansion {
        claim_ids,
        evidence: evidence_out,
        episode_ids: episodes.into_iter().collect(),
        entity_ids: entities.into_iter().collect(),
        identity_ids: identities.into_iter().collect(),
        nodes_used,
        edges_used,
        tokens_used,
        truncated,
    })
}

fn admit_node<T: Ord>(
    value: T,
    destination: &mut BTreeSet<T>,
    nodes_used: &mut usize,
    edges_used: &mut usize,
    budget: ExpansionBudget,
    truncated: &mut bool,
) {
    if destination.contains(&value) {
        return;
    }
    if *nodes_used == budget.max_nodes || *edges_used == budget.max_edges {
        *truncated = true;
        return;
    }
    destination.insert(value);
    *nodes_used += 1;
    *edges_used += 1;
}

fn read_claim(
    tx: &Transaction<'_>,
    claim_id: &MemoryClaimId,
) -> Result<Option<MemoryClaim>, StoreError> {
    tx.query_row(
        "SELECT id, subject, predicate, object, scope, attribution, confidence,
                asserted_at_us, valid_from_us, valid_to_us, projector_version,
                initial_status, supersedes_claim_id
         FROM memory_claims WHERE id = ?1",
        params![claim_id.0],
        claim_row,
    )
    .optional()
    .map_err(db_error("read memory claim"))
}

fn claim_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<MemoryClaim> {
    let status: String = row.get(11)?;
    let confidence: f64 = row.get(6)?;
    #[allow(clippy::cast_possible_truncation)]
    let confidence = confidence as f32;
    Ok(MemoryClaim {
        id: MemoryClaimId(row.get(0)?),
        subject: row.get(1)?,
        predicate: row.get(2)?,
        object: row.get(3)?,
        scope: row.get(4)?,
        attribution: row.get(5)?,
        confidence,
        asserted_at_us: u64::try_from(row.get::<_, i64>(7)?).unwrap_or(0),
        valid_from_us: u64::try_from(row.get::<_, i64>(8)?).unwrap_or(0),
        valid_to_us: row
            .get::<_, Option<i64>>(9)?
            .and_then(|value| u64::try_from(value).ok()),
        projector_version: row.get(10)?,
        status: ClaimStatus::parse(&status).unwrap_or(ClaimStatus::Proposed),
        supersedes_claim_id: row.get::<_, Option<String>>(12)?.map(MemoryClaimId),
        evidence: Vec::new(),
    })
}

fn read_evidence(
    tx: &Transaction<'_>,
    claim_id: &MemoryClaimId,
) -> Result<Vec<EvidenceRef>, StoreError> {
    let mut stmt = tx
        .prepare(
            "SELECT e.id, e.event_id, e.source_kind, e.source_locator,
                    e.source_scope, e.observed_at_us, e.content_hash
             FROM memory_claim_evidence ce
             JOIN memory_evidence e ON e.id = ce.evidence_id
             WHERE ce.claim_id = ?1 ORDER BY e.id ASC",
        )
        .map_err(db_error("prepare claim evidence"))?;
    let rows = stmt
        .query_map(params![claim_id.0], |row| {
            Ok(EvidenceRef {
                id: EvidenceId(row.get(0)?),
                event_id: EventId(u64::try_from(row.get::<_, i64>(1)?).unwrap_or(0)),
                source_kind: row.get(2)?,
                source_locator: row.get(3)?,
                source_scope: row.get(4)?,
                observed_at_us: u64::try_from(row.get::<_, i64>(5)?).unwrap_or(0),
                content_hash: row.get(6)?,
            })
        })
        .map_err(db_error("query claim evidence"))?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row.map_err(db_error("read claim evidence"))?);
    }
    Ok(out)
}

fn require_event(tx: &Transaction<'_>, event_id: EventId) -> Result<(), StoreError> {
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM events WHERE id = ?1)",
            params![to_i64(event_id.0, "event_id")?],
            |row| row.get(0),
        )
        .map_err(db_error("check evidence event"))?;
    if exists {
        Ok(())
    } else {
        invalid("memory projection references a missing event")
    }
}

fn scope_is_same_or_narrower(previous: &str, replacement: &str) -> bool {
    replacement == previous
        || replacement
            .strip_prefix(previous)
            .is_some_and(|suffix| suffix.starts_with('/'))
}

fn validate_nonempty(name: &str, value: &str) -> Result<(), StoreError> {
    if value.trim().is_empty() {
        invalid(&format!("{name} must not be empty"))
    } else {
        Ok(())
    }
}

fn parse_status(value: &str) -> Result<ClaimStatus, StoreError> {
    ClaimStatus::parse(value)
        .ok_or_else(|| StoreError::Backend(format!("unknown memory claim status {value}")))
}

fn to_i64(value: u64, name: &str) -> Result<i64, StoreError> {
    i64::try_from(value)
        .map_err(|_| StoreError::InvalidInput(format!("{name} exceeds SQLite INTEGER")))
}

fn to_u64(value: i64, name: &str) -> Result<u64, StoreError> {
    u64::try_from(value).map_err(|_| StoreError::Backend(format!("negative {name}")))
}

fn invalid<T>(message: &str) -> Result<T, StoreError> {
    Err(StoreError::InvalidInput(message.into()))
}

fn db_error(context: &'static str) -> impl FnOnce(rusqlite::Error) -> StoreError {
    move |error| StoreError::Backend(format!("{context}: {error}"))
}
