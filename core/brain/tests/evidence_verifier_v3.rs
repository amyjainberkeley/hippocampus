use mci_brain::{
    BoundEvidenceVerdict, EventId, EvidenceContractError, EvidenceSet, EvidenceSlotVerdict,
    EvidenceSpan, ProposedClaim, MAX_VERIFIER_EVIDENCE_SLOTS,
};

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
fn evidence_span_is_utf8_safe_and_bound_to_the_full_event() {
    let event_text = "Owner: Maya. Launch: Sep 8. Café review complete.";
    let start = event_text.find("Café").unwrap();
    let end = start + "Café review complete.".len();
    let span = EvidenceSpan::new(EventId(41), event_text, start, end).unwrap();

    assert_eq!(span.exact_text(), "Café review complete.");
    assert_eq!(span.byte_range(), start..end);
    assert_eq!(span.event_id(), EventId(41));
    assert_eq!(span.event_content_sha256().len(), 64);

    let inside_accent = start + 4;
    assert!(matches!(
        EvidenceSpan::new(EventId(41), event_text, inside_accent, end),
        Err(EvidenceContractError::NonCharacterBoundary)
    ));
}

#[test]
fn evidence_span_rejects_empty_out_of_bounds_and_whitespace_ranges() {
    let text = "one two";
    assert!(matches!(
        EvidenceSpan::new(EventId(1), text, 3, 3),
        Err(EvidenceContractError::InvalidEvidenceRange)
    ));
    assert!(matches!(
        EvidenceSpan::new(EventId(1), text, 0, text.len() + 1),
        Err(EvidenceContractError::InvalidEvidenceRange)
    ));
    assert!(matches!(
        EvidenceSpan::new(EventId(1), text, 3, 4),
        Err(EvidenceContractError::EmptyEvidenceSpan)
    ));
}

#[test]
fn evidence_set_is_nonempty_bounded_and_rejects_duplicate_spans() {
    assert!(matches!(
        EvidenceSet::new(Vec::new()),
        Err(EvidenceContractError::EmptyEvidenceSet)
    ));

    let spans = (0..=MAX_VERIFIER_EVIDENCE_SLOTS)
        .map(|index| {
            let text = Box::leak(format!("evidence {index}").into_boxed_str());
            EvidenceSpan::new(EventId(index as u64 + 1), text, 0, text.len()).unwrap()
        })
        .collect();
    assert!(matches!(
        EvidenceSet::new(spans),
        Err(EvidenceContractError::TooManyEvidenceSpans { .. })
    ));

    let text = "Maya approved the launch.";
    let span = EvidenceSpan::new(EventId(7), text, 0, text.len()).unwrap();
    assert!(matches!(
        EvidenceSet::new(vec![span.clone(), span]),
        Err(EvidenceContractError::DuplicateEvidenceSpan)
    ));
}

#[test]
fn host_binding_preserves_every_selected_citation_in_stable_slot_order() {
    let first_text = "The rollout owner is Maya.";
    let second_text = "Maya approved the September 8 launch date.";
    let evidence = EvidenceSet::new(vec![
        EvidenceSpan::new(EventId(11), first_text, 0, first_text.len()).unwrap(),
        EvidenceSpan::new(EventId(12), second_text, 0, second_text.len()).unwrap(),
    ])
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
    let evidence = EvidenceSet::new(vec![
        EvidenceSpan::new(EventId(11), text, 0, text.len()).unwrap()
    ])
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
    let evidence = EvidenceSet::new(vec![
        EvidenceSpan::new(EventId(11), text, 0, text.len()).unwrap()
    ])
    .unwrap();

    for confidence in [f32::NAN, f32::INFINITY, -0.1, 1.1] {
        assert!(matches!(
            evidence.bind(EvidenceSlotVerdict::Insufficient { confidence }),
            Err(EvidenceContractError::InvalidConfidence)
        ));
    }
}

#[test]
fn bound_citation_revalidates_against_canonical_event_bytes() {
    let text = "Owner: Maya. Launch: Sep 8.";
    let start = text.find("Launch").unwrap();
    let evidence = EvidenceSet::new(vec![EvidenceSpan::new(
        EventId(31),
        text,
        start,
        text.len(),
    )
    .unwrap()])
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

    assert!(citation.validate_against_event(EventId(31), text));
    assert!(!citation.validate_against_event(EventId(32), text));
    assert!(!citation.validate_against_event(EventId(31), "Owner: Maya. Launch: Sep 9."));
}
