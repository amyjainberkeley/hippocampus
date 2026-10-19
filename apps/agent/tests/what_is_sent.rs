//! What a connected AI is told without asking: one decision, used by the
//! context packet, the session hook, the Overview's "Your AI already knows"
//! and the You page. Synthetic memory only.

mod handoff_fixture;

use std::collections::HashSet;

use handoff_fixture::{clock, fixture_brain, key, put_screen, ts_us};
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

const DAY: u64 = 24 * 60 * MIN;

/// A window as the store keeps it: the header, what the window said, and,
/// after the separator, its labels (`mci_brain::reading`).
fn window(app: &str, title: &str, said: &str, labels: &str) -> String {
    format!("[app={app} | title={title} | url=? | ts=2026-09-24T16:00:00.000Z]\n{said}\n\n\u{1e}\n{labels}")
}

/// Moments of one window at `times`, all saying the same.
fn moments(
    store: &SqlCipherBrainStore,
    times: &[u64],
    app: &str,
    title: &str,
    said: &str,
    labels: &str,
) -> Vec<i64> {
    times
        .iter()
        .map(|ts| {
            i64::try_from(put_screen(
                store,
                *ts,
                app,
                title,
                &window(app, title, said, labels),
            ))
            .unwrap()
        })
        .collect()
}

/// A mail client's inbox on three days: other people's messages, under the
/// account's label "Northwind Travel" (the shape of audit product-4).
fn inbox(store: &SqlCipherBrainStore, now: u64) -> Vec<i64> {
    moments(
        store,
        &[now - 3 * DAY, now - 2 * DAY, now - DAY],
        "com.apple.mail",
        "Inbox – Northwind Travel",
        "Harbor Ferries: Spring timetable, Thursday sailings from the north pier\n\
         Priya Shah: Re: checkout tax rounding\n\
         Trailhead Bikes: Your order has shipped",
        "Mailboxes\nInbox\nNorthwind Travel\nDrafts\nSent",
    )
}

/// A model note two hours ago whose `beneath` says nothing, and a measured
/// note before it.
fn note_sessions(store: &SqlCipherBrainStore, now: u64) {
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
}

/// Pricing notes on two days, a terminal on three and a checkout file on
/// two, each saying what one line claims.
fn work(store: &SqlCipherBrainStore, now: u64) -> (Vec<i64>, Vec<i64>, Vec<i64>) {
    let pricing = moments(
        store,
        &[now - 2 * DAY, now - 2 * DAY + 2 * MIN, now - DAY],
        "com.apple.Notes",
        "Pricing page",
        "Trailhead Bikes pricing page: redesigning the plan table. Team $18 a seat.",
        "Notes\nPricing page",
    );
    let terminal = moments(
        store,
        &[
            now - 3 * DAY,
            now - 2 * DAY + 30 * MIN,
            now - DAY + 30 * MIN,
        ],
        "com.apple.Terminal",
        "trailhead — zsh",
        "$ cat rust-toolchain.toml\nchannel = \"1.89\"\n$ cargo test\ntest result: ok. 12 passed",
        "zsh",
    );
    let checkout = moments(
        store,
        &[now - 2 * DAY + 60 * MIN, now - 2 * DAY + 62 * MIN, now - DAY + 60 * MIN],
        "com.microsoft.VSCode",
        "checkout.rs — trailhead",
        "fn tax_rounding(cents: i64) -> i64 {\n    // Trailhead checkout: tax rounding, third try\n}",
        "EXPLORER\ncheckout.rs",
    );
    (pricing, terminal, checkout)
}

/// The lines learned about Sam, in the order returned:
/// 0. a project three moments on two days show (sent);
/// 1. a skill the terminal shows on three days (sent);
/// 2. a preference the model is unsure of (only Sam sees it);
/// 3. someone Sam works with (a relationship: only Sam sees it);
/// 4. a struggle seen once (not shown);
/// 5. how Sam is right now (never shown);
/// 6. a plan read off the inbox's label (only Sam sees it);
/// 7. a project made from the inbox's label (only Sam sees it);
/// 8. a preference Sam confirmed (sent, though the model was unsure);
/// 9. a struggle the checkout shows on two days (sent when looked up).
fn learn(store: &SqlCipherBrainStore, now: u64) -> Vec<i64> {
    note_sessions(store, now);
    let (pricing, terminal, checkout) = work(store, now);
    let mail = inbox(store, now);
    let mut ids = Vec::new();
    for (text, kind, confidence, evidence) in [
        (
            "Sam is redesigning the pricing page for Trailhead Bikes.",
            PropositionKind::Project,
            0.8,
            &pricing,
        ),
        (
            "Sam writes Rust and runs tests from the terminal.",
            PropositionKind::Skill,
            0.9,
            &terminal,
        ),
        (
            "Sam prefers short plan names over descriptive ones.",
            PropositionKind::Preference,
            0.4,
            &pricing,
        ),
        (
            "Sam works with Priya on the checkout.",
            PropositionKind::Relationship,
            0.9,
            &checkout,
        ),
        (
            "Sam took several tries to get the tax rounding right.",
            PropositionKind::Struggle,
            0.9,
            &Vec::new(),
        ),
        (
            "Sam is tired this afternoon.",
            PropositionKind::State,
            0.9,
            &Vec::new(),
        ),
        (
            "Sam is planning a trip through the Northwind Travel account.",
            PropositionKind::Goal,
            0.9,
            &mail,
        ),
        (
            "Sam is organizing the Northwind Travel inbox folders.",
            PropositionKind::Project,
            0.9,
            &mail,
        ),
        (
            "Sam keeps plan names to one word.",
            PropositionKind::Preference,
            0.4,
            &pricing,
        ),
        (
            "Sam took several tries to get the Trailhead checkout tax rounding right.",
            PropositionKind::Struggle,
            0.9,
            &checkout,
        ),
    ] {
        ids.push(
            store
                .insert_proposition(&claim(text, kind, confidence), evidence, now - 10 * MIN)
                .unwrap(),
        );
    }
    assert!(store.confirm_proposition(ids[8], now - 5 * MIN).unwrap());
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
    assert!(
        block.contains("- Sam keeps plan names to one word."),
        "confirmed: {block}"
    );
    for never in [
        "short plan names",
        "Priya",
        "tax rounding",
        "tired",
        "Northwind Travel",
        "trip",
    ] {
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

fn served(store: SqlCipherBrainStore, now: u64, topic: Option<&str>) -> HashSet<i64> {
    let served = query::run(
        &std::sync::Arc::new(store),
        PDT,
        now,
        &query::UnderstandingQuery::UserModel {
            query: topic.map(str::to_owned),
            limit: None,
            page: None,
        },
    )
    .unwrap();
    served["propositions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["id"].as_i64().unwrap())
        .collect()
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
        Some("Northwind Travel trip"),
        Some("tired"),
    ] {
        for p in about_you(&store, PDT, now, focus) {
            assert!(
                shared.contains(&p.id),
                "{} is sent with focus {focus:?} but not on the page",
                p.text
            );
        }
    }
    assert_eq!(
        listed("shared"),
        vec![ids[0], ids[8], ids[1]],
        "working on, how you work, then skills"
    );
    assert_eq!(
        listed("kept_back"),
        vec![ids[9]],
        "a struggle the checkout shows on two days can be looked up"
    );
    assert_eq!(
        listed("not_sent").into_iter().collect::<HashSet<_>>(),
        [ids[2], ids[3], ids[6], ids[7]].into_iter().collect(),
        "an unsure guess, a person and two lines made from a label: only Sam sees them"
    );
    let everywhere: Vec<i64> = ["shared", "kept_back", "not_sent", "not_seen_lately"]
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
    let basis: Vec<(&str, &str)> = page["shared"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| {
            (
                item["group"].as_str().unwrap(),
                item["basis"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        basis,
        vec![
            ("working_on", "seen_on_days"),
            ("how_you_work", "confirmed"),
            ("skills", "seen_on_days"),
        ]
    );

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
        vec![ids[8], ids[1], ids[0]],
        "the surest first: confirmed, then by confidence"
    );
    assert_eq!(
        page["recent_work"][0]["template"],
        "{start}–{end} · Pricing page copy: You drafted the plan names."
    );
    assert!(page["recent_work"][0]["times"]["start"].is_u64());

    // `mci_user_model` serves what the page says may go to AI tools, and
    // nothing else.
    assert_eq!(
        served(store, now, None),
        [ids[0], ids[1], ids[8], ids[9]].into_iter().collect()
    );
}

/// Audit product-4 and live-5: the on-device model read a mail client's
/// inbox and wrote a line about the person from the account's label. It
/// reached every AI session. Here the label is "Northwind Travel".
/// However sure the model is, and on however many days the inbox was open,
/// no wording of it goes to an AI tool unless the person confirms it.
#[test]
fn a_mailbox_label_never_becomes_a_claim_about_the_person() {
    let (_dir, db, _root, _records) = fixture_brain();
    let now = now_us();
    let ids = {
        let store = SqlCipherBrainStore::new(&db, &key()).unwrap();
        let mail = inbox(&store, now);
        [
            (
                "Sam is planning a trip through the Northwind Travel account.",
                PropositionKind::Goal,
            ),
            (
                "Sam is booking a trip with Northwind Travel.",
                PropositionKind::Goal,
            ),
            (
                "Sam is organizing the Northwind Travel inbox folders.",
                PropositionKind::Project,
            ),
        ]
        .into_iter()
        .map(|(text, kind)| {
            store
                .insert_proposition(&claim(text, kind, 1.0), &mail, now - 10 * MIN)
                .unwrap()
        })
        .collect::<Vec<_>>()
    };
    let store = SqlCipherBrainStore::open_readonly(&db, &key()).unwrap();

    // Before this rule, any of them was sent: a kind sent unasked, the
    // model sure of it, seen on three days.
    let page = model_page(&store, PDT, now).unwrap();
    for item in page["not_sent"].as_array().unwrap() {
        assert_eq!(item["basis"], "seen_on_days");
        assert_eq!(item["days_seen"], 3);
    }
    let listed = |key: &str| -> HashSet<i64> {
        page[key]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["id"].as_i64().unwrap())
            .collect()
    };
    assert_eq!(
        listed("not_sent"),
        ids.iter().copied().collect(),
        "Sam sees them on You, to confirm or forget"
    );
    assert!(listed("shared").is_empty() && listed("kept_back").is_empty());

    for focus in [None, Some("Northwind Travel"), Some("trip planning")] {
        assert!(
            about_you(&store, PDT, now, focus).is_empty(),
            "nothing about the inbox is sent with focus {focus:?}"
        );
        assert!(context_understanding(&store, PDT, now, focus).is_none_or(|u| u.about.is_empty()));
    }
    let overview = overview::overview(&store, None, PDT, now, &OverviewEnv::default()).unwrap();
    assert!(
        serde_json::to_value(overview).unwrap()["ai_knows"]["about_you"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(served(store, now, Some("Northwind Travel")).is_empty());
    assert!(served(
        SqlCipherBrainStore::open_readonly(&db, &key()).unwrap(),
        now,
        None
    )
    .is_empty());

    // Sam says the label line is right: then, and only then, it is sent.
    {
        let writer = SqlCipherBrainStore::new(&db, &key()).unwrap();
        assert!(writer.confirm_proposition(ids[2], now).unwrap());
    }
    let store = SqlCipherBrainStore::open_readonly(&db, &key()).unwrap();
    let sent: Vec<i64> = about_you(&store, PDT, now, None)
        .into_iter()
        .map(|p| p.id)
        .collect();
    assert_eq!(sent, vec![ids[2]]);
}
