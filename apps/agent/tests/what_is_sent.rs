//! What a connected AI is told without asking: one decision, used by the
//! context packet, the session hook, the Overview's "Your AI already knows"
//! and the You page. Synthetic memory only.

mod handoff_fixture;

use std::collections::HashSet;

use handoff_fixture::{clock, fixture_brain, key, ts_us};
use mci_agent::context_packet::{
    compile_context_packet, render_context_packet_markdown, render_understanding_block,
    ContextBudget, ContextSources,
};
use mci_agent::handoff::{
    compile_handoff_with_block, fallback_envelope, no_project_memory_envelope, DISCLAIMER,
};
use mci_agent::understanding::overview::{self, OverviewEnv};
use mci_agent::understanding::query::{self, about_you, context_understanding, model_page};
use mci_brain::understanding::{NewProposition, PropositionKind, SessionNote};
use mci_brain::SqlCipherBrainStore;

const PDT: i32 = -7 * 3600;
const MIN: u64 = 60_000_000;

fn now_us() -> u64 {
    ts_us("2026-09-26T05:43:00Z") + 60 * MIN
}

fn claim(text: &str, kind: PropositionKind, confidence: f64) -> NewProposition {
    NewProposition {
        text: text.into(),
        reasoning: "Seen in the fixture.".into(),
        kind,
        confidence,
        decay: 0.3,
        model: "apple-foundation-models".into(),
    }
}

/// A model note two hours ago whose `beneath` says nothing, a measured note
/// before it, and items of every kind.
fn learn(store: &SqlCipherBrainStore, now: u64) -> Vec<i64> {
    store
        .put_session_note(&SessionNote {
            start_us: now - 120 * MIN,
            end_us: now - 95 * MIN,
            title: "Pricing page copy".into(),
            surface: "You drafted the plan names.".into(),
            beneath: "Nothing notable.".into(),
            signals: "{}".into(),
            event_count: 12,
            generated_us: now - 90 * MIN,
            model: "apple-foundation-models".into(),
        })
        .unwrap();
    store
        .put_session_note(&SessionNote {
            start_us: now - 180 * MIN,
            end_us: now - 160 * MIN,
            title: "Notes — Launch plan".into(),
            surface: "Typing in Notes (Launch plan)".into(),
            beneath: "Paused 4 min with no input in Notes.".into(),
            signals: "{}".into(),
            event_count: 9,
            generated_us: now - 150 * MIN,
            model: "measured".into(),
        })
        .unwrap();
    let mut ids = Vec::new();
    for (text, kind, confidence) in [
        (
            "Sam is redesigning the pricing page for Trailhead Bikes.",
            PropositionKind::Project,
            0.8,
        ),
        (
            "Sam writes Rust and runs tests from the terminal.",
            PropositionKind::Skill,
            0.7,
        ),
        (
            "Sam prefers short plan names over descriptive ones.",
            PropositionKind::Preference,
            0.4,
        ),
        (
            "Sam works with Priya on the checkout.",
            PropositionKind::Relationship,
            0.9,
        ),
        (
            "Sam took several tries to get the tax rounding right.",
            PropositionKind::Struggle,
            0.9,
        ),
        ("Sam is tired this afternoon.", PropositionKind::State, 0.9),
    ] {
        ids.push(
            store
                .insert_proposition(&claim(text, kind, confidence), &[], now - 10 * MIN)
                .unwrap(),
        );
    }
    ids
}

#[test]
fn the_hook_packet_carries_the_same_recent_work_and_about_you_block_as_context() {
    let (_dir, db, root, _records) = fixture_brain();
    let now = now_us();
    learn(&SqlCipherBrainStore::new(&db, &key()).unwrap(), now);
    let store = SqlCipherBrainStore::open_readonly(&db, &key()).unwrap();

    let understanding = context_understanding(&store, PDT, now, None).expect("something to tell");
    let block = render_understanding_block(&understanding);
    assert!(block.contains("\n## Recent work\n"), "{block}");
    assert!(
        block.contains("· Pricing page copy: You drafted the plan names.\n"),
        "a note with nothing notable beneath sends its surface: {block}"
    );
    assert!(
        block.contains("· Launch plan\n"),
        "a measured note sends its window title and no telemetry: {block}"
    );
    assert!(
        !block.contains("Paused") && !block.contains("Nothing notable."),
        "{block}"
    );
    assert!(block.contains("- Sam is redesigning the pricing page for Trailhead Bikes."));
    assert!(block.contains("- Sam writes Rust and runs tests from the terminal."));
    for never in ["short plan names", "Priya", "tax rounding", "tired"] {
        assert!(
            !block.contains(never),
            "{never} is not sent unasked: {block}"
        );
    }

    // The hook: after the title and "Last worked" lines, before every section.
    let packet =
        compile_handoff_with_block(&store, &root.join("hippocampus"), 600, &clock(now), &block)
            .unwrap();
    let text = &packet.packet;
    assert!(text.starts_with(&format!("{DISCLAIMER}\n\n")), "{text}");
    let last_worked = text.find("\nLast worked ").expect("last worked line");
    let recent = text
        .find("\n## Recent work\n")
        .expect("recent work in the hook");
    let first_section = text
        .find("\n## Where you stopped\n")
        .expect("first section");
    assert!(last_worked < recent && recent < first_section, "{text}");
    assert!(
        text.contains(&block),
        "the hook sends the block as context renders it"
    );

    // `context` renders the same block from the same lines.
    let mut context = compile_context_packet(
        None,
        now,
        ContextBudget::new(200, 6),
        ContextSources::default(),
    );
    context.understanding = Some(understanding);
    assert!(render_context_packet_markdown(&context).contains(&block));

    // A project with no memory still starts with the block, after the safety line.
    let envelope = no_project_memory_envelope(&block);
    assert!(envelope.contains("Recent work") && envelope.contains("Local memory reference only."));
    assert_eq!(no_project_memory_envelope(""), fallback_envelope());
}

#[test]
#[allow(clippy::too_many_lines)] // one packet, compared with the page field by field
fn the_page_shows_everything_context_sends() {
    let (_dir, db, _root, _records) = fixture_brain();
    let now = now_us();
    let ids = learn(&SqlCipherBrainStore::new(&db, &key()).unwrap(), now);
    let store = SqlCipherBrainStore::open_readonly(&db, &key()).unwrap();

    let page = model_page(&store, PDT, now).unwrap();
    let listed = |key: &str| -> Vec<i64> {
        page[key]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["id"].as_i64().unwrap())
            .collect()
    };
    let shared: HashSet<i64> = listed("shared").into_iter().collect();
    for focus in [
        None,
        Some("pricing page"),
        Some("rust terminal"),
        Some("Priya checkout"),
        Some("tired"),
    ] {
        for p in about_you(&store, now, focus) {
            assert!(
                shared.contains(&p.id),
                "{} is sent with focus {focus:?} but not on the page",
                p.text
            );
        }
    }
    assert_eq!(
        listed("shared"),
        vec![ids[0], ids[1]],
        "working on, then skills"
    );
    assert_eq!(
        listed("kept_back"),
        vec![ids[2], ids[3]],
        "a guess and a person can be looked up"
    );
    let everywhere: Vec<i64> = ["shared", "kept_back", "not_seen_lately"]
        .iter()
        .flat_map(|k| listed(k))
        .collect();
    assert!(
        !everywhere.contains(&ids[4]),
        "a struggle seen once is not shown"
    );
    assert!(
        !everywhere.contains(&ids[5]),
        "how the person is right now is never shown"
    );
    let text = page.to_string();
    assert!(
        !text.contains("confidence") && !text.contains('%'),
        "no scores on the page"
    );
    for item in page["shared"].as_array().unwrap() {
        assert_eq!(item["basis"], "seen_once");
        assert_eq!(
            item["group"],
            if item["kind"] == "project" {
                "working_on"
            } else {
                "skills"
            }
        );
    }

    // The page's recent work is what the Overview says a new session gets.
    let day = overview::overview(&store, None, PDT, now, &OverviewEnv::default()).unwrap();
    let day = serde_json::to_value(day).unwrap();
    assert_eq!(page["recent_work"], day["ai_knows"]["recent_work"]);
    assert_eq!(page["recent_work"].as_array().unwrap().len(), 2);
    assert_eq!(
        day["ai_knows"]["about_you"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| a["id"].as_i64().unwrap())
            .collect::<Vec<_>>(),
        vec![ids[0], ids[1]]
    );
    assert_eq!(
        page["recent_work"][0]["template"],
        "{start}–{end} · Pricing page copy: You drafted the plan names."
    );
    assert!(page["recent_work"][0]["times"]["start"].is_u64());

    // `mci_user_model` serves what the page shows, and nothing else.
    let served = query::run(
        &std::sync::Arc::new(store),
        PDT,
        now,
        &query::UnderstandingQuery::UserModel {
            query: None,
            limit: None,
            page: None,
        },
    )
    .unwrap();
    let served: HashSet<i64> = served["propositions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["id"].as_i64().unwrap())
        .collect();
    assert_eq!(
        served,
        [ids[0], ids[1], ids[2], ids[3]].into_iter().collect()
    );
}
