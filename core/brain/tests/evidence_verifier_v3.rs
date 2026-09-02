use mci_brain::{
    BoundEvidenceVerdict, EventId, EvidenceContractError, EvidenceOrigin, EvidenceSet,
    EvidenceSlotVerdict, EvidenceSpan, ProposedClaim, MAX_CLAIM_FIELD_BYTES,
    MAX_EVIDENCE_SPAN_BYTES, MAX_VERIFIER_EVIDENCE_SLOTS,
};

fn claim() -> ProposedClaim {
    ProposedClaim::new("Maya", "approved", "launch on Sep 8", "project/hippo").unwrap()
}

fn origin() -> EvidenceOrigin {
    EvidenceOrigin::new("brain-device-a", "project/hippo", "screen_ocr").unwrap()
}

const AUTHORIZED_BRAIN: &str = "brain-device-a";

#[test]
fn proposed_claim_requires_one_nonempty_structured_relation() {
    let claim = ProposedClaim::new(
        "  Maya  ",
        " approved ",
        " launch on Sep 8 ",
        " project/hippo",
    )
    .expect("valid structured claim");
    assert_eq!(claim.subject(), "Maya");
    assert_eq!(claim.predicate(), "approved");
    assert_eq!(claim.object(), "launch on Sep 8");
    assert_eq!(claim.scope(), "project/hippo");

    for (subject, predicate, object, scope) in [
        ("", "approved", "launch", "project/hippo"),
        ("Maya", "", "launch", "project/hippo"),
        ("Maya", "approved", "", "project/hippo"),
        ("Maya", "approved", "launch", ""),
    ] {
        assert!(matches!(
            ProposedClaim::new(subject, predicate, object, scope),
            Err(EvidenceContractError::EmptyClaimField(_))
        ));
    }
}

#[test]
fn proposed_claim_rejects_multiline_or_nul_fields() {
    for value in ["Maya\napproved", "Maya\rapproved", "Maya\0approved"] {
        assert!(matches!(
            ProposedClaim::new(value, "approved", "launch", "project/hippo"),
            Err(EvidenceContractError::InvalidClaimField("subject"))
        ));
    }
}

#[test]
fn proposed_claim_and_evidence_have_pre_tokenization_size_limits() {
    let oversized_claim = "x".repeat(MAX_CLAIM_FIELD_BYTES + 1);
    assert!(matches!(
        ProposedClaim::new(&oversized_claim, "approved", "launch", "project/hippo"),
        Err(EvidenceContractError::ClaimFieldTooLarge { .. })
    ));

    let oversized_evidence = "x".repeat(MAX_EVIDENCE_SPAN_BYTES + 1);
    assert!(matches!(
        EvidenceSpan::new(
            EventId(1),
            &oversized_evidence,
            0,
            oversized_evidence.len(),
            &origin(),
        ),
        Err(EvidenceContractError::EvidenceSpanTooLarge { .. })
    ));
}

#[test]
fn evidence_span_is_utf8_safe_and_bound_to_the_full_event() {
    let event_text = "Owner: Maya. Launch: Sep 8. Café review complete.";
    let start = event_text.find("Café").unwrap();
    let end = start + "Café review complete.".len();
    let span = EvidenceSpan::new(EventId(41), event_text, start, end, &origin()).unwrap();

    assert_eq!(span.exact_text(), "Café review complete.");
    assert_eq!(span.byte_range(), start..end);
    assert_eq!(span.event_id(), EventId(41));
    assert_eq!(span.event_content_sha256().len(), 64);
    assert_eq!(span.provenance_sha256().len(), 64);
    assert_eq!(span.origin().scope(), "project/hippo");

    let inside_accent = start + 4;
    assert!(matches!(
        EvidenceSpan::new(EventId(41), event_text, inside_accent, end, &origin()),
        Err(EvidenceContractError::NonCharacterBoundary)
    ));
}

#[test]
fn evidence_span_rejects_empty_out_of_bounds_and_whitespace_ranges() {
    let text = "one two";
    assert!(matches!(
        EvidenceSpan::new(EventId(0), text, 0, text.len(), &origin()),
        Err(EvidenceContractError::UnpersistedEventId)
    ));
    assert!(matches!(
        EvidenceSpan::new(EventId(1), text, 3, 3, &origin()),
        Err(EvidenceContractError::InvalidEvidenceRange)
    ));
    assert!(matches!(
        EvidenceSpan::new(EventId(1), text, 0, text.len() + 1, &origin()),
        Err(EvidenceContractError::InvalidEvidenceRange)
    ));
    assert!(matches!(
        EvidenceSpan::new(EventId(1), text, 3, 4, &origin()),
        Err(EvidenceContractError::EmptyEvidenceSpan)
    ));
}

#[test]
fn evidence_set_is_nonempty_bounded_and_rejects_duplicate_spans() {
    assert!(matches!(
        EvidenceSet::new(&claim(), AUTHORIZED_BRAIN, Vec::new()),
        Err(EvidenceContractError::EmptyEvidenceSet)
    ));

    let spans = (0..=MAX_VERIFIER_EVIDENCE_SLOTS)
        .map(|index| {
            let text = Box::leak(format!("evidence {index}").into_boxed_str());
            EvidenceSpan::new(EventId(index as u64 + 1), text, 0, text.len(), &origin()).unwrap()
        })
        .collect();
    assert!(matches!(
        EvidenceSet::new(&claim(), AUTHORIZED_BRAIN, spans),
        Err(EvidenceContractError::TooManyEvidenceSpans { .. })
    ));

    let text = "Maya approved the launch.";
    let span = EvidenceSpan::new(EventId(7), text, 0, text.len(), &origin()).unwrap();
    assert!(matches!(
        EvidenceSet::new(&claim(), AUTHORIZED_BRAIN, vec![span.clone(), span]),
        Err(EvidenceContractError::DuplicateEvidenceSpan)
    ));
}

#[test]
fn evidence_set_rejects_cross_scope_or_cross_brain_provenance() {
    let text = "Maya approved the launch.";
    let private = EvidenceOrigin::new("brain-device-a", "private", "screen_ocr").unwrap();
    let other_brain = EvidenceOrigin::new("brain-device-b", "project/hippo", "screen_ocr").unwrap();

    assert!(matches!(
        EvidenceSet::new(
            &claim(),
            AUTHORIZED_BRAIN,
            vec![EvidenceSpan::new(EventId(7), text, 0, text.len(), &private).unwrap()]
        ),
        Err(EvidenceContractError::EvidenceScopeMismatch)
    ));
    assert!(matches!(
        EvidenceSet::new(
            &claim(),
            AUTHORIZED_BRAIN,
            vec![
                EvidenceSpan::new(EventId(7), text, 0, text.len(), &origin()).unwrap(),
                EvidenceSpan::new(EventId(8), text, 0, text.len(), &other_brain).unwrap(),
            ]
        ),
        Err(EvidenceContractError::MixedEvidenceBrains)
    ));

    let wrong_brain = EvidenceOrigin::new("brain-device-b", "project/hippo", "screen_ocr").unwrap();
    assert!(matches!(
        EvidenceSet::new(
            &claim(),
            AUTHORIZED_BRAIN,
            vec![EvidenceSpan::new(EventId(9), text, 0, text.len(), &wrong_brain).unwrap()]
        ),
        Err(EvidenceContractError::EvidenceBrainMismatch)
    ));
}

#[test]
fn evidence_set_exposes_ranked_slots_without_mutation() {
    let first = "The rollout owner is Maya.";
    let second = "The launch date is September 8.";
    let evidence = EvidenceSet::new(
        &claim(),
        AUTHORIZED_BRAIN,
        vec![
            EvidenceSpan::new(EventId(11), first, 0, first.len(), &origin()).unwrap(),
            EvidenceSpan::new(EventId(12), second, 0, second.len(), &origin()).unwrap(),
        ],
    )
    .unwrap();

    let slots = evidence.iter().collect::<Vec<_>>();
    assert_eq!(slots.len(), 2);
    assert_eq!(slots[0].event_id(), EventId(11));
    assert_eq!(slots[1].event_id(), EventId(12));
    assert!(evidence.validates_claim_scope(&claim()));
    let private_claim = ProposedClaim::new("Maya", "approved", "launch", "private").unwrap();
    assert!(!evidence.validates_claim_scope(&private_claim));
}

#[test]
fn host_binding_preserves_every_selected_citation_in_stable_slot_order() {
    let first_text = "The rollout owner is Maya.";
    let second_text = "Maya approved the September 8 launch date.";
    let evidence = EvidenceSet::new(
        &claim(),
        AUTHORIZED_BRAIN,
        vec![
            EvidenceSpan::new(EventId(11), first_text, 0, first_text.len(), &origin()).unwrap(),
            EvidenceSpan::new(EventId(12), second_text, 0, second_text.len(), &origin()).unwrap(),
        ],
    )
    .unwrap();

    let bound = evidence
        .bind(EvidenceSlotVerdict::Supported {
            confidence: 0.97,
            citation_slots: vec![1, 0],
        })
        .unwrap();
    let BoundEvidenceVerdict::Supported {
        confidence,
        citations,
    } = bound
    else {
        panic!("expected supported verdict");
    };
    assert!((confidence - 0.97).abs() < f32::EPSILON);
    assert_eq!(citations.len(), 2);
    assert_eq!(citations[0].event_id(), EventId(11));
    assert_eq!(citations[1].event_id(), EventId(12));
}

#[test]
fn host_binding_rejects_duplicate_unknown_or_missing_citation_slots() {
    let text = "The rollout owner is Maya.";
    let evidence = EvidenceSet::new(
        &claim(),
        AUTHORIZED_BRAIN,
        vec![EvidenceSpan::new(EventId(11), text, 0, text.len(), &origin()).unwrap()],
    )
    .unwrap();

    assert!(matches!(
        evidence.bind(EvidenceSlotVerdict::Supported {
            confidence: 0.9,
            citation_slots: vec![]
        }),
        Err(EvidenceContractError::MissingCitationSlots)
    ));
    assert!(matches!(
        evidence.bind(EvidenceSlotVerdict::Supported {
            confidence: 0.9,
            citation_slots: vec![0, 0]
        }),
        Err(EvidenceContractError::DuplicateCitationSlot(0))
    ));
    assert!(matches!(
        evidence.bind(EvidenceSlotVerdict::Contradicted {
            confidence: 0.9,
            citation_slots: vec![1]
        }),
        Err(EvidenceContractError::UnknownCitationSlot(1))
    ));
}

#[test]
fn host_binding_rejects_invalid_confidence() {
    let text = "The rollout owner is Maya.";
    let evidence = EvidenceSet::new(
        &claim(),
        AUTHORIZED_BRAIN,
        vec![EvidenceSpan::new(EventId(11), text, 0, text.len(), &origin()).unwrap()],
    )
    .unwrap();

    for confidence in [f32::NAN, f32::INFINITY, -0.1, 1.1] {
        assert!(matches!(
            evidence.bind(EvidenceSlotVerdict::Insufficient { confidence }),
            Err(EvidenceContractError::InvalidConfidence)
        ));
        assert!(matches!(
            evidence.bind(EvidenceSlotVerdict::Abstained {
                strongest_class_confidence: confidence
            }),
            Err(EvidenceContractError::InvalidConfidence)
        ));
    }
}

#[test]
fn bound_citation_revalidates_against_canonical_event_bytes() {
    let text = "Owner: Maya. Launch: Sep 8.";
    let start = text.find("Launch").unwrap();
    let evidence = EvidenceSet::new(
        &claim(),
        AUTHORIZED_BRAIN,
        vec![EvidenceSpan::new(EventId(31), text, start, text.len(), &origin()).unwrap()],
    )
    .unwrap();
    let BoundEvidenceVerdict::Supported { citations, .. } = evidence
        .bind(EvidenceSlotVerdict::Supported {
            confidence: 0.98,
            citation_slots: vec![0],
        })
        .unwrap()
    else {
        panic!("expected supported verdict");
    };
    let citation = &citations[0];

    assert!(citation.validate_against_event(EventId(31), &origin(), text));
    assert!(!citation.validate_against_event(EventId(32), &origin(), text));
    assert!(!citation.validate_against_event(
        EventId(31),
        &EvidenceOrigin::new("brain-device-a", "private", "screen_ocr").unwrap(),
        text
    ));
    assert!(!citation.validate_against_event(
        EventId(31),
        &origin(),
        "Owner: Maya. Launch: Sep 9."
    ));
}
