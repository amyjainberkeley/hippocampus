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
    if delta.id != delta.derived_id() {
        return invalid("memory delta id does not match its immutable payload");
    }
    insert_delta(tx, delta)?;

    for claim in &delta.claims {
        validate_claim(tx, delta, claim)?;
        for evidence in &claim.evidence {
            insert_evidence(tx, evidence)?;
        }
        insert_claim(tx, claim, &delta.id)?;
        for evidence in &claim.evidence {
            tx.execute(
                "INSERT OR IGNORE INTO memory_claim_evidence (claim_id, evidence_id)
                 VALUES (?1, ?2)",
                params![claim.id.0, evidence.id.0],
            )
            .map_err(db_error("link claim evidence"))?;
        }
        apply_recorded_retractions(tx, claim)?;
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
            insert_transition(tx, &transition, Some(&delta.id))?;
        }
    }
    for transition in &delta.transitions {
        validate_transition(tx, delta, transition)?;
        insert_transition(tx, transition, Some(&delta.id))?;
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
    insert_event_retraction(tx, retraction)?;

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
        insert_transition(tx, &transition, None)?;
    }
    Ok(())
}

fn validate_claim(
    tx: &Transaction<'_>,
    delta: &MemoryDelta,
    claim: &MemoryClaim,
) -> Result<(), StoreError> {
    if claim.id != claim.derived_id() {
        return invalid("memory claim id does not match its immutable payload");
    }
    if claim.source_event_id != delta.source_event_id {
        return invalid("memory claim source event does not match its delta");
    }
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
        && claim
            .attribution
            .as_deref()
            .is_none_or(|value| value.trim().is_empty())
    {
        return invalid("active claims require preserved attribution");
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
        validate_evidence(tx, evidence)?;
        if claim.status == ClaimStatus::Active
            && !scope_is_same_or_narrower(&evidence.source_scope, &claim.scope)
        {
            return invalid("active claim scope exceeds its evidence source scope");
        }
    }

    if let Some(previous_id) = &claim.supersedes_claim_id {
        let previous = read_claim(tx, previous_id)?.ok_or_else(|| {
            StoreError::InvalidInput(format!("unknown superseded claim {}", previous_id.0))
        })?;
        if previous.subject != claim.subject || previous.predicate != claim.predicate {
            return invalid("a correction must preserve subject and predicate");
        }
        if previous.scope != claim.scope {
            return invalid("a correction must preserve the replaced claim's exact scope");
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
        // A committed correction already retired its target. Replays still pass
        // immutable-payload validation and insert_claim's persisted-payload check.
        if read_claim(tx, &claim.id)?.is_none()
            && claim_status_as_of(tx, previous_id, claim.valid_from_us, delta.asserted_at_us)?
                != Some(ClaimStatus::Active)
        {
            return invalid(
                "a correction may supersede only a claim active at its bitemporal coordinates",
            );
        }
    }

    if claim.asserted_at_us != delta.asserted_at_us {
        return invalid("claim asserted_at_us must equal its delta timestamp");
    }
    Ok(())
}

fn validate_evidence(tx: &Transaction<'_>, evidence: &EvidenceRef) -> Result<(), StoreError> {
    if evidence.id != evidence.derived_id() {
        return invalid("memory evidence id does not match its immutable payload");
    }
    for (name, value) in [
        ("source_kind", evidence.source_kind.as_str()),
        ("source_locator", evidence.source_locator.as_str()),
        ("source_scope", evidence.source_scope.as_str()),
        ("content_hash", evidence.content_hash.as_str()),
    ] {
        validate_nonempty(name, value)?;
    }
    let canonical: Option<(i64, Option<String>, Option<String>, String)> = tx
        .query_row(
            "SELECT ts_us, app_bundle_id, url, text FROM events WHERE id = ?1",
            params![to_i64(evidence.event_id.0, "evidence event_id")?],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()
        .map_err(db_error("read canonical evidence event"))?;
    let Some((observed_at_us, app_bundle_id, url, text)) = canonical else {
        return invalid("memory projection references a missing event");
    };
    let expected_observed_at_us = u64::try_from(observed_at_us)
        .map_err(|_| StoreError::InvalidInput("canonical event timestamp is negative".into()))?;
    let expected_locator = EvidenceRef::canonical_source_locator(evidence.event_id, url.as_deref());
    let expected_scope =
        EvidenceRef::canonical_source_scope(evidence.event_id, app_bundle_id.as_deref());
    let expected_content_hash = EvidenceRef::canonical_content_hash(&text);
    if evidence.source_locator != expected_locator {
        return invalid("memory evidence locator does not match its canonical event");
    }
    if evidence.source_scope != expected_scope {
        return invalid("memory evidence source scope does not match its canonical event");
    }
    if evidence.observed_at_us != expected_observed_at_us {
        return invalid("memory evidence observation time does not match its canonical event");
    }
    if evidence.content_hash != expected_content_hash {
        return invalid("memory evidence content hash does not match its canonical event");
    }
    Ok(())
}

fn validate_transition(
    tx: &Transaction<'_>,
    delta: &MemoryDelta,
    value: &ClaimTransition,
) -> Result<(), StoreError> {
    if value.id != value.derived_id() {
        return invalid("claim transition id does not match its immutable payload");
    }
    if value.source_event_id != delta.source_event_id {
        return invalid("claim transition source event does not match its delta");
    }
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

fn insert_delta(tx: &Transaction<'_>, value: &MemoryDelta) -> Result<(), StoreError> {
    let existing: Option<(i64, i64)> = tx
        .query_row(
            "SELECT source_event_id, asserted_at_us FROM memory_deltas WHERE id = ?1",
            params![value.id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(db_error("read memory delta identity"))?;
    let expected = (
        to_i64(value.source_event_id.0, "source_event_id")?,
        to_i64(value.asserted_at_us, "asserted_at_us")?,
    );
    if let Some(existing) = existing {
        return if existing == expected {
            Ok(())
        } else {
            invalid("memory delta id conflicts with a different persisted payload")
        };
    }
    tx.execute(
        "INSERT INTO memory_deltas
         (id, source_event_id, asserted_at_us, projector_version)
         VALUES (?1, ?2, ?3, ?4)",
        params![value.id, expected.0, expected.1, value.projector_version],
    )
    .map_err(db_error("insert memory delta"))?;
    Ok(())
}

fn insert_evidence(tx: &Transaction<'_>, value: &EvidenceRef) -> Result<(), StoreError> {
    type EvidencePayload = (i64, String, String, String, i64, String);
    let existing: Option<EvidencePayload> = tx
        .query_row(
            "SELECT event_id, source_kind, source_locator, source_scope,
                    observed_at_us, content_hash
             FROM memory_evidence WHERE id = ?1",
            params![value.id.0],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            },
        )
        .optional()
        .map_err(db_error("read memory evidence identity"))?;
    let expected = (
        to_i64(value.event_id.0, "evidence event_id")?,
        value.source_kind.clone(),
        value.source_locator.clone(),
        value.source_scope.clone(),
        to_i64(value.observed_at_us, "observed_at_us")?,
        value.content_hash.clone(),
    );
    if let Some(existing) = existing {
        return if existing == expected {
            Ok(())
        } else {
            invalid("memory evidence id conflicts with a different persisted payload")
        };
    }
    tx.execute(
        "INSERT INTO memory_evidence
         (id, event_id, source_kind, source_locator, source_scope, observed_at_us, content_hash)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            value.id.0, expected.0, expected.1, expected.2, expected.3, expected.4, expected.5,
        ],
    )
    .map_err(db_error("insert memory evidence"))?;
    Ok(())
}

fn insert_claim(
    tx: &Transaction<'_>,
    value: &MemoryClaim,
    delta_id: &str,
) -> Result<(), StoreError> {
    type ClaimFields = (
        i64,
        String,
        String,
        String,
        String,
        Option<String>,
        f64,
        i64,
        i64,
        Option<i64>,
        String,
        Option<String>,
    );
    type ClaimPayload = (Option<String>, ClaimFields);
    let existing: Option<ClaimPayload> = tx
        .query_row(
            "SELECT delta_id, source_event_id, subject, predicate, object, scope, attribution,
                    confidence, asserted_at_us, valid_from_us, valid_to_us,
                    initial_status, supersedes_claim_id
             FROM memory_claims WHERE id = ?1",
            params![value.id.0],
            |row| {
                Ok((
                    row.get(0)?,
                    (
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                        row.get(6)?,
                        row.get(7)?,
                        row.get(8)?,
                        row.get(9)?,
                        row.get(10)?,
                        row.get(11)?,
                        row.get(12)?,
                    ),
                ))
            },
        )
        .optional()
        .map_err(db_error("read memory claim identity"))?;
    let expected = (
        Some(delta_id.to_owned()),
        (
            to_i64(value.source_event_id.0, "claim source_event_id")?,
            value.subject.clone(),
            value.predicate.clone(),
            value.object.clone(),
            value.scope.clone(),
            value.attribution.clone(),
            f64::from(value.confidence),
            to_i64(value.asserted_at_us, "claim asserted_at_us")?,
            to_i64(value.valid_from_us, "claim valid_from_us")?,
            value
                .valid_to_us
                .map(|valid_to| to_i64(valid_to, "claim valid_to_us"))
                .transpose()?,
            value.status.as_str().to_owned(),
            value.supersedes_claim_id.as_ref().map(|id| id.0.clone()),
        ),
    );
    if let Some(existing) = existing {
        return if existing == expected {
            Ok(())
        } else {
            invalid("memory claim id conflicts with a different persisted payload")
        };
    }
    tx.execute(
        "INSERT INTO memory_claims
         (id, delta_id, source_event_id, subject, predicate, object, scope, attribution,
          confidence, asserted_at_us, valid_from_us, valid_to_us,
          projector_version, initial_status, supersedes_claim_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
        params![
            value.id.0,
            expected.0,
            expected.1 .0,
            expected.1 .1,
            expected.1 .2,
            expected.1 .3,
            expected.1 .4,
            expected.1 .5,
            expected.1 .6,
            expected.1 .7,
            expected.1 .8,
            expected.1 .9,
            value.projector_version,
            expected.1 .10,
            expected.1 .11,
        ],
    )
    .map_err(db_error("insert memory claim"))?;
    Ok(())
}

fn insert_transition(
    tx: &Transaction<'_>,
    value: &ClaimTransition,
    delta_id: Option<&str>,
) -> Result<(), StoreError> {
    type TransitionFields = (String, String, i64, i64, String, i64);
    type TransitionPayload = (Option<String>, TransitionFields);
    let existing: Option<TransitionPayload> = tx
        .query_row(
            "SELECT delta_id, claim_id, status, asserted_at_us, effective_at_us, reason,
                    source_event_id
             FROM memory_claim_transitions WHERE id = ?1",
            params![value.id],
            |row| {
                Ok((
                    row.get(0)?,
                    (
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                        row.get(6)?,
                    ),
                ))
            },
        )
        .optional()
        .map_err(db_error("read claim transition identity"))?;
    let expected = (
        delta_id.map(str::to_owned),
        (
            value.claim_id.0.clone(),
            value.status.as_str().to_owned(),
            to_i64(value.asserted_at_us, "transition asserted_at_us")?,
            to_i64(value.effective_at_us, "transition effective_at_us")?,
            value.reason.clone(),
            to_i64(value.source_event_id.0, "transition source_event_id")?,
        ),
    );
    if let Some(existing) = existing {
        return if existing == expected {
            Ok(())
        } else {
            invalid("claim transition id conflicts with a different persisted payload")
        };
    }
    tx.execute(
        "INSERT INTO memory_claim_transitions
         (id, delta_id, claim_id, status, asserted_at_us, effective_at_us, reason,
          source_event_id, projector_version)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            value.id,
            expected.0,
            expected.1 .0,
            expected.1 .1,
            expected.1 .2,
            expected.1 .3,
            expected.1 .4,
            expected.1 .5,
            value.projector_version,
        ],
    )
    .map_err(db_error("insert claim transition"))?;
    Ok(())
}

fn insert_event_retraction(
    tx: &Transaction<'_>,
    value: &MemoryRetraction,
) -> Result<(), StoreError> {
    type RetractionPayload = (i64, i64, i64, i64, String);
    let id = value.derived_id();
    let existing: Option<RetractionPayload> = tx
        .query_row(
            "SELECT target_event_id, retraction_event_id, asserted_at_us,
                    effective_at_us, reason
             FROM memory_event_retractions WHERE id = ?1",
            params![id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .optional()
        .map_err(db_error("read event retraction identity"))?;
    let expected = (
        to_i64(value.target_event_id.0, "target_event_id")?,
        to_i64(value.retraction_event_id.0, "retraction_event_id")?,
        to_i64(value.asserted_at_us, "retraction asserted_at_us")?,
        to_i64(value.effective_at_us, "retraction effective_at_us")?,
        value.reason.clone(),
    );
    if let Some(existing) = existing {
        return if existing == expected {
            Ok(())
        } else {
            invalid("event retraction id conflicts with a different persisted payload")
        };
    }
    tx.execute(
        "INSERT INTO memory_event_retractions
         (id, target_event_id, retraction_event_id, asserted_at_us,
          effective_at_us, reason, projector_version)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            id,
            expected.0,
            expected.1,
            expected.2,
            expected.3,
            expected.4,
            value.projector_version,
        ],
    )
    .map_err(db_error("insert event retraction"))?;
    Ok(())
}

fn apply_recorded_retractions(tx: &Transaction<'_>, claim: &MemoryClaim) -> Result<(), StoreError> {
    let event_ids: BTreeSet<EventId> = claim
        .evidence
        .iter()
        .map(|evidence| evidence.event_id)
        .collect();
    for event_id in event_ids {
        let mut stmt = tx
            .prepare(
                "SELECT retraction_event_id, asserted_at_us, effective_at_us,
                        reason, projector_version
                 FROM memory_event_retractions
                 WHERE target_event_id = ?1
                 ORDER BY asserted_at_us ASC, effective_at_us ASC, id ASC",
            )
            .map_err(db_error("prepare recorded event retractions"))?;
        let rows = stmt
            .query_map(params![to_i64(event_id.0, "retracted event_id")?], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                ))
            })
            .map_err(db_error("query recorded event retractions"))?;
        let mut recorded = Vec::new();
        for row in rows {
            recorded.push(row.map_err(db_error("read recorded event retraction"))?);
        }
        drop(stmt);
        for (source, asserted, effective, reason, projector_version) in recorded {
            let transition = ClaimTransition::new(
                claim.id.clone(),
                ClaimStatus::Retracted,
                to_u64(asserted, "retraction asserted_at_us")?,
                to_u64(effective, "retraction effective_at_us")?,
                &reason,
                EventId(to_u64(source, "retraction source_event_id")?),
                &projector_version,
            );
            insert_transition(tx, &transition, None)?;
        }
    }
    Ok(())
}

fn claim_status_as_of(
    tx: &Transaction<'_>,
    claim_id: &MemoryClaimId,
    valid_at_us: u64,
    asserted_as_of_us: u64,
) -> Result<Option<ClaimStatus>, StoreError> {
    let initial: Option<String> = tx
        .query_row(
            "SELECT initial_status
             FROM memory_claims
             WHERE id = ?1
               AND asserted_at_us <= ?2
               AND valid_from_us <= ?3
               AND (valid_to_us IS NULL OR valid_to_us >= ?3)",
            params![
                claim_id.0,
                to_i64(asserted_as_of_us, "asserted_as_of_us")?,
                to_i64(valid_at_us, "valid_at_us")?,
            ],
            |row| row.get(0),
        )
        .optional()
        .map_err(db_error("read claim status coordinates"))?;
    let Some(initial) = initial else {
        return Ok(None);
    };
    let transitioned: Option<String> = tx
        .query_row(
            "SELECT status FROM memory_claim_transitions
             WHERE claim_id = ?1
               AND asserted_at_us <= ?2
               AND effective_at_us <= ?3
             ORDER BY asserted_at_us DESC, effective_at_us DESC, id DESC
             LIMIT 1",
            params![
                claim_id.0,
                to_i64(asserted_as_of_us, "asserted_as_of_us")?,
                to_i64(valid_at_us, "valid_at_us")?,
            ],
            |row| row.get(0),
        )
        .optional()
        .map_err(db_error("read claim transition coordinates"))?;
    transitioned.as_deref().map_or_else(
        || parse_status(&initial).map(Some),
        |status| parse_status(status).map(Some),
    )
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
                    c.projector_version, c.initial_status, c.supersedes_claim_id,
                    c.source_event_id
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

struct ExpansionAccumulator {
    claim_ids: Vec<MemoryClaimId>,
    evidence: Vec<ExpandedEvidence>,
    episodes: BTreeSet<EpisodeId>,
    entities: BTreeSet<EntityId>,
    identities: BTreeSet<IdentityId>,
    nodes_used: usize,
    edges_used: usize,
    tokens_used: usize,
    truncated: bool,
}

impl ExpansionAccumulator {
    fn new(seed_count: usize) -> Self {
        Self {
            claim_ids: Vec::with_capacity(seed_count),
            evidence: Vec::new(),
            episodes: BTreeSet::new(),
            entities: BTreeSet::new(),
            identities: BTreeSet::new(),
            nodes_used: 0,
            edges_used: 0,
            tokens_used: 0,
            truncated: false,
        }
    }

    fn finish(self) -> MemoryExpansion {
        MemoryExpansion {
            claim_ids: self.claim_ids,
            evidence: self.evidence,
            episode_ids: self.episodes.into_iter().collect(),
            entity_ids: self.entities.into_iter().collect(),
            identity_ids: self.identities.into_iter().collect(),
            nodes_used: self.nodes_used,
            edges_used: self.edges_used,
            tokens_used: self.tokens_used,
            truncated: self.truncated,
        }
    }
}

pub(crate) fn expand_memory(
    tx: &Transaction<'_>,
    seed_claim_ids: &[MemoryClaimId],
    budget: ExpansionBudget,
) -> Result<MemoryExpansion, StoreError> {
    let mut seeds = seed_claim_ids.to_vec();
    seeds.sort();
    seeds.dedup();
    let mut scheduled = Vec::with_capacity(seeds.len());
    for claim_id in seeds {
        let admissible = claim_has_admissible_evidence(tx, &claim_id, budget)?;
        scheduled.push((!admissible, claim_id));
    }
    scheduled.sort();
    let mut accumulator = ExpansionAccumulator::new(scheduled.len());

    for (_, claim_id) in scheduled {
        if read_claim(tx, &claim_id)?.is_none() {
            continue;
        }
        if accumulator.nodes_used == budget.max_nodes {
            accumulator.truncated = true;
            continue;
        }
        accumulator.nodes_used += 1;
        accumulator.claim_ids.push(claim_id.clone());
        expand_claim_evidence(tx, &claim_id, budget, &mut accumulator)?;
    }

    Ok(accumulator.finish())
}

fn expand_claim_evidence(
    tx: &Transaction<'_>,
    claim_id: &MemoryClaimId,
    budget: ExpansionBudget,
    accumulator: &mut ExpansionAccumulator,
) -> Result<(), StoreError> {
    for evidence in read_evidence(tx, claim_id)? {
        if accumulator.evidence.len() == budget.max_evidence
            || accumulator.edges_used == budget.max_edges
        {
            accumulator.truncated = true;
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
        if token_count > budget.max_tokens.saturating_sub(accumulator.tokens_used) {
            accumulator.truncated = true;
            continue;
        }
        accumulator.tokens_used += token_count;
        accumulator.edges_used += 1;
        accumulator.evidence.push(ExpandedEvidence {
            evidence: evidence.clone(),
            excerpt: crate::EventRecord::truncate_snippet(&text),
            token_count,
        });

        if let Some(raw_episode) = episode_id {
            let episode = EpisodeId(to_u64(raw_episode, "episode_id")?);
            admit_node(
                episode,
                &mut accumulator.episodes,
                &mut accumulator.nodes_used,
                &mut accumulator.edges_used,
                budget,
                &mut accumulator.truncated,
            );
        }

        for (entity, identity) in expansion_graph_rows(tx, evidence.event_id)? {
            admit_node(
                EntityId(entity),
                &mut accumulator.entities,
                &mut accumulator.nodes_used,
                &mut accumulator.edges_used,
                budget,
                &mut accumulator.truncated,
            );
            if let Some(identity) = identity {
                admit_node(
                    IdentityId(identity),
                    &mut accumulator.identities,
                    &mut accumulator.nodes_used,
                    &mut accumulator.edges_used,
                    budget,
                    &mut accumulator.truncated,
                );
            }
        }
    }
    Ok(())
}

fn expansion_graph_rows(
    tx: &Transaction<'_>,
    event_id: EventId,
) -> Result<Vec<(String, Option<String>)>, StoreError> {
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
        .query_map(params![to_i64(event_id.0, "graph event_id")?], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
        })
        .map_err(db_error("query expansion graph"))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(db_error("read expansion graph"))
}

fn claim_has_admissible_evidence(
    tx: &Transaction<'_>,
    claim_id: &MemoryClaimId,
    budget: ExpansionBudget,
) -> Result<bool, StoreError> {
    if budget.max_nodes == 0
        || budget.max_edges == 0
        || budget.max_evidence == 0
        || budget.max_tokens == 0
    {
        return Ok(false);
    }
    for evidence in read_evidence(tx, claim_id)? {
        let token_count: Option<usize> = tx
            .query_row(
                "SELECT text FROM events WHERE id = ?1",
                params![to_i64(evidence.event_id.0, "evidence event_id")?],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(db_error("preflight expansion evidence"))?
            .map(|text| text.split_whitespace().count());
        if token_count.is_some_and(|tokens| tokens <= budget.max_tokens) {
            return Ok(true);
        }
    }
    Ok(false)
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
                initial_status, supersedes_claim_id, source_event_id
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
        source_event_id: EventId(u64::try_from(row.get::<_, i64>(13)?).unwrap_or(0)),
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
