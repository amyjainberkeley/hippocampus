//! The reader: stored text in, readable text out (`mci_brain::reading`).
//!
//! Fixtures under `tests/fixtures/reading/` are synthetic windows:
//! - `<name>.old.txt` is text the shipping assembler stored before windows
//!   were classified (copied from the realistic mock windows), and
//!   `<name>.old.main.txt` is its reading;
//! - `<name>.stored.txt` is a classified window as the store keeps it
//!   (header, content, U+001E separator, chrome), and `<name>.main.txt` and
//!   `<name>.rest.txt` are its reading.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use mci_brain::reading::{
    body, excerpt, reading, reading_prefix, screen_reading, ExcerptQuery, Reading,
    CHROME_SEPARATOR, VISIBLE_OCR_SEPARATOR,
};
use mci_brain::redaction::ocr_secrets::{contains_secret, PATTERNS};
use mci_brain::EventSource;

const SCREEN: EventSource = EventSource::ScreenOcr;
const VSCODE: Option<&str> = Some("com.microsoft.VSCode");
const NOTES: Option<&str> = Some("com.apple.Notes");
const TERMINAL: Option<&str> = Some("com.apple.Terminal");
const SLACK: Option<&str> = Some("com.tinyspeck.slackmacgap");

fn fixture(name: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/reading")
        .join(name);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn header(app: &str) -> String {
    format!("[app={app} | title=Example | url=? | ts=2026-10-12T14:02:00.000Z]\n")
}

fn app_of(name: &str) -> &'static str {
    match name {
        "article" | "video" => "com.google.Chrome",
        "chat" => "com.tinyspeck.slackmacgap",
        "editor" => "com.microsoft.VSCode",
        "mail" => "com.apple.mail",
        "notes" => "com.apple.Notes",
        "messages" => "com.apple.MobileSMS",
        "terminal" => "com.apple.Terminal",
        other => panic!("no app for {other}"),
    }
}

fn read(stored: &str, app: Option<&str>) -> Reading {
    reading(stored, SCREEN, app, None)
}

fn separated(content: &str, chrome: &str) -> String {
    format!(
        "{}{content}{CHROME_SEPARATOR}{chrome}",
        header("com.example.app")
    )
}

// ---------------------------------------------------------------------------
// Goldens
// ---------------------------------------------------------------------------

#[test]
fn old_windows_lose_only_the_header_and_junk_tokens() {
    for name in ["article", "chat", "editor", "mail", "notes", "video"] {
        let body = fixture(&format!("{name}.old.txt"));
        let stored = format!("{}{body}", header(app_of(name)));
        let read = reading(&stored, SCREEN, Some(app_of(name)), Some("Example"));
        assert_eq!(
            read.main,
            fixture(&format!("{name}.old.main.txt")),
            "{name}"
        );
        assert_eq!(
            read.rest, "",
            "{name}: old text has nothing after a separator"
        );
    }
}

#[test]
fn classified_windows_read_as_main_then_rest() {
    for name in ["article", "chat", "editor", "messages", "notes", "terminal"] {
        let stored = fixture(&format!("{name}.stored.txt"));
        let read = reading(&stored, SCREEN, Some(app_of(name)), Some("Example"));
        assert_eq!(
            read.main,
            fixture(&format!("{name}.main.txt")),
            "{name} main"
        );
        assert_eq!(
            read.rest,
            fixture(&format!("{name}.rest.txt")),
            "{name} rest"
        );
    }
}

#[test]
fn the_editor_reads_as_its_code_its_chat_and_its_terminal() {
    let read = reading(&fixture("editor.stored.txt"), SCREEN, VSCODE, None);
    assert!(read
        .main
        .starts_with("use std::time::Duration;\n\n/// Delete events"));
    assert!(
        read.main.contains("\n        return Ok(0);\n    };\n"),
        "code keeps its indentation"
    );
    assert!(read.main.contains(
        "So a long sweep never holds the writer for more than one batch. Each batch deletes at most 512 events"
    ));
    assert!(read.main.ends_with("test result: ok. 6 passed; 0 failed"));
    for chrome in [
        "EXPLORER",
        "apps > agent > src",
        "Ask about your code",
        "Ln 9, Col 34",
        "TR",
    ] {
        assert!(!read.main.contains(chrome), "{chrome} is chrome");
        assert!(
            read.rest.contains(chrome),
            "{chrome} moves to rest, it is not deleted"
        );
    }
}

#[test]
fn a_two_sided_chat_reads_with_indents_of_none_or_four_spaces() {
    let read = reading(
        &fixture("messages.stored.txt"),
        SCREEN,
        Some("com.apple.MobileSMS"),
        None,
    );
    assert_eq!(
        read.main,
        "Are we still on for 3?\n    Yes, running five minutes late\nSee you there"
    );
    assert!(
        read.rest.contains("iMessage"),
        "the composer placeholder is chrome"
    );
    assert!(!read.main.contains("Me:"), "no invented labels");
}

// ---------------------------------------------------------------------------
// The header
// ---------------------------------------------------------------------------

#[test]
fn body_strips_only_a_whole_header() {
    assert_eq!(body("[app=a | title=t | url=u | ts=1]\nText"), "Text");
    assert_eq!(
        body("[app=claude-code | title=demo · user | url=/x/demo#main | session=s | src=/t.jsonl:2]\nHi"),
        "Hi",
        "a transcript import's header"
    );
    assert_eq!(
        body("[app=claude-code | title=demo · user | url=/x/demo#]\nHi"),
        "Hi",
        "an older transcript header"
    );
    let revision = format!("[MCP_RESOURCE revision_sha256={}]\n", "ab".repeat(32));
    assert_eq!(
        body(&format!(
            "{revision}[app=mcp:docs | title=Spec | url=docs://1 | ts=1]\nBody"
        )),
        "Body"
    );
    for kept in [
        "[app=editor | title=incomplete\nVisible content",
        "[app=editor | url=? | ts=now]\nVisible content",
        "[app=editor | title=title | url=? | ts=now\nVisible content",
        "Notes\n[app=editor | title=title | url=? | ts=now]\nVisible content",
        "[app=needle]\nOrdinary text.",
        "[app=needle | title=x | url= | ts=100]",
    ] {
        assert_eq!(body(kept), kept);
    }
    let header = "[app=e | title=t | url=? | ts=now]\n";
    assert_eq!(
        body(&format!("{header}{header}body")),
        format!("{header}body"),
        "one header, once"
    );
    let short_revision = format!(
        "[MCP_RESOURCE revision_sha256={}]\n[app=x | title=t | url=u | ts=1]\nB",
        "ab".repeat(8)
    );
    assert_eq!(
        body(&short_revision),
        short_revision,
        "a revision line is a 64-digit digest"
    );
}

#[test]
fn no_reading_holds_the_separator_or_a_header() {
    let revision = format!("[MCP_RESOURCE revision_sha256={}]\n", "cd".repeat(32));
    let stored_shapes = [
        format!("{}Content line one\n\n\u{1e}\nChrome", header("com.example.app")),
        format!("{}Page text\u{1e} with a stray separator{VISIBLE_OCR_SEPARATOR}Seen\n\n\u{1e}\nTabs", header("com.google.Chrome")),
        "[app=claude-code | title=demo · user | url=/x#main | session=s | src=/t.jsonl:9]\nHello \u{1e} there".to_owned(),
        "[app=codex | title=demo · tool | url=/x#]\nls\u{1e}".to_owned(),
        format!("{revision}[app=mcp:docs | title=Spec | url=docs://1 | ts=1]\nResource\u{1e}body"),
        format!("{}Second\n\n\u{1e}\nchrome\n\n\u{1e}\nmore chrome", header("com.apple.Notes")),
        format!("{}\u{1e}", header("com.apple.Notes")),
    ];
    let sources = [
        EventSource::Unknown,
        EventSource::ScreenOcr,
        EventSource::ScreenContext,
        EventSource::BrowserPage,
        EventSource::BrowserPageWithOcr,
        EventSource::TranscriptImport,
        EventSource::StructuredApp,
        EventSource::McpResource,
    ];
    for stored in &stored_shapes {
        for source in sources {
            for app in [None, TERMINAL, SLACK, VSCODE] {
                let read = reading(stored, source, app, Some("Example"));
                let seen = screen_reading(stored, source, app, None);
                let prefix = reading_prefix(stored, source, app, 280);
                let short = excerpt(&read, app, &ExcerptQuery::new("chrome"), 512);
                for text in [
                    &read.main, &read.rest, &seen.main, &seen.rest, &prefix, &short,
                ] {
                    assert!(!text.contains('\u{1e}'), "{source:?}: {text:?}");
                    assert!(!text.contains("[app="), "{source:?}: {text:?}");
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Junk and what survives
// ---------------------------------------------------------------------------

#[test]
fn logo_misreads_symbol_runs_and_icon_glyphs_go() {
    let stored = format!(
        "{}\u{4e09} Docs Pricing notes\n\u{53e3}\nSearch \u{25cf} mail\n\u{2606} \u{25a1} \u{2261} \u{d7}\n\u{f8ff} Apple menu\nBroken \u{fffd} glyph\nLaunch plan",
        header("com.apple.Notes")
    );
    assert_eq!(
        read(&stored, NOTES).main,
        "Docs Pricing notes\nSearch mail\nApple menu\nBroken glyph\nLaunch plan"
    );
}

#[test]
fn a_stray_glyph_the_helper_set_aside_stays_out_of_main() {
    let read = read(
        &separated(
            "Per-seat or tiered? How to price a team plan",
            "TR\nStripe Docs",
        ),
        NOTES,
    );
    assert_eq!(read.main, "Per-seat or tiered? How to price a team plan");
    assert_eq!(read.rest, "TR\nStripe Docs");
}

#[test]
fn old_text_keeps_short_latin_words_because_text_alone_cannot_tell_an_icon_from_initials() {
    // T5: old memories lose the header and stray symbols only. "TR" read off
    // an icon and "AJ" in a sentence are the same to a text rule.
    let stored = format!(
        "{}TR\nMet with AJ and RP about the launch.",
        header("com.apple.Notes")
    );
    assert_eq!(
        read(&stored, NOTES).main,
        "TR\nMet with AJ and RP about the launch."
    );
}

#[test]
fn real_short_words_numbers_and_initials_survive() {
    let lines = [
        "I",
        "a",
        "OK",
        "Go",
        "Free space: 5 GB",
        "Open issues",
        "3",
        "Thanks, J. R. Smith and AJ, for the notes.",
        "\u{4e1c}\u{4eac} is two characters, not one.",
    ];
    let text = lines.join("\n");
    for stored in [
        format!("{}{text}", header("com.apple.Notes")),
        separated(&text, "Sidebar"),
    ] {
        assert_eq!(read(&stored, NOTES).main, text);
    }
}

#[test]
fn a_cjk_window_keeps_its_single_characters() {
    let text =
        "\u{4eca}\u{65e5} \u{306e} \u{4e88}\u{5b9a}\n\u{4f1a}\u{8b70} \u{306f} \u{5348}\u{5f8c}";
    assert_eq!(
        read(&format!("{}{text}", header("com.apple.Notes")), NOTES).main,
        text
    );
}

#[test]
fn indented_code_keeps_every_byte_in_old_and_new_text() {
    let code = "fn sweep() {\n    if deleted > 0 {\n        store.vacuum()?;\n    }\n}";
    assert_eq!(
        read(&format!("{}{code}", header("com.microsoft.VSCode")), VSCODE).main,
        code
    );
    assert_eq!(read(&separated(code, "EXPLORER"), VSCODE).main, code);
    let with_junk = "fn sweep() {\n    \u{25cf} if deleted > 0 {\n\u{53e3}\n    }\n}";
    assert_eq!(
        read(&separated(with_junk, ""), VSCODE).main,
        "fn sweep() {\n    if deleted > 0 {\n\n    }\n}",
        "junk goes, every line keeps its place"
    );
}

#[test]
fn a_terminal_keeps_its_lines_and_indents_even_where_prose_would_join() {
    let output = "Compiling the workspace takes a while on this machine because of\nthe size\n  ok";
    let stored = separated(output, "zsh");
    assert_eq!(read(&stored, TERMINAL).main, output);
    assert_eq!(
        read(&stored, NOTES).main,
        "Compiling the workspace takes a while on this machine because of the size\n    ok",
        "outside a terminal the same lines join and the indent is four spaces"
    );
}

// ---------------------------------------------------------------------------
// Paragraphs and indents: only on classified text
// ---------------------------------------------------------------------------

#[test]
fn wrapped_lines_join_only_in_text_that_carries_the_separator() {
    let prose = "Most teams choose between charging for every seat and charging by tier. Per-seat\npricing is easy to explain and grows with the customer, but it punishes the well-\nconnected teams the most.";
    let joined = "Most teams choose between charging for every seat and charging by tier. Per-seat pricing is easy to explain and grows with the customer, but it punishes the well-connected teams the most.";
    assert_eq!(read(&separated(prose, ""), NOTES).main, joined);
    assert_eq!(
        read(&format!("{}{prose}", header("com.apple.Notes")), NOTES).main,
        prose
    );
}

#[test]
fn sentence_ends_short_lines_and_capitals_stay_on_their_own_lines() {
    let text = "Pushed the new onboarding flow to staging today.\nthe next line starts lower\nShort line\nlower start after a short line\nAnother long line that ends without a stop but\nThen a capital starts this one";
    assert_eq!(read(&separated(text, ""), NOTES).main, text);
}

#[test]
fn indents_outside_preformatted_text_are_none_or_four_spaces_in_classified_text_only() {
    let text = "Are we still on\n             Yes\nSee you";
    assert_eq!(
        read(&separated(text, ""), NOTES).main,
        "Are we still on\n    Yes\nSee you"
    );
    assert_eq!(
        read(&format!("{}{text}", header("com.apple.Notes")), NOTES).main,
        text
    );
}

#[test]
fn a_block_that_loses_everything_takes_its_gap_along() {
    let stored = separated("First\n\n\u{53e3}\n\u{25cf}\n\nSecond", "\u{25a1}\n\nTabs");
    let read = read(&stored, NOTES);
    assert_eq!(read.main, "First\n\nSecond");
    assert_eq!(read.rest, "Tabs");
}

// ---------------------------------------------------------------------------
// Sources
// ---------------------------------------------------------------------------

#[test]
fn a_browser_page_read_both_ways_shows_the_page_then_what_was_on_screen() {
    let page =
        "Pricing guide\nPer-seat pricing grows with the customer, and it punishes big teams.";
    let stored = format!(
        "{}{page}{VISIBLE_OCR_SEPARATOR}Per-seat pricing grows with the customer, and it\n\u{53e3} punishes big teams.\n\n\u{1e}\nStripe Docs \u{d7}",
        header("com.google.Chrome")
    );
    let seen_main = "Per-seat pricing grows with the customer, and it punishes big teams.";
    let read = reading(
        &stored,
        EventSource::BrowserPageWithOcr,
        Some("com.google.Chrome"),
        None,
    );
    assert_eq!(
        read.main, page,
        "the page's own text, as the extension sent it"
    );
    assert_eq!(read.rest, format!("{seen_main}\n\nStripe Docs \u{d7}"));
    let seen = screen_reading(
        &stored,
        EventSource::BrowserPageWithOcr,
        Some("com.google.Chrome"),
        None,
    );
    assert_eq!(
        seen.main, seen_main,
        "the on-screen question uses the visible part"
    );
    assert_eq!(seen.rest, "Stripe Docs \u{d7}");
}

#[test]
fn only_a_browser_page_read_both_ways_is_cut_at_the_marker() {
    let stored = format!(
        "{}Page{VISIBLE_OCR_SEPARATOR}Seen \u{53e3}",
        header("com.google.Chrome")
    );
    for source in [
        EventSource::BrowserPage,
        EventSource::ScreenOcr,
        EventSource::Unknown,
    ] {
        let read = reading(&stored, source, None, None);
        assert!(read.main.contains("[VISIBLE-OCR]"), "{source:?}");
        assert_eq!(read.rest, "");
    }
}

#[test]
fn text_that_was_not_read_off_a_screen_is_shown_as_stored() {
    let text = "Hi Dana,\n\u{25cf} \u{53e3}\nthe invoice is attached.\n\u{2606}";
    for source in [
        EventSource::Unknown,
        EventSource::BrowserPage,
        EventSource::TranscriptImport,
        EventSource::StructuredApp,
        EventSource::McpResource,
    ] {
        let read = reading(
            &format!("{}{text}", header("com.apple.mail")),
            source,
            None,
            None,
        );
        assert_eq!(read.main, text, "{source:?}");
        assert_eq!(read.rest, "");
    }
}

// ---------------------------------------------------------------------------
// The guard
// ---------------------------------------------------------------------------

fn corpus() -> Vec<(String, bool, String)> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures/ocr-secret-corpus.json");
    let value: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    value["cases"]
        .as_array()
        .unwrap()
        .iter()
        .map(|case| {
            (
                case["text"].as_str().unwrap().to_owned(),
                case["secret"].as_bool().unwrap(),
                case["why"].as_str().unwrap().to_owned(),
            )
        })
        .collect()
}

#[test]
fn the_guard_answers_the_shared_corpus_like_the_capture_helper() {
    let cases = corpus();
    assert!(cases.len() >= 60);
    for (text, secret, why) in cases {
        assert_eq!(contains_secret(&text), secret, "{why}: {text:?}");
    }
}

#[test]
fn the_guard_uses_the_capture_helpers_four_pattern_strings_verbatim() {
    let swift = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression/SuppressionCascade.swift");
    let source = std::fs::read_to_string(swift).unwrap();
    for pattern in PATTERNS {
        assert!(
            source.contains(&format!("#\"{pattern}\"#")),
            "{pattern} is not in SuppressionCascade.swift"
        );
    }
}

#[test]
fn cleaning_that_would_make_a_secret_appear_in_the_chrome_falls_back_to_the_stored_text() {
    // Removing the stray square would turn "token \u{25a1} : 12345" into
    // "token : 12345", which the helper would never have stored.
    let stored = separated(
        "Launch plan \u{53e3} for the beta",
        "Access token \u{25a1} : 12345",
    );
    assert!(!contains_secret(&stored));
    let read = read(&stored, NOTES);
    assert_eq!(read.rest, "Access token \u{25a1} : 12345");
    assert_eq!(
        read.main, "Launch plan \u{53e3} for the beta",
        "no other cleaning either"
    );
    assert!(!contains_secret(&format!("{}\n\n{}", read.main, read.rest)));
}

#[test]
fn a_secret_only_in_chrome_text_is_still_caught() {
    let stored = separated("Launch plan \u{53e3} for the beta", "Password: hunter2");
    let read = read(&stored, NOTES);
    assert_eq!(
        read.main, "Launch plan \u{53e3} for the beta",
        "the guard looked past the separator"
    );
    assert_eq!(read.rest, "Password: hunter2");
}

#[test]
fn cleaning_across_lines_cannot_make_a_secret_in_main() {
    // Dropping the symbol-only line would put "token" and "= abc123" on
    // neighbouring lines, which the key-value pattern spans.
    let stored = separated("token\n\u{25cf}\n= abc123 and more words to read", "Tabs");
    assert!(!contains_secret(&stored));
    let read = read(&stored, NOTES);
    assert!(!contains_secret(&read.main), "{:?}", read.main);
    assert_eq!(
        read.main,
        "token\n\u{25cf}\n= abc123 and more words to read"
    );
}

#[test]
fn a_passage_is_never_cut_so_that_a_secret_appears() {
    // Whole, neither token is an AWS key id: the first is too long, the
    // second has letters before it. Cut after twenty characters, or started
    // at its "AKIA", either would be one.
    let main = format!(
        "{}AKIAIOSFODNN7EXAMPLEZZ XXAKIAIOSFODNN7EXAMPLE tail",
        "word ".repeat(10)
    );
    assert!(!contains_secret(&main));
    let passage = excerpt(
        &Reading {
            main: main.clone(),
            rest: String::new(),
        },
        None,
        &ExcerptQuery::new("tail"),
        22,
    );
    assert!(!contains_secret(&passage), "{passage:?}");
    for max in 1..main.len() {
        let read = Reading {
            main: main.clone(),
            rest: String::new(),
        };
        let first = excerpt(&read, None, &ExcerptQuery::default(), max);
        let last = excerpt(&read, TERMINAL, &ExcerptQuery::default(), max);
        let prefix = reading_prefix(&format!("{}{main}", header("x")), SCREEN, None, max);
        for text in [first, last, prefix] {
            assert!(!contains_secret(&text), "{max}: {text:?}");
        }
    }
}

// ---------------------------------------------------------------------------
// Excerpts
// ---------------------------------------------------------------------------

#[test]
fn a_terminal_excerpt_shows_its_last_lines() {
    let lines: Vec<String> = (1..=200)
        .map(|n| format!("line {n} of the build"))
        .collect();
    let read = reading(&separated(&lines.join("\n"), "zsh"), SCREEN, TERMINAL, None);
    let passage = excerpt(&read, TERMINAL, &ExcerptQuery::default(), 120);
    assert!(passage.ends_with("line 200 of the build"), "{passage:?}");
    assert!(
        passage.starts_with("line "),
        "starts on a whole line: {passage:?}"
    );
    assert!(passage.len() <= 120);
    assert!(!passage.contains("line 1 of"));
}

#[test]
fn a_chat_excerpt_shows_the_newest_messages() {
    let messages: Vec<String> = (1..=50).map(|n| format!("Maya: message {n}")).collect();
    let read = reading(
        &separated(&messages.join("\n"), "Channels"),
        SCREEN,
        SLACK,
        None,
    );
    let passage = excerpt(&read, SLACK, &ExcerptQuery::default(), 60);
    assert!(passage.ends_with("Maya: message 50"), "{passage:?}");
    let other = excerpt(&read, NOTES, &ExcerptQuery::default(), 60);
    assert!(
        other.starts_with("Maya: message 1\n"),
        "other apps show the first lines: {other:?}"
    );
}

#[test]
fn a_query_excerpt_contains_the_query_from_main_or_else_from_rest() {
    let content = format!(
        "{}The launch decision is recorded here. {}",
        "filler ".repeat(100),
        "tail ".repeat(100)
    );
    let read = reading(
        &separated(&content, "Sidebar: Roadmap"),
        SCREEN,
        NOTES,
        None,
    );
    let passage = excerpt(&read, NOTES, &ExcerptQuery::new("launch decision"), 280);
    assert!(passage.contains("launch decision"), "{passage:?}");
    assert!(passage.len() <= 280);
    assert!(read.main.contains(&passage), "verbatim from main");
    let from_rest = excerpt(&read, NOTES, &ExcerptQuery::new("roadmap"), 280);
    assert_eq!(from_rest, "Sidebar: Roadmap");
    let nowhere = excerpt(&read, NOTES, &ExcerptQuery::new("quantum"), 40);
    assert_eq!(
        nowhere,
        &read.main[..40],
        "no match: the first part of main"
    );
}

#[test]
fn a_query_excerpt_starts_on_a_whole_word_with_a_little_context() {
    let main = format!(
        "{}decision for the launch is recorded.",
        "before ".repeat(80)
    );
    let passage = excerpt(
        &Reading {
            main: main.clone(),
            rest: String::new(),
        },
        None,
        &ExcerptQuery::new("launch"),
        280,
    );
    let lead = passage.split_once("launch").unwrap().0;
    assert!(lead.len() <= 32, "{lead:?}");
    assert!(
        passage.starts_with(|ch: char| ch.is_alphanumeric()),
        "{passage:?}"
    );
    assert!(main.contains(&passage));
}

#[test]
fn found_in_says_whether_a_search_word_is_in_a_text() {
    let query = ExcerptQuery::new("Roadmap");
    assert!(query.found_in("Sidebar: roadmap"));
    assert!(!query.found_in("Sidebar: roadmaps"));
    assert!(!ExcerptQuery::new("  ").found_in("anything"));
}

// ---------------------------------------------------------------------------
// Prefixes for lists
// ---------------------------------------------------------------------------

#[test]
fn a_list_prefix_is_the_start_of_main() {
    for name in ["article", "chat", "editor", "messages", "notes", "terminal"] {
        let stored = fixture(&format!("{name}.stored.txt"));
        let app = Some(app_of(name));
        let main = reading(&stored, SCREEN, app, None).main;
        for max in [1, 2, 17, 80, 280, 5_000] {
            assert_eq!(
                reading_prefix(&stored, SCREEN, app, max),
                main.chars().take(max).collect::<String>(),
                "{name} {max}"
            );
        }
    }
    for name in ["article", "chat", "editor", "mail", "notes", "video"] {
        let stored = format!(
            "{}{}",
            header(app_of(name)),
            fixture(&format!("{name}.old.txt"))
        );
        let app = Some(app_of(name));
        let main = reading(&stored, SCREEN, app, None).main;
        assert_eq!(
            reading_prefix(&stored, SCREEN, app, 280),
            main.chars().take(280).collect::<String>(),
            "{name}"
        );
    }
    assert_eq!(reading_prefix("anything", SCREEN, None, 0), "");
}

#[test]
fn a_list_prefix_of_a_page_read_both_ways_is_the_page() {
    let stored = format!(
        "{}Page text{VISIBLE_OCR_SEPARATOR}Seen",
        header("com.google.Chrome")
    );
    assert_eq!(
        reading_prefix(&stored, EventSource::BrowserPageWithOcr, None, 280),
        "Page text"
    );
    assert_eq!(
        reading_prefix(&stored, EventSource::BrowserPageWithOcr, None, 4),
        "Page"
    );
}

/// About 64 KB of one block with no blank line in it, as a window read in
/// one piece gives.
fn one_block_window() -> String {
    let line = "Most teams choose between charging for every seat and charging by tier \u{4e09}\n";
    format!(
        "{}{}",
        header("com.apple.Notes"),
        line.repeat(64 * 1024 / line.len())
    )
}

/// About 64 KB of window text: prose, code and chat, with icon misreads.
fn large_window(seed: u64, classified: bool) -> String {
    let mut rng = Lcg(seed);
    let mut text = String::new();
    while text.len() < 62 * 1024 {
        match rng.below(3) {
            0 => {
                for _ in 0..6 {
                    text.push_str("Most teams choose between charging for every seat and charging by tier and\n");
                }
                text.push_str("the plan is not finished.\n\n");
            }
            1 => text.push_str("fn sweep(store: &Store) -> Result<u64, Error> {\n    let mut deleted = 0;\n    Ok(deleted)\n}\n\n"),
            _ => text.push_str("\u{4e09} Maya Chen 10:42 AM\nPushed the onboarding flow \u{25cf} to staging.\n\n"),
        }
    }
    if classified {
        text.push_str(&CHROME_SEPARATOR[2..]);
        text.push_str(&"EXPLORER\napps\nagent\nsrc\n".repeat(64));
    }
    format!("{}{text}", header("com.apple.Notes"))
}

#[test]
fn list_prefixes_of_a_thousand_64_kb_windows_stop_early() {
    let mut windows: Vec<String> = (0..6)
        .map(|seed| large_window(seed, seed % 2 == 0))
        .collect();
    windows.push(one_block_window());
    windows.push(one_block_window().replace("\u{4e09}", "and"));
    assert!(windows.iter().all(|w| w.len() >= 60 * 1024));
    // A full reading of these windows takes about fifteen times as long in a
    // debug build. A prefix reads only the blocks it shows, in pieces of at
    // most 64 lines, plus one count of letters when a lone CJK character
    // appears. The best of three runs keeps a busy machine from failing it.
    let best = (0..3)
        .map(|_| {
            let started = Instant::now();
            let mut total = 0;
            for index in 0..1_000 {
                total += reading_prefix(&windows[index % windows.len()], SCREEN, NOTES, 280).len();
            }
            assert!(total > 0);
            started.elapsed()
        })
        .min()
        .unwrap();
    assert!(
        best < Duration::from_secs(4),
        "1,000 prefixes took {best:?}"
    );
}

// ---------------------------------------------------------------------------
// Properties
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

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }

    fn pick<'a>(&mut self, items: &[&'a str]) -> &'a str {
        items[usize::try_from(self.below(items.len() as u64)).unwrap()]
    }
}

const WORDS: &[&str] = &[
    "plan",
    "Pricing",
    "the",
    "team",
    "is",
    "a",
    "I",
    "OK",
    "Go",
    "5",
    "GB",
    "AJ",
    "seat,",
    "well-",
    "known",
    "(Ravi)",
    "x",
    "=",
    "{",
    "}",
    "->",
    "$18",
    "12:31",
    "\u{2022}",
    "\u{2014}",
    "+",
    "\u{2606}",
    "\u{d7}",
    "caf\u{e9}",
    "\u{4e1c}\u{4eac}",
    "<",
    "Tuesday.",
    "and",
    "colleagues",
    "--",
    "\u{2261}",
];
const JUNK: &[&str] = &[
    "\u{4e09}",
    "\u{53e3}",
    "\u{25cf}",
    "\u{25a1}",
    "\u{2500}\u{2500}",
    "\u{f8ff}",
    "\u{fffd}",
];

fn random_text(rng: &mut Lcg, junk_share: u64) -> String {
    let mut lines = Vec::new();
    for _ in 0..=rng.below(14) {
        if rng.below(6) == 0 {
            lines.push(String::new());
            continue;
        }
        let mut line = " ".repeat(usize::try_from(rng.below(3) * 4 * rng.below(2)).unwrap());
        for index in 0..=rng.below(9) {
            if index > 0 {
                line.push(' ');
            }
            if rng.below(100) < junk_share {
                line.push_str(rng.pick(JUNK));
            } else {
                line.push_str(rng.pick(WORDS));
            }
        }
        lines.push(line);
    }
    lines.join("\n")
}

fn is_junk_token(token: &str, cjk_rare: bool) -> bool {
    let single_cjk = cjk_rare
        && token.chars().count() == 1
        && token
            .chars()
            .all(|c| ('\u{4e00}'..='\u{9fff}').contains(&c));
    single_cjk
        || token.chars().all(|c| {
            ('\u{2500}'..='\u{25ff}').contains(&c)
                || ('\u{e000}'..='\u{f8ff}').contains(&c)
                || c == '\u{fffd}'
        })
}

/// The output's characters, whitespace aside, are the input's tokens in
/// order, but for tokens that are junk or hold no letter or digit.
fn only_junk_disappeared(input: &[&str], output: &str) -> bool {
    let out: Vec<char> = output.chars().filter(|c| !c.is_whitespace()).collect();
    let tokens: Vec<Vec<char>> = input
        .iter()
        .flat_map(|part| part.split_whitespace())
        .map(|token| token.chars().collect())
        .collect();
    // reachable[j]: the first i tokens can produce out[..j].
    let mut reachable = vec![false; out.len() + 1];
    reachable[0] = true;
    for token in &tokens {
        let text: String = token.iter().collect();
        let skippable = is_junk_token(&text, true) || !token.iter().any(|c| c.is_alphanumeric());
        let mut next = vec![false; out.len() + 1];
        for (j, ok) in reachable.iter().enumerate() {
            if !ok {
                continue;
            }
            if skippable {
                next[j] = true;
            }
            if out.len() >= j + token.len() && out[j..j + token.len()] == token[..] {
                next[j + token.len()] = true;
            }
        }
        reachable = next;
    }
    reachable[out.len()]
}

#[test]
fn nothing_but_junk_ever_disappears() {
    let mut rng = Lcg(7);
    for case in 0..2_000 {
        let content = random_text(&mut rng, 15);
        let chrome = random_text(&mut rng, 15);
        let classified = case % 2 == 0;
        let app = [NOTES, TERMINAL, SLACK][usize::try_from(rng.below(3)).unwrap()];
        let stored = if classified {
            separated(&content, &chrome)
        } else {
            format!("{}{content}", header("x"))
        };
        let read = read(&stored, app);
        let parts: Vec<&str> = if classified {
            vec![&content, &chrome]
        } else {
            vec![&content]
        };
        let output = format!("{}\n{}", read.main, read.rest);
        assert!(
            only_junk_disappeared(&parts, &output),
            "case {case}\n{stored:?}\n{read:?}"
        );
    }
}

/// Every line `line` can become: each junk token goes with one whitespace
/// character beside it when one is left.
fn allowed_lines(line: &str, cjk_rare: bool) -> Vec<String> {
    let mut spans = Vec::new();
    let mut start = None;
    for (at, ch) in line
        .char_indices()
        .chain(std::iter::once((line.len(), ' ')))
    {
        match (ch.is_whitespace(), start) {
            (false, None) => start = Some(at),
            (true, Some(from)) => {
                spans.push((from, at));
                start = None;
            }
            _ => {}
        }
    }
    let junk: Vec<(usize, usize)> = spans
        .into_iter()
        .filter(|(s, e)| is_junk_token(&line[*s..*e], cjk_rare))
        .collect();
    let mut outputs = Vec::new();
    for choice in 0..(1u32 << junk.len()) {
        let mut deleted = vec![false; line.len()];
        for (index, (start, end)) in junk.iter().enumerate() {
            deleted[*start..*end].iter_mut().for_each(|d| *d = true);
            let before = *start > 0 && line.as_bytes()[start - 1] == b' ' && !deleted[start - 1];
            let after = *end < line.len() && line.as_bytes()[*end] == b' ' && !deleted[*end];
            if before && (choice & (1 << index) != 0 || !after) {
                deleted[start - 1] = true;
            } else if after {
                deleted[*end] = true;
            }
        }
        let kept: Vec<u8> = line
            .bytes()
            .zip(&deleted)
            .filter(|(_, d)| !**d)
            .map(|(b, _)| b)
            .collect();
        outputs.push(String::from_utf8(kept).unwrap());
    }
    outputs
}

fn cjk_rare(text: &str) -> bool {
    let letters = text.chars().filter(|c| c.is_alphabetic()).count();
    let cjk = text
        .chars()
        .filter(|c| ('\u{4e00}'..='\u{9fff}').contains(c))
        .count();
    cjk * 10 < letters
}

/// What a terminal's text must read as: each line with its junk tokens
/// gone and nothing else changed; a block left with no text goes with the
/// blank lines before it; blank lines at the start and end go.
fn kept_as_read(content: &str, cjk_rare: bool) -> String {
    let mut out = String::new();
    let mut blank_lines = 0;
    let mut block: Vec<String> = Vec::new();
    let mut started = false;
    for line in content.split('\n').chain(std::iter::once("")) {
        if !line.trim().is_empty() {
            // The documented choice: the whitespace before a junk token
            // when it is free, otherwise the one after it.
            let allowed = allowed_lines(line, cjk_rare);
            block.push(allowed.last().expect("at least one way").clone());
            continue;
        }
        if !block.is_empty() {
            if block.iter().any(|l| !l.trim().is_empty()) {
                if started {
                    out.push_str(&"\n".repeat(blank_lines + 1));
                }
                out.push_str(&block.join("\n"));
                started = true;
            }
            block.clear();
            blank_lines = 0;
        }
        blank_lines += 1;
    }
    out
}

#[test]
fn preformatted_text_is_byte_exact_but_for_removed_junk() {
    let mut rng = Lcg(11);
    for case in 0..2_000 {
        let content = random_text(&mut rng, 20);
        let classified = case % 2 == 0;
        let stored = if classified {
            separated(&content, "zsh")
        } else {
            format!("{}{content}", header("x"))
        };
        let main = read(&stored, TERMINAL).main;
        let rare = cjk_rare(body(&stored));
        assert_eq!(
            main,
            kept_as_read(&content, rare),
            "case {case}: {content:?}"
        );
    }
}
