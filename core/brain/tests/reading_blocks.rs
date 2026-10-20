//! A reading's text as blocks (`mci_brain::reading_blocks`, SPEC 4.2 to
//! 4.11): each kind of window gives the blocks its golden file holds;
//! nothing is invented, nothing that was read is lost, and code, terminal
//! output and tables come out byte for byte.
//!
//! Fixtures under `tests/fixtures/reading/blocks/` are synthetic windows, as
//! the store keeps them: `<kind>.old.txt` was stored before windows were
//! classified, `<kind>.new.txt` since (content, U+001E, chrome), and
//! `extension-table.page.txt` came from the browser extension. Each has its
//! blocks as `<name>.blocks.json`, their Markdown as `<name>.md` and their
//! plain text as `<name>.plain.txt`. Run with `UPDATE_READING_GOLDENS=1` to
//! write them again, then read the change.

use std::path::{Path, PathBuf};

use mci_brain::reading::{header_fields, reading};
use mci_brain::reading_blocks::{
    blocks, markdown, plain_text, Block, Item, Window, MAX_ELEMENTS, MAX_STRUCTURE_BYTES,
};
use mci_brain::redaction::ocr_secrets::contains_secret;
use mci_brain::EventSource;

const SCREEN: EventSource = EventSource::ScreenOcr;

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/reading")
}

/// The app a stored text's header names.
fn app_of(stored: &str) -> Option<&str> {
    stored
        .strip_prefix("[app=")
        .and_then(|rest| rest.split(" | ").next())
}

/// One fixture: its name, its stored text and how it was acquired.
struct Fixture {
    name: String,
    stored: String,
    source: EventSource,
}

/// Every fixture, in a fixed order: the kinds under `blocks/`, and the
/// reader's own Slack, Messages and VS Code windows.
fn all_fixtures() -> Vec<Fixture> {
    let dir = fixtures().join("blocks");
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(|entry| {
            let name = entry.unwrap().file_name().into_string().unwrap();
            // The windows, not their plain-text goldens.
            name.strip_suffix(".txt")
                .filter(|name| {
                    [".old", ".new", ".page"]
                        .iter()
                        .any(|kind| name.ends_with(kind))
                })
                .map(str::to_owned)
        })
        .collect();
    names.sort();
    let mut out: Vec<Fixture> = names
        .into_iter()
        .map(|name| Fixture {
            stored: std::fs::read_to_string(dir.join(format!("{name}.txt"))).unwrap(),
            // `<name>.page` came from the browser extension.
            source: if Path::new(&name)
                .extension()
                .is_some_and(|extension| extension == "page")
            {
                EventSource::BrowserPage
            } else {
                SCREEN
            },
            name,
        })
        .collect();
    // The reader's fixtures: older ones are stored without their header.
    for (name, file, app, title) in [
        (
            "slack.new",
            "chat.stored.txt",
            "com.tinyspeck.slackmacgap",
            "",
        ),
        (
            "slack.old",
            "chat.old.txt",
            "com.tinyspeck.slackmacgap",
            "launch-plan (Channel) - Northwind Studio - Slack",
        ),
        (
            "messages.new",
            "messages.stored.txt",
            "com.apple.MobileSMS",
            "",
        ),
        (
            "vscode.new",
            "editor.stored.txt",
            "com.microsoft.VSCode",
            "",
        ),
        (
            "vscode.old",
            "editor.old.txt",
            "com.microsoft.VSCode",
            "retention_worker.rs \u{2014} hippocampus",
        ),
    ] {
        let text = std::fs::read_to_string(fixtures().join(file)).unwrap();
        let stored = if text.starts_with("[app=") {
            text
        } else {
            format!("[app={app} | title={title} | url=? | ts=2026-10-12T14:02:00.000Z]\n{text}")
        };
        out.push(Fixture {
            name: name.to_owned(),
            stored,
            source: SCREEN,
        });
    }
    out
}

/// `main` of a fixture, read as the FFI reads it, and the window it came
/// from.
fn read(fixture: &Fixture) -> (String, Option<&str>, Option<&str>, Option<&str>) {
    let app = app_of(&fixture.stored);
    let (title, url) = header_fields(&fixture.stored);
    let main = reading(&fixture.stored, fixture.source, app, None).main;
    (main, app, title, url)
}

fn blocks_of(fixture: &Fixture) -> (String, Vec<Block>) {
    let (main, app, title, url) = read(fixture);
    let made = blocks(&main, &Window { app, title, url }, fixture.source);
    (main, made)
}

/// Compares `actual` with the golden file, or writes it when asked to.
fn golden(path: &Path, actual: &str) {
    if std::env::var_os("UPDATE_READING_GOLDENS").is_some() {
        std::fs::write(path, actual).unwrap();
        return;
    }
    let expected = std::fs::read_to_string(path).unwrap_or_else(|e| {
        panic!(
            "{}: {e} (run with UPDATE_READING_GOLDENS=1)",
            path.display()
        )
    });
    assert_eq!(actual, expected, "{} differs", path.display());
}

fn words(text: &str) -> Vec<&str> {
    text.split_whitespace().collect()
}

// ---------------------------------------------------------------------------
// Goldens, kind by kind
// ---------------------------------------------------------------------------

#[test]
fn every_kind_of_window_gives_its_golden_blocks_and_markdown() {
    let all = all_fixtures();
    assert!(all.len() >= 26, "{} fixtures", all.len());
    for fixture in &all {
        let (_, made) = blocks_of(fixture);
        assert!(!made.is_empty(), "{}", fixture.name);
        let dir = fixtures().join("blocks");
        golden(
            &dir.join(format!("{}.blocks.json", fixture.name)),
            &(serde_json::to_string_pretty(&made).unwrap() + "\n"),
        );
        golden(
            &dir.join(format!("{}.md", fixture.name)),
            &(markdown(&made) + "\n"),
        );
        // What Copy Text copies; the window's own copy is checked against
        // it (ReadingBlocksDecodingTests).
        golden(
            &dir.join(format!("{}.plain.txt", fixture.name)),
            &(plain_text(&made) + "\n"),
        );
    }
}

/// The kinds of block a fixture's reading holds.
fn kinds(made: &[Block]) -> Vec<&'static str> {
    made.iter()
        .map(|block| match block {
            Block::Label { .. } => "label",
            Block::Heading { level: 1, .. } => "h1",
            Block::Heading { .. } => "h2",
            Block::Byline { .. } => "byline",
            Block::Paragraph { .. } => "paragraph",
            Block::List { .. } => "list",
            Block::Code { .. } => "code",
            Block::Terminal { .. } => "terminal",
            Block::Table { .. } => "table",
            Block::Lines { .. } => "lines",
            Block::Turn { .. } => "turn",
            Block::Quote { .. } => "quote",
            Block::Meta { .. } => "meta",
        })
        .collect()
}

fn fixture(name: &str) -> Fixture {
    all_fixtures()
        .into_iter()
        .find(|fixture| fixture.name == name)
        .unwrap_or_else(|| panic!("no fixture {name}"))
}

#[test]
fn the_article_reads_as_the_spec_draws_it() {
    // SPEC 4.10, old and new.
    for name in ["article.old", "article.new"] {
        let (_, made) = blocks_of(&fixture(name));
        assert_eq!(
            kinds(&made),
            [
                "label",
                "h1",
                "paragraph",
                "byline",
                "paragraph",
                "paragraph",
                "code",
                "paragraph",
                "paragraph"
            ],
            "{name}"
        );
        assert_eq!(
            made[6],
            Block::Code {
                text: "round_half_even(2.5)   // 2.0\nround_half_even(3.5)   // 4.0".into()
            },
            "{name}: code byte for byte"
        );
    }
}

#[test]
fn a_notes_checklist_is_a_list_of_checkboxes() {
    for name in ["notes-checklist.old", "notes-checklist.new"] {
        let (_, made) = blocks_of(&fixture(name));
        let Some(Block::List { items }) = made
            .iter()
            .find(|block| matches!(block, Block::List { .. }))
        else {
            panic!("{name}: no list in {made:?}");
        };
        let ticked: Vec<Option<bool>> = items.iter().map(|item| item.checked).collect();
        assert_eq!(
            ticked,
            [
                Some(true),
                Some(true),
                Some(false),
                Some(false),
                Some(false)
            ],
            "{name}"
        );
        assert!(
            matches!(
                made[0],
                Block::Heading { level: 1, .. } | Block::Byline { .. }
            ),
            "{name}: {made:?}"
        );
    }
}

#[test]
fn a_document_has_its_headings_lists_and_byline() {
    for name in ["google-docs.old", "google-docs.new"] {
        let (_, made) = blocks_of(&fixture(name));
        let found = kinds(&made);
        assert_eq!(
            &found[..5],
            ["h1", "byline", "h2", "list", "h2"],
            "{name}: {made:?}"
        );
    }
}

#[test]
fn mail_has_its_subject_header_lines_body_and_signature() {
    for name in ["gmail.old", "gmail.new"] {
        let (_, made) = blocks_of(&fixture(name));
        assert_eq!(
            made[..3],
            [
                Block::Heading {
                    level: 1,
                    text: "Invoice 1042 from Northwind Supplies".into()
                },
                Block::Meta {
                    text: "Dana Whitfield <dana@northwind.example>".into()
                },
                Block::Meta {
                    text: "to me".into()
                },
            ],
            "{name}"
        );
        assert_eq!(
            made.last(),
            Some(&Block::Meta {
                text: "--\nDana Whitfield\nNorthwind Supplies".into()
            }),
            "{name}: the signature"
        );
    }
    for name in ["apple-mail-quote.old", "apple-mail-quote.new"] {
        let (_, made) = blocks_of(&fixture(name));
        let Some(Block::Quote { text }) = made.last() else {
            panic!("{name}: {made:?}");
        };
        assert!(
            text.starts_with("On Oct 11, 2026, at 6:40 PM, Sam Lee"),
            "{name}: {text}"
        );
        assert!(text.lines().count() > 6, "{name}: long enough to close");
    }
}

#[test]
fn a_chat_reads_as_turns_and_messages_as_lines_of_their_own() {
    let (_, made) = blocks_of(&fixture("slack.new"));
    let turns: Vec<(&str, &str)> = made
        .iter()
        .filter_map(|block| match block {
            Block::Turn { speaker, time, .. } => Some((speaker.as_str(), time.as_str())),
            _ => None,
        })
        .collect();
    assert_eq!(
        turns,
        [
            ("Maya Chen", "10:42 AM"),
            ("Ravi Patel", "10:47 AM"),
            ("Jonas Weber", "11:05 AM"),
            ("Maya Chen", "11:09 AM"),
            ("Ravi Patel", "11:12 AM")
        ]
    );
    // Two messages of one turn stay two lines.
    assert!(made.iter().any(|block| matches!(block, Block::Turn { text, .. }
        if text == "Pushed the new onboarding flow to staging. The permissions step is now one screen.\nCan someone check the copy on the screen recording prompt before 3 PM?")));
    // Messages has no speaker lines: a paragraph each, nothing attributed.
    let (_, made) = blocks_of(&fixture("messages.new"));
    assert_eq!(kinds(&made), ["paragraph", "paragraph", "paragraph"]);
}

#[test]
fn ai_chats_read_as_documents_with_their_code() {
    for name in ["chatgpt.old", "chatgpt.new", "claude.old", "claude.new"] {
        let (_, made) = blocks_of(&fixture(name));
        assert!(
            !made.iter().any(|block| matches!(block, Block::Turn { .. })),
            "{name}: no speaker is inferred"
        );
        assert!(
            made.iter().any(|block| matches!(block, Block::Code { .. })),
            "{name}: {made:?}"
        );
    }
    let (_, made) = blocks_of(&fixture("claude.new"));
    assert!(made.iter().any(|block| matches!(block, Block::List { items } if items.len() == 2 && items[0].marker == "1.")));
}

#[test]
fn a_terminal_is_one_block_byte_for_byte_with_its_prompts_marked() {
    for name in ["terminal-assistant.old", "terminal-assistant.new"] {
        let (main, made) = blocks_of(&fixture(name));
        assert_eq!(
            made,
            [Block::Terminal {
                text: main.clone(),
                prompts: vec![0]
            }],
            "{name}"
        );
        // The assistant's status line and empty box stay out of it.
        assert!(!main.contains("accept edits"), "{name}");
    }
}

#[test]
fn code_in_an_editor_is_one_block_with_its_blank_lines() {
    let (main, made) = blocks_of(&fixture("vscode.new"));
    let Block::Code { text } = &made[0] else {
        panic!("{made:?}");
    };
    assert!(
        text.starts_with("use std::time::Duration;\n\n/// Delete events")
            && text.ends_with("    Ok(deleted)\n}"),
        "{text}"
    );
    assert!(main.contains(text.as_str()), "byte for byte");
    // The assistant's panel beside it reads as text, and its terminal as code.
    assert!(made.iter().any(
        |block| matches!(block, Block::Paragraph { text } if text.starts_with("So a long sweep"))
    ));
    assert!(matches!(made.last(), Some(Block::Code { text }) if text.starts_with("$ cargo test")));
}

#[test]
fn a_sheet_reads_as_rows_and_extension_text_as_a_table() {
    for name in ["numbers.old", "numbers.new"] {
        let (_, made) = blocks_of(&fixture(name));
        assert!(
            made.iter().any(
                |block| matches!(block, Block::Lines { table: true, lines } if lines.len() >= 4)
            ),
            "{name}: {made:?}"
        );
    }
    let (_, made) = blocks_of(&fixture("extension-table.page"));
    assert!(made.contains(&Block::Table {
        rows: vec![
            vec!["Plan".into(), "Price".into(), "Seats".into()],
            vec!["Ride".into(), "$0".into(), "1".into()],
            vec!["Tour".into(), "$18".into(), "5".into()],
            vec!["Club".into(), "$29".into(), "25".into()],
        ],
        numeric: vec![false, true, true],
    }));
}

// ---------------------------------------------------------------------------
// Counterexamples: what must stay apart (SPEC 4.11)
// ---------------------------------------------------------------------------

fn notes(main: &str) -> Vec<Block> {
    blocks(
        main,
        &Window {
            app: Some("com.apple.Notes"),
            title: Some("Scratch"),
            url: None,
        },
        SCREEN,
    )
}

#[test]
fn short_lines_stay_lines_of_their_own() {
    for main in [
        "Northwind Studio\n123 Market Street\nSan Francisco, CA 94103",
        "Breakfast\nLunch\nDinner",
        "Rain on the window and\nWind in the trees\nLight on the water",
        "Best,\nDana",
    ] {
        assert_eq!(
            notes(main),
            [Block::Lines {
                lines: main.lines().map(str::to_owned).collect(),
                table: false
            }],
            "{main}"
        );
    }
}

#[test]
fn list_items_stay_items_and_keep_their_markers() {
    let made = notes("1. Ship the rounding fix\n2. Update the changelog\n3) Tell the beta group");
    assert_eq!(
        made,
        [Block::List {
            items: vec![
                Item {
                    marker: "1.".into(),
                    text: "Ship the rounding fix".into(),
                    depth: 0,
                    checked: None
                },
                Item {
                    marker: "2.".into(),
                    text: "Update the changelog".into(),
                    depth: 0,
                    checked: None
                },
                Item {
                    marker: "3)".into(),
                    text: "Tell the beta group".into(),
                    depth: 0,
                    checked: None
                },
            ]
        }]
    );
    let made = notes("- [x] Rounding fix merged\n- [ ] Gift card copy reviewed\n    a wrapped line under it\n  - nested item");
    let Block::List { items } = &made[0] else {
        panic!("{made:?}");
    };
    assert_eq!(items[0].checked, Some(true));
    assert_eq!(items[1].checked, Some(false));
    assert_eq!(
        items[1].text,
        "Gift card copy reviewed\na wrapped line under it"
    );
    assert_eq!((items[2].depth, items[2].marker.as_str()), (1, "-"));
}

#[test]
fn two_messages_from_one_person_stay_two_lines() {
    let made = blocks(
        "Jordan Lee 2:14 PM\nstaging is green\nshipping the rounding fix at 4",
        &Window {
            app: Some("com.tinyspeck.slackmacgap"),
            title: None,
            url: None,
        },
        SCREEN,
    );
    assert_eq!(
        made,
        [Block::Turn {
            speaker: "Jordan Lee".into(),
            time: "2:14 PM".into(),
            text: "staging is green\nshipping the rounding fix at 4".into()
        }]
    );
    // A name with "Today at" before the time.
    let made = blocks(
        "Priya Raman Today at 2:15 PM\nI\u{2019}ll update the changelog",
        &Window {
            app: Some("com.hnc.Discord"),
            title: None,
            url: None,
        },
        SCREEN,
    );
    assert!(
        matches!(&made[0], Block::Turn { speaker, time, .. } if speaker == "Priya Raman" && time == "Today at 2:15 PM"),
        "{made:?}"
    );
}

#[test]
fn a_sentence_is_never_code_and_code_ending_in_a_word_is_never_prose() {
    let made = notes(
        "Thanks for sending this over. The October invoice is attached; the amount due is $1,240.00.\nlet me know if the purchase order number changes (it has not so far).",
    );
    assert!(
        made.iter()
            .all(|block| matches!(block, Block::Paragraph { .. })),
        "{made:?}"
    );
    let made = notes("if total > limit and\n    return round_half_even(total) as\n}");
    assert!(matches!(made[..], [Block::Code { .. }]), "{made:?}");
}

#[test]
fn a_cjk_paragraph_next_to_english_stays_its_own() {
    let main = "\u{6771}\u{4eac}\u{306f}\u{65e5}\u{672c}\u{306e}\u{9996}\u{90fd}\u{3067}\u{3059}\u{3002}\nTokyo is the capital of Japan.";
    let made = notes(main);
    let plain = plain_text(&made);
    assert!(
        plain
            .lines()
            .all(|line| !(line.contains('\u{6771}') && line.contains("Tokyo"))),
        "{made:?}"
    );
}

#[test]
fn a_heading_comes_only_from_the_window_or_its_shape_and_place() {
    let window = Window {
        app: Some("com.google.Chrome"),
        title: Some("Seat-based pricing: the pros and cons - SaaS Guide"),
        url: Some("https://saasguide.example/seats"),
    };
    let made = blocks(
        "Seat-based pricing: the pros and cons\nSaaS Guide \u{b7} 5 min read\nWhen tiers win\nTiers suit products where usage, not headcount, drives cost to serve.\nThanks!\nShare this",
        &window,
        EventSource::BrowserPage,
    );
    assert_eq!(
        kinds(&made),
        ["h1", "byline", "h2", "paragraph", "lines"],
        "{made:?}"
    );
    // A generic title names nothing.
    let made = blocks(
        "Notes\nGroceries for the week",
        &Window {
            app: Some("com.apple.Notes"),
            title: Some("Notes"),
            url: None,
        },
        SCREEN,
    );
    assert!(!kinds(&made).contains(&"h1"), "{made:?}");
}

// ---------------------------------------------------------------------------
// Markdown and Copy Text (SPEC 4.7)
// ---------------------------------------------------------------------------

#[test]
fn markdown_marks_structure_and_plain_text_adds_no_symbol() {
    let made = vec![
        Block::Label {
            text: "MONEY & ROUNDING".into(),
        },
        Block::Heading {
            level: 1,
            text: "Rounding half to even".into(),
        },
        Block::Paragraph {
            text: "Why banker\u{2019}s rounding keeps order totals from drifting by a cent".into(),
        },
        Block::Byline {
            text: "Priya Raman \u{b7} Oct 12, 2026 \u{b7} 6 min read".into(),
        },
        Block::Paragraph {
            text: "Round half up looks fair.".into(),
        },
        Block::Heading {
            level: 2,
            text: "Ties".into(),
        },
        Block::List {
            items: vec![Item {
                marker: "\u{2022}".into(),
                text: "Half go up".into(),
                depth: 0,
                checked: None,
            }],
        },
        Block::Code {
            text: "round_half_even(2.5)   // 2.0".into(),
        },
        Block::Turn {
            speaker: "Jordan Lee".into(),
            time: "2:14 PM".into(),
            text: "staging is green".into(),
        },
        Block::Quote {
            text: "On Oct 3, 2026, at 9:14 AM, Sam wrote:\n> looks right".into(),
        },
    ];
    assert_eq!(
        markdown(&made),
        "# Rounding half to even
Why banker\u{2019}s rounding keeps order totals from drifting by a cent
Priya Raman \u{b7} Oct 12, 2026 \u{b7} 6 min read

Round half up looks fair.

## Ties

\u{2022} Half go up

```
round_half_even(2.5)   // 2.0
```

**Jordan Lee** 2:14 PM
staging is green

> On Oct 3, 2026, at 9:14 AM, Sam wrote:
> looks right"
    );
    assert_eq!(
        plain_text(&made),
        "MONEY & ROUNDING
Rounding half to even
Why banker\u{2019}s rounding keeps order totals from drifting by a cent
Priya Raman \u{b7} Oct 12, 2026 \u{b7} 6 min read

Round half up looks fair.

Ties

\u{2022} Half go up

round_half_even(2.5)   // 2.0

Jordan Lee 2:14 PM
staging is green

On Oct 3, 2026, at 9:14 AM, Sam wrote:
> looks right"
    );
}

#[test]
fn a_code_fence_is_longer_than_any_run_of_backticks_in_the_code() {
    let made = [Block::Code {
        text: "```rust\nlet x = 1;\n```".into(),
    }];
    assert_eq!(markdown(&made), "````\n```rust\nlet x = 1;\n```\n````");
}

#[test]
fn a_table_is_a_pipe_table_with_numbers_to_the_right() {
    let made = [Block::Table {
        rows: vec![
            vec!["Plan".into(), "Price".into()],
            vec!["Ride | Tour".into(), "$18".into()],
        ],
        numeric: vec![false, true],
    }];
    assert_eq!(
        markdown(&made),
        "| Plan | Price |\n| --- | ---: |\n| Ride \\| Tour | $18 |"
    );
    assert_eq!(plain_text(&made), "Plan\tPrice\nRide | Tour\t$18");
}

// ---------------------------------------------------------------------------
// Properties (SPEC 4.11)
// ---------------------------------------------------------------------------

/// A small deterministic generator, so property cases repeat exactly.
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        self.0 >> 33
    }

    fn pick<'a>(&mut self, items: &[&'a str]) -> &'a str {
        items[usize::try_from(self.next() % items.len() as u64).unwrap()]
    }
}

/// Lines of every shape the rules tell apart, in any order.
const SHAPES: &[&str] = &[
    "MONEY & ROUNDING",
    "Rounding half to even",
    "Priya Raman \u{b7} Oct 12, 2026 \u{b7} 6 min read",
    "Round half up looks fair, but every tie goes the same way, and over thousands of orders the books drift.",
    "Goals",
    "\u{2022} Ship the rounding fix",
    "- [x] Changelog updated",
    "  a wrapped line under an item",
    "round_half_even(2.5)   // 2.0",
    "    let tax = subtotal * TAX_RATE;",
    "}",
    "dev@studio trailhead-shop % cargo test tax",
    "Jordan Lee 2:14 PM",
    "staging is green",
    "On Oct 3, 2026, at 9:14 AM, Sam wrote:",
    "> looks right",
    "--",
    "Plan\tPrice\tSeats",
    "Ride\t$0\t1",
    "1042 Northwind Supplies $1,240.00 31",
    "\u{6771}\u{4eac}\u{306f}\u{65e5}\u{672c}\u{306e}\u{9996}\u{90fd}\u{3067}\u{3059}\u{3002}",
    "Tokyo is the capital of Japan.",
    "",
    "",
];

const APPS: &[(&str, &str)] = &[
    ("com.google.Chrome", "https://devnotes.example/rounding"),
    ("com.apple.Notes", ""),
    ("com.apple.mail", ""),
    ("com.tinyspeck.slackmacgap", ""),
    ("com.openai.chat", ""),
    ("com.apple.Terminal", ""),
    ("com.microsoft.VSCode", ""),
    ("com.apple.iWork.Numbers", ""),
];

/// A made-up `main` of `lines` lines, and the window it is read in.
fn random_main(rng: &mut Lcg, lines: usize) -> (String, Window<'static>) {
    let main: Vec<&str> = (0..lines).map(|_| rng.pick(SHAPES)).collect();
    let main = main.join("\n").trim().to_owned();
    let (app, url) = APPS[usize::try_from(rng.next() % APPS.len() as u64).unwrap()];
    (
        main,
        Window {
            app: Some(app),
            title: Some("Rounding half to even \u{b7} Dev Notes"),
            url: (!url.is_empty()).then_some(url),
        },
    )
}

/// Every reading to check the properties on: the fixtures, and made-up
/// ones of every shape.
fn readings() -> Vec<(String, Window<'static>, EventSource, String)> {
    let mut out = Vec::new();
    for fixture in all_fixtures() {
        let (main, app, title, url) = read(&fixture);
        let window = Window {
            app: app.map(|app| &*Box::leak(app.to_owned().into_boxed_str())),
            title: title.map(|title| &*Box::leak(title.to_owned().into_boxed_str())),
            url: url.map(|url| &*Box::leak(url.to_owned().into_boxed_str())),
        };
        out.push((main, window, fixture.source, fixture.name.clone()));
    }
    let mut rng = Lcg(7);
    for case in 0..400 {
        let (main, window) = random_main(&mut rng, 1 + (case % 24));
        out.push((main, window, SCREEN, format!("random {case}")));
    }
    out
}

#[test]
fn no_block_holds_text_that_was_not_read_and_none_is_lost() {
    for (main, window, source, name) in readings() {
        let made = blocks(&main, &window, source);
        let plain = plain_text(&made);
        assert_eq!(words(&plain), words(&main), "{name}");
        if main.trim().is_empty() {
            assert!(made.is_empty(), "{name}");
        }
    }
}

#[test]
fn code_terminal_and_tables_come_out_byte_for_byte() {
    for (main, window, source, name) in readings() {
        for block in blocks(&main, &window, source) {
            match &block {
                Block::Code { text } | Block::Terminal { text, .. } => {
                    assert!(main.contains(text.as_str()), "{name}: {text:?}");
                }
                Block::Table { .. } | Block::Lines { table: true, .. } => {
                    let plain = block.plain();
                    assert!(main.contains(&plain), "{name}: {plain:?}");
                }
                _ => {}
            }
        }
    }
}

#[test]
fn the_same_reading_always_gives_the_same_blocks() {
    for (main, window, source, name) in readings() {
        let first = blocks(&main, &window, source);
        let second = blocks(&main, &window, source);
        assert_eq!(first, second, "{name}");
        assert_eq!(markdown(&first), markdown(&second), "{name}");
    }
}

#[test]
fn markdown_keeps_every_word_but_a_label_in_order() {
    for (main, window, source, name) in readings() {
        let made = blocks(&main, &window, source);
        let shown: Vec<Block> = made
            .iter()
            .filter(|block| !matches!(block, Block::Label { .. }))
            .cloned()
            .collect();
        let read: Vec<String> = words(&plain_text(&shown))
            .into_iter()
            .map(|word| {
                word.trim_matches(|ch: char| matches!(ch, '*' | '#' | '>' | '`' | '|' | '\\'))
                    .to_owned()
            })
            .filter(|word| !word.is_empty() && word != "---" && word != "---:")
            .collect();
        let marked: Vec<String> = words(&markdown(&made))
            .into_iter()
            .map(|word| {
                word.trim_matches(|ch: char| matches!(ch, '*' | '#' | '>' | '`' | '|' | '\\'))
                    .to_owned()
            })
            .filter(|word| !word.is_empty() && word != "---" && word != "---:")
            .collect();
        assert_eq!(marked, read, "{name}");
    }
}

#[test]
fn no_secret_appears_in_blocks_markdown_or_plain_text_that_the_reading_lacks() {
    // The shared corpus, every secret split across a line break in every
    // kind of window: what the reading kept apart stays apart.
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures/ocr-secret-corpus.json");
    let corpus: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let mut checked = 0usize;
    for case in corpus["cases"].as_array().unwrap() {
        // A case gives its `text`, or `parts` to join.
        let joined: String = case["parts"].as_array().map_or_else(String::new, |parts| {
            parts.iter().map(|part| part.as_str().unwrap()).collect()
        });
        let secret = case["text"].as_str().unwrap_or(&joined);
        for cut in (1..secret.len()).filter(|&at| secret.is_char_boundary(at)) {
            let main = format!(
                "Round half up looks fair, but every tie goes the same way, ending {}\n{} and the rest of it",
                &secret[..cut],
                &secret[cut..]
            );
            if contains_secret(&main) {
                continue;
            }
            for &(app, url) in APPS {
                let window = Window {
                    app: Some(app),
                    title: None,
                    url: (!url.is_empty()).then_some(url),
                };
                let made = blocks(&main, &window, SCREEN);
                checked += 1;
                assert!(!contains_secret(&markdown(&made)), "{app}: {main:?}");
                assert!(!contains_secret(&plain_text(&made)), "{app}: {main:?}");
                for block in &made {
                    assert!(!contains_secret(&block.plain()), "{app}: {block:?}");
                }
            }
        }
    }
    assert!(checked > 1_000, "{checked}");
}

#[test]
fn the_blocks_json_stays_within_the_windows_bound() {
    // The most elements of each kind a 129 KiB reading could hold: short
    // lines, list items, cells, prompts, speaker lines.
    let cap = 129 * 1024;
    let fill = |line: &str| {
        let mut out = String::new();
        while out.len() + line.len() < cap {
            out.push_str(line);
        }
        out
    };
    for (app, main) in [
        ("com.apple.Notes", fill("a\n")),
        ("com.apple.Notes", fill("\u{2022} a\n")),
        ("com.apple.Notes", fill("a b\n\n")),
        ("com.apple.Notes", fill("Goals\n")),
        ("com.apple.iWork.Numbers", fill("1\t2\t3\t4\t5\t6\t7\t8\n")),
        ("com.apple.Terminal", fill("$ a\n")),
        ("com.tinyspeck.slackmacgap", fill("Al 1:00 PM\n")),
        ("com.apple.mail", fill("> a\n")),
        ("com.apple.Notes", fill("\u{1}\"\\\n")),
    ] {
        let made = blocks(
            &main,
            &Window {
                app: Some(app),
                title: None,
                url: None,
            },
            SCREEN,
        );
        let json = serde_json::to_vec(&made).unwrap();
        let text = serde_json::to_vec(&main).unwrap();
        assert!(
            json.len() <= text.len() + MAX_STRUCTURE_BYTES,
            "{app}: {} bytes of JSON for {} of text",
            json.len(),
            text.len()
        );
        let elements: usize = made
            .iter()
            .map(|block| match block {
                Block::List { items } => 1 + items.len(),
                Block::Lines { lines, .. } => 1 + lines.len(),
                Block::Table { rows, numeric } => {
                    1 + rows.len() + rows.iter().map(Vec::len).sum::<usize>() + numeric.len()
                }
                Block::Terminal { prompts, .. } => 1 + prompts.len(),
                _ => 1,
            })
            .sum();
        assert!(elements <= MAX_ELEMENTS + 1, "{app}: {elements}");
        assert_eq!(
            words(&plain_text(&made)),
            words(&main),
            "{app}: nothing lost"
        );
    }
}
