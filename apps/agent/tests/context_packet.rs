use mci_agent::context_packet::{
    compile_context_packet, render_context_packet_markdown, ContextBudget, ContextEvidence,
    ContextPacketOutcome, ContextSectionKind, ContextSectionStatus, ContextSources,
    EvidencePriority,
};
use mci_brain::{ClaimStatus, Event, EventId, EvidenceRef, MemoryClaim, MemoryClaimId};

const NOW_US: u64 = 2_000_000;

fn event(id: u64, ts_us: u64, text: &str) -> Event {
    Event {
        id: EventId(id),
        ts_us,
        app_bundle_id: Some("com.apple.dt.Xcode".into()),
        window_title: Some("Hippocampus".into()),
        url: Some("https://github.com/example/hippocampus".into()),
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

fn claim(source: &Event, predicate: &str, object: &str, confidence: f32) -> MemoryClaim {
    MemoryClaim::new(
        source.id,
        "Hippocampus",
        predicate,
        object,
        "project/hippocampus",
        Some("Amy".into()),
        confidence,
        source.ts_us,
        source.ts_us,
        None,
        "test-projector-v1",
        ClaimStatus::Active,
        None,
        vec![EvidenceRef::from_event(source.id, source, "screen_ocr")],
    )
}

fn section(
    packet: &mci_agent::context_packet::ContextPacket,
    kind: ContextSectionKind,
) -> &mci_agent::context_packet::ContextSection {
    packet
        .sections
        .iter()
        .find(|section| section.kind == kind)
        .expect("section exists")
}

#[test]
fn compiler_is_deterministic_and_keeps_the_fixed_section_hierarchy() {
    let decision_event = event(
        20,
        1_900_000,
        "Use a bounded cited packet for agent handoff",
    );
    let open_loop_event = event(10, 1_800_000, "Connect the packet to Claude and Codex");
    let decision = claim(
        &decision_event,
        "decision",
        "use a bounded cited context packet",
        0.95,
    );
    let open_loop = claim(
        &open_loop_event,
        "next_step",
        "connect Claude and Codex",
        0.90,
    );
    let evidence = vec![
        ContextEvidence::from_event(&decision_event, EvidencePriority::Claim, None),
        ContextEvidence::from_event(&open_loop_event, EvidencePriority::Claim, None),
    ];

    let first = compile_context_packet(
        Some("hippocampus"),
        NOW_US,
        ContextBudget::new(300, 8),
        ContextSources {
            claims: vec![decision.clone(), open_loop.clone()],
            evidence: evidence.clone(),
        },
    );
    let second = compile_context_packet(
        Some("hippocampus"),
        NOW_US,
        ContextBudget::new(300, 8),
        ContextSources {
            claims: vec![open_loop, decision],
            evidence: evidence.into_iter().rev().collect(),
        },
    );

    assert_eq!(first, second);
    assert_eq!(
        first
            .sections
            .iter()
            .map(|section| section.kind)
            .collect::<Vec<_>>(),
        vec![
            ContextSectionKind::CurrentState,
            ContextSectionKind::Changes,
            ContextSectionKind::Decisions,
            ContextSectionKind::OpenLoops,
            ContextSectionKind::People,
            ContextSectionKind::Evidence,
        ]
    );
    assert_eq!(first.outcome, ContextPacketOutcome::Grounded);
    assert_eq!(
        section(&first, ContextSectionKind::Decisions).items.len(),
        1
    );
    assert_eq!(
        section(&first, ContextSectionKind::OpenLoops).items.len(),
        1
    );
    assert!(section(&first, ContextSectionKind::Decisions).items[0]
        .source_claim_id
        .is_some());
}

#[test]
fn packet_honors_the_content_budget_and_preserves_rendered_claim_citations() {
    let source = event(
        42,
        1_900_000,
        "A long exact source excerpt that should be shortened before the packet can exceed its explicit content token budget",
    );
    let packet = compile_context_packet(
        None,
        NOW_US,
        ContextBudget::new(24, 4),
        ContextSources {
            claims: vec![claim(
                &source,
                "decision",
                "ship cited context packets",
                0.99,
            )],
            evidence: vec![ContextEvidence::from_event(
                &source,
                EvidencePriority::Claim,
                None,
            )],
        },
    );

    assert!(packet.token_estimate <= 24);
    assert!(packet.truncated);
    assert!(packet
        .citations
        .iter()
        .any(|citation| citation.event_id == 42));
    let decision = &section(&packet, ContextSectionKind::Decisions).items[0];
    assert_eq!(decision.citation_event_ids, vec![42]);
}

#[test]
fn weak_claims_are_not_promoted_and_their_section_abstains() {
    let source = event(7, 1_900_000, "Maybe launch tomorrow");
    let packet = compile_context_packet(
        Some("launch"),
        NOW_US,
        ContextBudget::new(200, 4),
        ContextSources {
            claims: vec![claim(&source, "decision", "launch tomorrow", 0.20)],
            evidence: Vec::new(),
        },
    );

    assert_eq!(packet.outcome, ContextPacketOutcome::NothingAvailable);
    assert_eq!(packet.dropped_weak_claims, 1);
    let decisions = section(&packet, ContextSectionKind::Decisions);
    assert_eq!(decisions.status, ContextSectionStatus::Abstained);
    assert!(decisions.items.is_empty());
}

#[test]
fn claim_without_a_readable_canonical_event_is_not_grounded() {
    let source = event(8, 1_900_000, "Decision source later removed by retention");
    let packet = compile_context_packet(
        Some("hippocampus"),
        NOW_US,
        ContextBudget::new(200, 4),
        ContextSources {
            claims: vec![claim(
                &source,
                "decision",
                "keep only claims with readable evidence",
                0.99,
            )],
            evidence: Vec::new(),
        },
    );

    assert_eq!(packet.outcome, ContextPacketOutcome::NothingAvailable);
    assert!(packet.citations.is_empty());
    assert_eq!(
        section(&packet, ContextSectionKind::Decisions).status,
        ContextSectionStatus::Abstained
    );
}

#[test]
fn contradictory_active_claims_abstain_instead_of_selecting_a_winner() {
    let first_source = event(30, 1_800_000, "Use SQLite for the context index");
    let second_source = event(31, 1_900_000, "Use Postgres for the context index");
    let packet = compile_context_packet(
        Some("hippocampus"),
        NOW_US,
        ContextBudget::new(200, 8),
        ContextSources {
            claims: vec![
                claim(&first_source, "decision", "use SQLite", 0.95),
                claim(&second_source, "decision", "use Postgres", 0.95),
            ],
            evidence: vec![
                ContextEvidence::from_event(&first_source, EvidencePriority::Claim, None),
                ContextEvidence::from_event(&second_source, EvidencePriority::Claim, None),
            ],
        },
    );

    assert_eq!(packet.outcome, ContextPacketOutcome::NothingAvailable);
    assert_eq!(packet.dropped_weak_claims, 2);
    assert_eq!(
        section(&packet, ContextSectionKind::Decisions).status,
        ContextSectionStatus::Abstained
    );
}

#[test]
fn superseded_claim_is_not_rendered_even_when_its_evidence_is_present() {
    let source = event(32, 1_900_000, "An old decision that was superseded");
    let mut old_claim = claim(&source, "decision", "use the old approach", 0.99);
    old_claim.status = ClaimStatus::Superseded;
    let packet = compile_context_packet(
        Some("hippocampus"),
        NOW_US,
        ContextBudget::new(200, 4),
        ContextSources {
            claims: vec![old_claim],
            evidence: vec![ContextEvidence::from_event(
                &source,
                EvidencePriority::Claim,
                None,
            )],
        },
    );

    assert_eq!(packet.outcome, ContextPacketOutcome::NothingAvailable);
    assert_eq!(packet.dropped_weak_claims, 1);
}

#[test]
fn oversized_first_claim_does_not_starve_a_later_small_claim() {
    let large_source = event(40, 1_800_000, "large claim source");
    let small_source = event(41, 1_900_000, "small claim source");
    let mut large = claim(
        &large_source,
        "decision",
        &vec!["oversized"; 100].join(" "),
        0.99,
    );
    large.id = MemoryClaimId("a-large".into());
    large.subject = "Hippocampus architecture".into();
    let mut small = claim(&small_source, "decision", "ship safely", 0.99);
    small.id = MemoryClaimId("b-small".into());
    small.subject = "Hippocampus release".into();
    let packet = compile_context_packet(
        Some("hippocampus"),
        NOW_US,
        ContextBudget::new(12, 4),
        ContextSources {
            claims: vec![large, small],
            evidence: vec![
                ContextEvidence::from_event(&large_source, EvidencePriority::Claim, None),
                ContextEvidence::from_event(&small_source, EvidencePriority::Claim, None),
            ],
        },
    );

    let decisions = section(&packet, ContextSectionKind::Decisions);
    assert_eq!(decisions.items.len(), 1);
    assert_eq!(
        decisions.items[0].source_claim_id.as_deref(),
        Some("b-small")
    );
    assert!(packet.truncated);
}

#[test]
fn packet_enforces_a_byte_ceiling_for_pathological_single_tokens() {
    let source = event(50, 1_900_000, &"x".repeat(100_000));
    let packet = compile_context_packet(
        None,
        NOW_US,
        ContextBudget::new(16, 4),
        ContextSources {
            claims: Vec::new(),
            evidence: vec![ContextEvidence::from_event(
                &source,
                EvidencePriority::Recent,
                None,
            )],
        },
    );

    assert!(packet.byte_estimate <= 16 * 24);
    assert!(packet.truncated);
    assert!(section(&packet, ContextSectionKind::Evidence)
        .items
        .is_empty());
}

#[test]
fn raw_recent_activity_is_labeled_observation_not_grounded_claim() {
    let source = event(3, 1_950_000, "Implemented the first context packet fixture");
    let packet = compile_context_packet(
        None,
        NOW_US,
        ContextBudget::new(200, 4),
        ContextSources {
            claims: Vec::new(),
            evidence: vec![ContextEvidence::from_event(
                &source,
                EvidencePriority::Recent,
                None,
            )],
        },
    );

    assert_eq!(packet.outcome, ContextPacketOutcome::ObservationsOnly);
    assert_eq!(
        section(&packet, ContextSectionKind::Changes).status,
        ContextSectionStatus::Observed
    );
    assert_eq!(
        section(&packet, ContextSectionKind::CurrentState).status,
        ContextSectionStatus::Abstained
    );
}

#[test]
fn repeated_screen_ocr_uses_only_the_newest_canonical_citation() {
    let oldest = event(
        70,
        1_700_000,
        "[app=com.apple.Terminal | title=Build | url=? | ts=1970-01-01T00:00:01.700Z]\nThe notarized release build completed successfully.",
    );
    let middle = event(
        71,
        1_800_000,
        "[app=com.apple.Terminal | title=Build | url=? | ts=1970-01-01T00:00:01.800Z]\nThe notarized release build completed successfully.",
    );
    let newest = event(
        72,
        1_900_000,
        "[app=com.apple.Terminal | title=Build | url=? | ts=1970-01-01T00:00:01.900Z]\n  The notarized release BUILD completed successfully.  ",
    );
    let packet = compile_context_packet(
        Some("release build"),
        NOW_US,
        ContextBudget::new(200, 6),
        ContextSources {
            claims: Vec::new(),
            evidence: [oldest, newest, middle]
                .iter()
                .map(|source| {
                    let mut evidence =
                        ContextEvidence::from_event(source, EvidencePriority::Focused, Some(0.8));
                    evidence.source_kind = "screen_ocr".into();
                    evidence
                })
                .collect(),
        },
    );

    assert_eq!(
        packet
            .citations
            .iter()
            .map(|citation| citation.event_id)
            .collect::<Vec<_>>(),
        vec![72]
    );
    assert_eq!(
        section(&packet, ContextSectionKind::Evidence).items.len(),
        1
    );
}

#[test]
fn current_focus_excludes_only_explicitly_superseded_observations() {
    let previous = event(80, 1_700_000, "Previous plan: Martin.");
    let current = event(
        81,
        1_900_000,
        "Current decision: Priya. This supersedes the previous plan.",
    );
    let packet = compile_context_packet(
        Some("Who owns HIP-204 now?"),
        NOW_US,
        ContextBudget::new(200, 6),
        ContextSources {
            claims: Vec::new(),
            evidence: [previous, current]
                .iter()
                .map(|source| {
                    ContextEvidence::from_event(source, EvidencePriority::Focused, Some(0.8))
                })
                .collect(),
        },
    );

    let cited = packet
        .citations
        .iter()
        .map(|citation| citation.event_id)
        .collect::<Vec<_>>();
    assert_eq!(cited, vec![81]);
}

#[test]
fn current_focus_preserves_competing_observations_without_supersession_marker() {
    let first = event(90, 1_700_000, "Martin owns HIP-204.");
    let second = event(91, 1_900_000, "Priya owns HIP-204.");
    let packet = compile_context_packet(
        Some("Who owns HIP-204 now?"),
        NOW_US,
        ContextBudget::new(200, 6),
        ContextSources {
            claims: Vec::new(),
            evidence: [first, second]
                .iter()
                .map(|source| {
                    ContextEvidence::from_event(source, EvidencePriority::Focused, Some(0.8))
                })
                .collect(),
        },
    );

    assert_eq!(packet.citations.len(), 2);
}

#[test]
fn markdown_handoff_preserves_truth_status_and_exact_event_citations() {
    let source = event(
        92,
        1_900_000,
        "Current decision: ship the bounded context command.",
    );
    let mut packet = compile_context_packet(
        Some("What should the coding agent know?"),
        NOW_US,
        ContextBudget::new(200, 6),
        ContextSources {
            claims: Vec::new(),
            evidence: vec![ContextEvidence::from_event(
                &source,
                EvidencePriority::Focused,
                Some(0.8),
            )],
        },
    );
    packet.focus_retrieval = Some(mci_agent::context_packet::ContextFocusRetrieval::degraded(
        mci_brain::RetrievalDegradation::EvidenceVerifierUnavailable,
    ));

    let markdown = render_context_packet_markdown(&packet);

    assert!(markdown.contains("# Hippocampus context"));
    assert!(markdown.contains("Truth status: observations only"));
    assert!(markdown.contains("Retrieval: degraded (evidence verifier unavailable)"));
    assert!(markdown.contains("[event 92]"));
    assert!(markdown.contains("com.apple.dt.Xcode"));
    assert!(markdown.contains("https://github.com/example/hippocampus"));
    assert!(markdown.contains("Observations are not verified facts."));
}

#[test]
fn empty_sources_return_a_typed_empty_packet() {
    let packet = compile_context_packet(
        None,
        NOW_US,
        ContextBudget::new(200, 4),
        ContextSources::default(),
    );

    assert_eq!(packet.outcome, ContextPacketOutcome::NothingAvailable);
    assert!(packet.citations.is_empty());
    assert!(packet
        .sections
        .iter()
        .all(|section| section.status == ContextSectionStatus::Abstained));
}

#[test]
fn focused_packet_does_not_leak_an_out_of_scope_claims_evidence() {
    let unrelated = event(99, 1_900_000, "Confidential details from another project");
    let packet = compile_context_packet(
        Some("hippocampus"),
        NOW_US,
        ContextBudget::new(200, 4),
        ContextSources {
            claims: vec![MemoryClaim::new(
                unrelated.id,
                "Unrelated project",
                "decision",
                "keep this in the unrelated workspace",
                "project/unrelated",
                Some("Amy".into()),
                0.99,
                unrelated.ts_us,
                unrelated.ts_us,
                None,
                "test-projector-v1",
                ClaimStatus::Active,
                None,
                vec![EvidenceRef::from_event(
                    unrelated.id,
                    &unrelated,
                    "screen_ocr",
                )],
            )],
            evidence: vec![ContextEvidence::from_event(
                &unrelated,
                EvidencePriority::Claim,
                None,
            )],
        },
    );

    assert_eq!(packet.outcome, ContextPacketOutcome::NothingAvailable);
    assert!(packet.citations.is_empty());
    assert!(section(&packet, ContextSectionKind::Evidence)
        .items
        .is_empty());
}

#[test]
fn multiword_focus_can_match_across_claim_fields() {
    let source = event(60, 1_900_000, "Hippocampus launch is ready");
    let packet = compile_context_packet(
        Some("hippocampus launch"),
        NOW_US,
        ContextBudget::new(200, 4),
        ContextSources {
            claims: vec![claim(
                &source,
                "decision",
                "launch the memory workspace",
                0.99,
            )],
            evidence: vec![ContextEvidence::from_event(
                &source,
                EvidencePriority::Claim,
                None,
            )],
        },
    );

    assert_eq!(packet.outcome, ContextPacketOutcome::Grounded);
    assert_eq!(
        section(&packet, ContextSectionKind::Decisions).items.len(),
        1
    );
}
