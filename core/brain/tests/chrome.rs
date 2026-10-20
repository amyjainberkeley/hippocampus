//! Window chrome set apart from what the person was reading
//! (`mci_brain::chrome`, used by `mci_brain::reading`).
//!
//! Every window here is synthetic: made-up text laid out the way the reader
//! reads Chrome, Safari, Arc, VS Code and Slack, before windows were
//! classified (one line per row, columns run together) and since.

use std::collections::HashMap;
use std::fmt::Write as _;

use mci_brain::chrome::{Frame, RepeatedChrome};
use mci_brain::reading::{
    body, excerpt, passage, reading, reading_prefix, reading_with, ExcerptQuery, Reading,
    CHROME_SEPARATOR,
};
use mci_brain::redaction::ocr_secrets::contains_secret;
use mci_brain::EventSource;

const SCREEN: EventSource = EventSource::ScreenOcr;
const CHROME: &str = "com.google.Chrome";
const SAFARI: &str = "com.apple.Safari";
const ARC: &str = "company.thebrowser.Browser";
const VSCODE: &str = "com.microsoft.VSCode";
const SLACK: &str = "com.tinyspeck.slackmacgap";

/// The tab strip from the report: Chrome's tabs read as one line, favicons as
/// letters, titles cut short, a close button and a check mark between them.
const REPORTED_TAB_STRIP: &str =
    "T N 27 Trailhead - Sched \u{d7} \u{2713} Q4 planning - Goo # launch-plan (Chan\u{2026}";

fn stored(app: &str, title: &str, text: &str) -> String {
    format!("[app={app} | title={title} | url=? | ts=2026-10-12T14:02:00.000Z]\n{text}")
}

fn lines_of(text: &str) -> Vec<&str> {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect()
}

/// Every token of `text` with a letter or digit is in `main` or `rest` at
/// least as often: chrome moves, it is never deleted. (The windows here hold
/// no junk glyphs, so every such token must survive.)
fn assert_no_word_lost(text: &str, read: &Reading) {
    let mut want: HashMap<&str, usize> = HashMap::new();
    for token in text.split_whitespace() {
        if token.chars().any(char::is_alphanumeric) {
            *want.entry(token).or_default() += 1;
        }
    }
    let shown = format!("{}\n{}", read.main, read.rest);
    let mut have: HashMap<&str, usize> = HashMap::new();
    for token in shown.split_whitespace() {
        *have.entry(token).or_default() += 1;
    }
    for (token, count) in want {
        assert!(
            have.get(token).copied().unwrap_or(0) >= count,
            "{token:?} was lost\n{read:#?}"
        );
    }
}

/// List rows and passages agree with the reading.
fn assert_rows_agree(stored: &str, app: &str, read: &Reading) {
    assert_eq!(
        reading_prefix(stored, SCREEN, Some(app), 280),
        read.main.chars().take(280).collect::<String>()
    );
    let none = ExcerptQuery::default();
    assert_eq!(
        passage(stored, SCREEN, Some(app), &none, 280),
        excerpt(read, Some(app), &none, 280)
    );
}

// ---------------------------------------------------------------------------
// The report
// ---------------------------------------------------------------------------

const ACCENTS_PAGE: &str = "How to type accents on a Mac
Click in a document where you want the letter to go.
Press and hold a letter key, then choose an accent from the menu.
Release the key to type the letter with its accent.";

#[test]
fn the_reported_tab_strip_leaves_main_and_the_page_stays() {
    let text = format!(
        "{REPORTED_TAB_STRIP}\n< > C support.example/type-accents \u{2606}\n{ACCENTS_PAGE}"
    );
    let stored = stored(CHROME, "How to type accents on a Mac", &text);
    let read = reading(&stored, SCREEN, Some(CHROME), None);
    assert_eq!(
        read.main, ACCENTS_PAGE,
        "the page, in reading order, unchanged"
    );
    assert!(!read.main.contains("Sched") && !read.main.contains("Q4 planning - Goo"));
    assert_eq!(
        lines_of(&read.rest),
        vec![
            REPORTED_TAB_STRIP,
            "< > C support.example/type-accents \u{2606}"
        ],
        "the strip and the address bar are in rest, not deleted"
    );
    assert_no_word_lost(&text, &read);
    assert_rows_agree(&stored, CHROME, &read);
    // A tab title still finds the moment, from the rest of the window.
    let found = passage(
        &stored,
        SCREEN,
        Some(CHROME),
        &ExcerptQuery::new("Trailhead schedule"),
        280,
    );
    assert!(found.contains("Trailhead"), "{found}");
    // The list row starts with the page.
    assert!(reading_prefix(&stored, SCREEN, Some(CHROME), 280).starts_with("How to type accents"));
}

#[test]
fn the_stored_text_keeps_every_word_for_search_and_audit() {
    let text = format!("{REPORTED_TAB_STRIP}\n{ACCENTS_PAGE}");
    let stored = stored(CHROME, "How to type accents on a Mac", &text);
    let before = stored.clone();
    let _ = reading(&stored, SCREEN, Some(CHROME), None);
    assert_eq!(stored, before);
    assert_eq!(body(&stored), text);
}

// ---------------------------------------------------------------------------
// One frame: Chrome, VS Code, Slack
// ---------------------------------------------------------------------------

#[test]
fn chrome_sets_apart_its_tab_strip_address_bar_and_bookmarks_bar() {
    let page = "Per-seat or tiered? How to price a team plan
By Lena Ortiz, October 3, 2026
Most teams choose between charging for every seat and charging by tier.
A seat minimum is the usual compromise.";
    let chrome_lines = [
        "Per-seat or tiered? How to p\u{2026} \u{d7} Stripe Docs \u{d7} Inbox (12) \u{d7} +",
        "< > C pricingnotes.example/team-plans/per-seat-or-tiered \u{2606} \u{22ee}",
        "Gmail YouTube Maps News All Bookmarks",
    ];
    let text = format!("{}\n{page}", chrome_lines.join("\n"));
    let stored = stored(
        CHROME,
        "Per-seat or tiered? How to price a team plan",
        &text,
    );
    let read = reading(&stored, SCREEN, Some(CHROME), None);
    assert_eq!(read.main, page);
    assert_eq!(lines_of(&read.rest), chrome_lines.to_vec());
    assert_no_word_lost(&text, &read);
    assert_rows_agree(&stored, CHROME, &read);
}

#[test]
fn a_web_apps_menus_and_share_button_leave_main_and_the_document_stays() {
    // Google Docs in Chrome, read before windows were classified: the tabs,
    // the address, the document's name, its menus, Share, then the page.
    let page = "Goals
Ship the rounding fix before the holiday sale
Cut checkout to under 30 seconds on mobile";
    let chrome_lines = [
        "E Q4 planning - Google Docs \u{d7} D Rounding half to even \u{00b7} Dev No \u{d7} +",
        "< > C docs.google.com/document/d/q4-planning/edit \u{2606}",
        "File Edit View Insert Format Tools Extensions Help",
        "Share",
    ];
    let text = format!(
        "{}\n{}\nQ4 planning\n{}\n{}\n{page}",
        chrome_lines[0], chrome_lines[1], chrome_lines[2], chrome_lines[3]
    );
    let stored = stored(CHROME, "Q4 planning - Google Docs", &text);
    let read = reading(&stored, SCREEN, Some(CHROME), None);
    assert_eq!(read.main, format!("Q4 planning\n{page}"));
    assert_eq!(lines_of(&read.rest), chrome_lines.to_vec());
    assert_no_word_lost(&text, &read);
    assert_rows_agree(&stored, CHROME, &read);
}

#[test]
fn a_search_pages_tabs_leave_main_and_the_results_stay() {
    let results = "Per-seat or tiered? How to price a team plan
Most teams choose between charging for every seat and charging by tier.";
    let chrome_lines = [
        "G per seat vs tiered pricing - Goo \u{d7} Q4 planning - Google Docs \u{d7} +",
        "< > C google.com/search?q=per+seat+vs+tiered+pricing \u{2606}",
        "All Images Videos News Shopping Short videos More Tools",
    ];
    let text = format!("{}\n{results}", chrome_lines.join("\n"));
    let stored = stored(CHROME, "per seat vs tiered pricing - Google Search", &text);
    let read = reading(&stored, SCREEN, Some(CHROME), None);
    assert_eq!(read.main, results);
    assert_eq!(lines_of(&read.rest), chrome_lines.to_vec());
    assert_no_word_lost(&text, &read);
    assert_rows_agree(&stored, CHROME, &read);
}

#[test]
fn a_sentence_of_menu_words_stays_and_other_apps_keep_their_menu_rows() {
    // A sentence made of menu words is the page; the lone button under it,
    // near the top, is not. An app that is not a browser keeps both.
    let page = "Edit the file, then view it
Share";
    let read = reading(
        &stored(CHROME, "Notes on editing", page),
        SCREEN,
        Some(CHROME),
        None,
    );
    assert_eq!(read.main, "Edit the file, then view it");
    assert_eq!(read.rest, "Share");
    let notes = "File Edit View Insert Format Tools Extensions Help\nShare";
    let read = reading(
        &stored("com.apple.Notes", "Menus", notes),
        SCREEN,
        Some("com.apple.Notes"),
        None,
    );
    assert_eq!(read.main, notes);
    assert_eq!(read.rest, "");
}

#[test]
fn a_sites_menu_leaves_main_and_the_article_starts_with_its_heading() {
    let page = "MONEY & ROUNDING
Rounding half to even
Why banker\u{2019}s rounding keeps order totals from drifting by a cent";
    let chrome_lines = [
        "D Rounding half to even \u{00b7} Dev No \u{d7} 31 Northwind - Calen \u{d7} +",
        "< > C devnotes.example/rounding \u{2606}",
        "Dev Notes Articles Topics About Subscribe",
    ];
    let text = format!("{}\n{page}", chrome_lines.join("\n"));
    let stored = stored(CHROME, "Rounding half to even \u{00b7} Dev Notes", &text);
    let read = reading(&stored, SCREEN, Some(CHROME), None);
    assert_eq!(read.main, page);
    assert_eq!(lines_of(&read.rest), chrome_lines.to_vec());
    assert_no_word_lost(&text, &read);
    assert_rows_agree(&stored, CHROME, &read);
}

#[test]
fn messages_sets_apart_its_receipts_and_message_box() {
    let chat = "Today 2:21 PM
Are we still on for 3?
Yes, running five minutes late
Read the printouts before you come
Delivered
iMessage";
    let read = reading(
        &stored("com.apple.MobileSMS", "Sam Lee", chat),
        SCREEN,
        Some("com.apple.MobileSMS"),
        None,
    );
    assert_eq!(
        read.main,
        "Today 2:21 PM\nAre we still on for 3?\nYes, running five minutes late\nRead the printouts before you come"
    );
    assert_eq!(lines_of(&read.rest), vec!["Delivered", "iMessage"]);
    assert_no_word_lost(chat, &read);
}

#[test]
fn a_page_heading_that_holds_a_times_sign_is_kept() {
    // Not a tab strip: one "×", nothing cut short, no new-tab button.
    let page = "Width \u{d7} Height calculator\nEnter the width and the height in centimetres.";
    let read = reading(
        &stored(CHROME, "Calculator", page),
        SCREEN,
        Some(CHROME),
        None,
    );
    assert_eq!(read.main, page);
    assert_eq!(read.rest, "");
}

#[test]
fn below_the_first_lines_nothing_in_a_browser_moves_by_its_shape() {
    let mut page = String::from("Release notes\n");
    for n in 1..=8 {
        let _ = writeln!(page, "Item {n} shipped this week.");
    }
    page.push_str("Compare plans \u{d7} Teams \u{d7} Studios \u{d7}");
    let read = reading(
        &stored(CHROME, "Release notes", &page),
        SCREEN,
        Some(CHROME),
        None,
    );
    assert_eq!(read.main, page);
}

#[test]
fn vscode_sets_apart_tabs_headings_breadcrumbs_and_status_bar_and_keeps_code_exact() {
    let code = "pub fn order_total(lines: &[Line]) -> Money {
    let subtotal: Money = lines.iter().map(|l| l.price * l.qty).sum();
    round_half_even(subtotal + subtotal * TAX_RATE)
}";
    let text = format!(
        "tax.rs \u{d7} cart.rs \u{d7} main.rs \u{d7}
EXPLORER
src > cart > tax.rs
{code}
OUTLINE
TIMELINE
main 0 errors, 2 warnings Ln 14, Col 37 UTF-8 Rust"
    );
    let stored = stored(VSCODE, "tax.rs \u{2014} trailhead-shop", &text);
    let read = reading(&stored, SCREEN, Some(VSCODE), None);
    assert_eq!(read.main, code, "code keeps every byte, indents included");
    assert_eq!(
        lines_of(&read.rest),
        vec![
            "tax.rs \u{d7} cart.rs \u{d7} main.rs \u{d7}",
            "EXPLORER",
            "src > cart > tax.rs",
            "OUTLINE",
            "TIMELINE",
            "main 0 errors, 2 warnings Ln 14, Col 37 UTF-8 Rust",
        ]
    );
    assert_no_word_lost(&text, &read);
    assert_rows_agree(&stored, VSCODE, &read);
}

#[test]
fn slack_sets_apart_its_top_bar_sidebar_headings_and_message_box() {
    let messages = "Maya Chen 10:42 AM
Pushed the new onboarding flow to staging.
Ravi Patel 10:47 AM
Looks good. One nit on the capture copy.";
    let text = format!(
        "Northwind Studio > Q Search Northwind Studio
Threads
{messages}
Direct messages

Message #launch-plan"
    );
    let stored = stored(
        SLACK,
        "launch-plan (Channel) - Northwind Studio - Slack",
        &text,
    );
    let read = reading(&stored, SCREEN, Some(SLACK), None);
    assert_eq!(read.main, messages);
    assert_eq!(
        lines_of(&read.rest),
        vec![
            "Northwind Studio > Q Search Northwind Studio",
            "Threads",
            "Direct messages",
            "Message #launch-plan",
        ]
    );
    assert_no_word_lost(&text, &read);
    assert_rows_agree(&stored, SLACK, &read);
}

#[test]
fn a_message_that_starts_like_a_heading_stays() {
    let messages = "Message me when the build is green.\nThreads are hard to follow on mobile.";
    let read = reading(
        &stored(SLACK, "general", messages),
        SCREEN,
        Some(SLACK),
        None,
    );
    assert_eq!(read.main, messages);
}

#[test]
fn classified_text_is_left_as_the_helper_classified_it() {
    // The helper knew where each line sat on the screen: what it kept as
    // content stays whole, even a line shaped like chrome, and its chrome is
    // `rest`.
    let content = format!("{REPORTED_TAB_STRIP}\n{ACCENTS_PAGE}");
    let text = format!("{content}{CHROME_SEPARATOR}Gmail YouTube Maps");
    let stored = stored(CHROME, "Accents", &text);
    let read = reading(&stored, SCREEN, Some(CHROME), None);
    assert!(read.main.starts_with(REPORTED_TAB_STRIP), "{:?}", read.main);
    assert!(read
        .main
        .ends_with("Release the key to type the letter with its accent."));
    assert_eq!(read.rest, "Gmail YouTube Maps");
}

#[test]
fn a_terminal_is_kept_as_read() {
    let text = "a.rs \u{d7} b.rs \u{d7} c.rs \u{d7}\n$ cargo test\nok";
    let read = reading(
        &stored("com.apple.Terminal", "zsh", text),
        SCREEN,
        Some("com.apple.Terminal"),
        None,
    );
    assert_eq!(read.main, text);
}

#[test]
fn moving_chrome_never_makes_a_secret_appear() {
    // The run at the top passes over a lone word above the strip; without
    // the strip between them, "token" and ": …" would read as a key and its
    // value. Nothing moves, and nothing reads as a secret.
    let text = "token\nTab one \u{d7} Tab two \u{d7}\n: abc123def456\nMore page text";
    assert!(!contains_secret(text));
    let stored = stored(CHROME, "Settings", text);
    let read = reading(&stored, SCREEN, Some(CHROME), None);
    assert!(
        !contains_secret(&read.main) && !contains_secret(&read.rest),
        "{read:?}"
    );
    assert!(read.main.contains("Tab one"), "nothing moved: {read:?}");
    let prefix = reading_prefix(&stored, SCREEN, Some(CHROME), 280);
    assert!(!contains_secret(&prefix), "{prefix}");
    let shown = passage(&stored, SCREEN, Some(CHROME), &ExcerptQuery::default(), 280);
    assert!(!contains_secret(&shown), "{shown}");
}

// ---------------------------------------------------------------------------
// What was read stays, however much it reads like chrome
// ---------------------------------------------------------------------------

/// Whether `line` is still a line of `main`.
fn kept_in_main(read: &Reading, line: &str) -> bool {
    read.main.lines().any(|kept| kept.trim() == line.trim())
}

#[test]
fn sums_formulas_and_sizes_under_a_browsers_tab_strip_stay() {
    for line in [
        "Dimensions: 24 \u{d7} 18 \u{d7} 2 inches",
        "Storage Bin, 15 \u{d7} 10 \u{d7} 6 Inches",
        "Area = length \u{d7} width \u{d7} height",
        "Cost = price \u{d7} quantity \u{d7} (1 \u{2212} discount)",
        "Matrix product: A \u{d7} B \u{d7} C",
    ] {
        // Older text: the strip and the address bar go, the line stays.
        let old = format!(
            "Pricing notes \u{d7} Stripe Docs \u{d7}\n< > C shop.example.com/bins \u{2606}\n{line}\nShips flat in two days.\nMore text here about the item."
        );
        let read = reading(&stored(CHROME, "Shop", &old), SCREEN, Some(CHROME), None);
        assert!(kept_in_main(&read, line), "{line}: {read:?}");
        assert!(!read.main.contains("Stripe Docs"), "{read:?}");
        // Classified text: the helper's content stays whole.
        let new = format!(
            "{line}\nShips flat in two days.\nMore text here about the item.{CHROME_SEPARATOR}Pricing notes \u{d7} Stripe Docs \u{d7}"
        );
        let read = reading(&stored(CHROME, "Shop", &new), SCREEN, Some(CHROME), None);
        assert!(kept_in_main(&read, line), "{line}: {read:?}");
    }
}

#[test]
fn a_classified_pages_first_lines_stay_whatever_their_shape() {
    for line in [
        "Get started",
        "y = mx + b",
        "a\u{b2} + b\u{b2} = c\u{b2}",
        "ok :)",
        "https://example.com/q3-report",
        "Share",
    ] {
        let text = format!(
            "{line}\nInstall the tool and create your first project.\nMore of the page follows here.{CHROME_SEPARATOR}Pricing notes \u{d7} Stripe Docs \u{d7}"
        );
        let read = reading(&stored(CHROME, "Docs", &text), SCREEN, Some(CHROME), None);
        assert!(kept_in_main(&read, line), "{line}: {read:?}");
    }
}

#[test]
fn an_editors_markdown_steps_and_code_in_the_middle_stay() {
    for line in [
        "## TIMELINE",
        "- OUTPUT",
        "System Settings > Privacy > Accessibility",
        "assert low > mid > high",
        "SEARCH",
        "if a > b > c { return; }",
    ] {
        let text = format!("# Notes\nSome prose before.\n{line}\nSome prose after.\nlet x = 1;");
        let read = reading(
            &stored(VSCODE, "NOTES.md \u{2014} trailhead", &text),
            SCREEN,
            Some(VSCODE),
            None,
        );
        assert!(kept_in_main(&read, line), "{line}: {read:?}");
    }
}

#[test]
fn chat_replies_that_read_like_slack_or_messages_chrome_stay() {
    for line in ["Later", "More", "Files", "Message me later"] {
        let text = format!(
            "Maya Chen 10:42 AM\nCan we sync on the deck?\nSam Lee 10:43 AM\n{line}\nMaya Chen 10:44 AM\nok"
        );
        let read = reading(
            &stored(SLACK, "launch (Channel) - Northwind - Slack", &text),
            SCREEN,
            Some(SLACK),
            None,
        );
        assert!(kept_in_main(&read, line), "{line}: {read:?}");
    }
    // A reply last in the window is not the message box.
    for line in ["Message received", "Message sent"] {
        let text = format!("Maya Chen 10:42 AM\nDid the invoice go out?\nSam Lee 10:43 AM\n{line}");
        let read = reading(
            &stored(SLACK, "billing (Channel) - Northwind - Slack", &text),
            SCREEN,
            Some(SLACK),
            None,
        );
        assert!(kept_in_main(&read, line), "{line}: {read:?}");
    }
    // A message first in the window is not the top bar.
    for text in [
        "Search is down for everyone\nMaya Chen 10:42 AM\nSame here, it times out.".to_owned(),
        format!("Search is down for everyone\nMaya Chen 10:42 AM\nSame here, it times out.{CHROME_SEPARATOR}Northwind > Q Search"),
    ] {
        let read = reading(
            &stored(SLACK, "launch (Channel) - Northwind - Slack", &text),
            SCREEN,
            Some(SLACK),
            None,
        );
        assert!(kept_in_main(&read, "Search is down for everyone"), "{read:?}");
    }
    for line in ["Read", "Delivered", "Read Today"] {
        let text = format!("Sam Lee\nDid you finish the book?\n{line}\nNice\nDelivered\niMessage");
        let read = reading(
            &stored("com.apple.MobileSMS", "Sam Lee", &text),
            SCREEN,
            Some("com.apple.MobileSMS"),
            None,
        );
        assert!(kept_in_main(&read, line), "{line}: {read:?}");
        assert_eq!(lines_of(&read.rest), vec!["Delivered", "iMessage"]);
    }
}

// ---------------------------------------------------------------------------
// Tab strips as older text reads them
// ---------------------------------------------------------------------------

#[test]
fn every_way_a_tab_strip_was_read_leaves_the_rows_first_line() {
    let page = "< > C devnotes.example/rounding \u{2606}\nRounding half to even\nRound half up looks fair, but every tie goes the same way.";
    for (shape, strip) in [
        ("two close buttons", "D Rounding half to even \u{b7} Dev No \u{d7} 31 Northwind - Calen \u{d7} +"),
        ("one close button and an ellipsis", REPORTED_TAB_STRIP),
        ("the reported shape without its ellipsis", "T N 27 Trailhead - Sched \u{d7} \u{2713} Q4 planning - Goo # launch-plan (Channel) - Northwind - Slack"),
        ("one close button, faded titles", "D Rounding half to even \u{b7} Dev No \u{d7} 31 Northwind - Calen # #launch - Slack E Q4 planning - Google Do"),
        ("close buttons read as x", "N How We Price Team Plans - Nor x G per seat vs tiered pricing - Go x +"),
        ("close buttons read as X", "Rounding half to even X Northwind - Calendar X Q4 planning X"),
        ("no close buttons", "Rounding half to even \u{b7} Dev Notes Northwind - Calendar Q4 planning - Google Docs"),
        ("over two lines", "D Rounding half to even \u{b7} Dev No \u{d7} 31 Northwind - Calen\n\u{d7} # #launch - Slack \u{d7} +"),
        ("close buttons read as a circled x", "Rounding half to even \u{2297} Northwind - Calendar \u{2297} Q4 planning \u{2297} +"),
        ("Firefox, X and a new tab", "Stripe Docs X Inbox (12) X Pricing notes X +"),
        ("Firefox, x", "Stripe Docs x Inbox (12) x Pricing notes x"),
    ] {
        let text = format!("{strip}\n{page}");
        let stored = format!(
            "[app={CHROME} | title=Rounding half to even \u{b7} Dev Notes | url=https://devnotes.example/rounding | ts=2026-10-12T14:00:00.000Z]\n{text}"
        );
        let read = reading(&stored, SCREEN, Some(CHROME), None);
        assert!(
            read.main.starts_with("Rounding half to even\nRound half up"),
            "{shape}: {read:?}"
        );
        for line in strip.lines() {
            assert!(read.rest.contains(line), "{shape}: {read:?}");
        }
        assert!(
            reading_prefix(&stored, SCREEN, Some(CHROME), 120).starts_with("Rounding half to even"),
            "{shape}"
        );
        assert_no_word_lost(&text, &read);
    }
}

#[test]
fn safaris_tab_bar_holds_the_open_pages_title() {
    let text = "Pricing notes    Stripe Docs    Inbox (12)\npricingnotes.example\nStripe Docs\nCreate a price with a unit amount and a currency.";
    let read = reading(
        &stored(SAFARI, "Stripe Docs", text),
        SCREEN,
        Some(SAFARI),
        None,
    );
    assert_eq!(
        read.main,
        "Stripe Docs\nCreate a price with a unit amount and a currency."
    );
    assert_eq!(
        lines_of(&read.rest),
        vec![
            "Pricing notes    Stripe Docs    Inbox (12)",
            "pricingnotes.example"
        ]
    );
}

// ---------------------------------------------------------------------------
// Web apps and apps with a side bar
// ---------------------------------------------------------------------------

#[test]
fn web_apps_open_on_what_was_read_not_their_navigation() {
    let tabs = "D Rounding half to even \u{b7} Dev No \u{d7} 31 Northwind - Calen \u{d7} +";
    for (site, title, url, navigation, content) in [
        (
            "Gmail",
            "Re: Invoice 1042 - sam@northwind.example - Northwind Mail",
            "https://mail.google.com/mail/u/0/#inbox/FMfcgzQ",
            "Gmail Q Search mail\nCompose\nInbox 1,204\nStarred\nSnoozed\nSent\nDrafts 3\nMore",
            "Re: Invoice 1042 Inbox \u{d7}\nDana Whitfield <dana@northwind.example>\nThanks for sending this over. The October invoice is attached.",
        ),
        (
            "Calendar",
            "Northwind - Calendar - Week of October 12, 2026",
            "https://calendar.google.com/calendar/u/0/r/week",
            "Calendar Today < > October 2026 Q ? Week\nSUN 11 MON 12 TUE 13 WED 14 THU 15 FRI 16 SAT 17",
            "9 AM\nStandup 9:30 - 9:45am",
        ),
        (
            "GitHub",
            "Round half to even in order_total by sam-lee \u{b7} Pull Request #42 \u{b7} northwind/trailhead-shop",
            "https://github.com/northwind/trailhead-shop/pull/42",
            "northwind / trailhead-shop\nCode Issues 3 Pull requests 1 Actions Projects Security Insights",
            "Round half to even in order_total #42\nOpen sam-lee wants to merge 1 commit into main from round-half-even",
        ),
        (
            "YouTube",
            "How rounding works in payment systems - YouTube",
            "https://www.youtube.com/watch?v=rounding",
            "Home Shorts Subscriptions You History",
            "How rounding works in payment systems\nPayments Weekly \u{b7} 12K views",
        ),
        (
            "LinkedIn",
            "(3) Feed | LinkedIn",
            "https://www.linkedin.com/feed/",
            "in Q Search Home My Network Jobs Messaging Notifications Me For Business",
            "Start a post\nSam Lee \u{b7} 1st\nWe shipped round-half-even totals today.",
        ),
    ] {
        let host = url.trim_start_matches("https://").split('/').next().unwrap();
        let text = format!("{tabs}\n< > C {host} \u{2606}\n{navigation}\n{content}");
        let stored = format!(
            "[app={CHROME} | title={title} | url={url} | ts=2026-10-12T14:00:00.000Z]\n{text}"
        );
        let read = reading(&stored, SCREEN, Some(CHROME), None);
        assert_eq!(read.main, content, "{site}");
        for line in navigation.lines() {
            assert!(read.rest.contains(line), "{site}: {line}");
        }
        assert_no_word_lost(&text, &read);
        assert_rows_agree(&stored, CHROME, &read);
    }
}

#[test]
fn notes_finder_and_system_settings_open_past_their_side_bars() {
    for (app, title, navigation, content) in [
        (
            "com.apple.Notes",
            "Launch checklist",
            "iCloud\nAll iCloud 42\nNotes 38\nQuick Notes 4",
            "Launch checklist\nBeta group told about 0.4\nChangelog drafted",
        ),
        (
            "com.apple.finder",
            "Invoices",
            "Favorites\nAirDrop\nRecents\nApplications\nDownloads\niCloud\niCloud Drive",
            "Invoices\ninvoice-1042.pdf\ninvoice-1043.pdf",
        ),
        (
            "com.apple.systempreferences",
            "Wi-Fi",
            "Q Search\nBluetooth\nNetwork\nNotifications",
            "Wi-Fi\nKnown Networks\nNorthwind Guest",
        ),
    ] {
        let text = format!("{navigation}\n{content}");
        let read = reading(&stored(app, title, &text), SCREEN, Some(app), None);
        assert_eq!(read.main, content, "{app}");
        assert_eq!(lines_of(&read.rest), lines_of(navigation), "{app}");
    }
}

// ---------------------------------------------------------------------------
// Older text reads in paragraphs
// ---------------------------------------------------------------------------

#[test]
fn an_older_pages_wrapped_lines_read_as_paragraphs() {
    let text = "Rounding half to even
Why banker\u{2019}s rounding keeps order totals from drifting by a cent
Priya Shah \u{b7} Oct 12, 2026 \u{b7} 6 min read
Round half up looks fair, but every tie goes the same way. Over thousands of orders the extra
half cents add up, and the books stop matching the bank by a few dollars a month.
Round half to even sends each tie to the even neighbour instead, so half the ties go down and
half go up. The errors cancel out:
round_half_even(2.5) // 2.0
round_half_even(3.5) // 4.0
Most payment processors already round this way. Matching them means the total a customer sees
is the total that settles, to the cent.
Next: Currency math without floats";
    let read = reading(
        &stored(CHROME, "Rounding", text),
        SCREEN,
        Some(CHROME),
        None,
    );
    assert_eq!(
        read.main,
        "Rounding half to even
Why banker\u{2019}s rounding keeps order totals from drifting by a cent
Priya Shah \u{b7} Oct 12, 2026 \u{b7} 6 min read
Round half up looks fair, but every tie goes the same way. Over thousands of orders the extra half cents add up, and the books stop matching the bank by a few dollars a month.
Round half to even sends each tie to the even neighbour instead, so half the ties go down and half go up. The errors cancel out:
round_half_even(2.5) // 2.0
round_half_even(3.5) // 4.0
Most payment processors already round this way. Matching them means the total a customer sees is the total that settles, to the cent.
Next: Currency math without floats"
    );
    assert_rows_agree(&stored(CHROME, "Rounding", text), CHROME, &read);
    // A terminal and a code editor keep their lines.
    for app in ["com.apple.Terminal", VSCODE] {
        let read = reading(&stored(app, "Rounding", text), SCREEN, Some(app), None);
        assert!(
            read.main
                .contains("Over thousands of orders the extra\nhalf cents add up"),
            "{app}: {read:?}"
        );
    }
    // A chat with people joins only a line that fills the line (SPEC 4.3):
    // these wraps reach the window's edge, so they join as on the page, and
    // nothing else does.
    let chat = reading(&stored(SLACK, "Rounding", text), SCREEN, Some(SLACK), None);
    assert!(
        chat.main
            .contains("Over thousands of orders the extra half cents add up"),
        "{chat:?}"
    );
    assert!(
        chat.main.contains(
            "Why banker\u{2019}s rounding keeps order totals from drifting by a cent\nPriya Shah"
        ),
        "{chat:?}"
    );
}

// ---------------------------------------------------------------------------
// Many frames: Safari, Arc, Slack
// ---------------------------------------------------------------------------

fn learn(app: &str, app_frames: &[(&str, String)]) -> RepeatedChrome {
    RepeatedChrome::learn(
        app_frames.iter().map(|(title, text)| Frame {
            title: Some(title),
            text,
        }),
        Some(app),
    )
}

#[test]
fn safari_tab_bar_and_favorites_bar_are_learned_from_three_pages() {
    let tabs = "Per-seat or tiered?    Stripe Docs    Inbox (12)";
    let favorites = "Apple iCloud Google Wikipedia News";
    let pages = [
        (
            "Per-seat or tiered?",
            "Per-seat or tiered?\nMost teams choose between seats and tiers.",
        ),
        (
            "Stripe Docs",
            "Stripe Docs\nCreate a price with a unit amount and a currency.",
        ),
        (
            "Inbox (12)",
            "Inbox\nDana Whitfield sent the invoice for phase two.",
        ),
    ];
    let frames: Vec<(&str, String)> = pages
        .iter()
        .map(|(title, page)| {
            (
                *title,
                format!("{tabs}\npricingnotes.example\n{favorites}\n{page}"),
            )
        })
        .collect();
    let learned = learn(SAFARI, &frames);
    for ((title, text), (_, page)) in frames.iter().zip(&pages) {
        let stored = stored(SAFARI, title, text);
        let read = reading_with(&stored, SCREEN, Some(SAFARI), Some(title), Some(&learned));
        assert_eq!(read.main, *page, "{title}");
        assert_eq!(
            lines_of(&read.rest),
            vec![tabs, "pricingnotes.example", favorites],
            "{title}"
        );
        assert_no_word_lost(text, &read);
        // Without the learned lines, the one-frame rules still find the tab
        // bar, which holds the open page's title among wide gaps, and the
        // address bar; the favorites bar under them stays.
        let alone = reading(&stored, SCREEN, Some(SAFARI), Some(title));
        assert_eq!(
            lines_of(&alone.rest),
            vec![tabs, "pricingnotes.example"],
            "{title}"
        );
        assert!(alone.main.starts_with(favorites), "{title}");
    }
}

#[test]
fn arc_sidebar_is_learned_and_comes_off_a_line_it_was_read_into() {
    let sidebar = [
        "hippocampus.example/docs",
        "Today",
        "Hippocampus docs",
        "Layout ideas",
        "Accent menu",
    ];
    let pages = [
        (
            "Hippocampus docs",
            "Getting started\nInstall with one line in Terminal.",
        ),
        (
            "Layout ideas",
            "Hero section\nThree columns with a pricing table below.",
        ),
        (
            "Accent menu",
            "Typing accents\nPress and hold a letter key, then pick an accent.",
        ),
    ];
    let frames: Vec<(&str, String)> = pages
        .iter()
        .map(|(title, page)| (*title, format!("{}\n{page}", sidebar.join("\n"))))
        .collect();
    let learned = learn(ARC, &frames);
    assert!(
        !learned.contains("Today"),
        "a lone word is never learned: it is as often what someone wrote"
    );
    for ((title, text), (_, page)) in frames.iter().zip(&pages) {
        let read = reading_with(
            &stored(ARC, title, text),
            SCREEN,
            Some(ARC),
            Some(title),
            Some(&learned),
        );
        // The section label stays; the run at the top goes on past it.
        assert_eq!(read.main, format!("Today\n{page}"), "{title}");
        assert_no_word_lost(text, &read);
    }
    // Old text often runs the sidebar into the page's lines.
    let merged = "Today\nLayout ideas Hero section with three columns\nAccent menu The pricing table sits below the fold.";
    let read = reading_with(
        &stored(ARC, "Layout ideas", merged),
        SCREEN,
        Some(ARC),
        None,
        Some(&learned),
    );
    assert_eq!(
        read.main,
        "Today\nHero section with three columns\nThe pricing table sits below the fold."
    );
    assert_eq!(lines_of(&read.rest), vec!["Layout ideas", "Accent menu"]);
    assert_no_word_lost(merged, &read);
}

#[test]
fn slack_channel_list_is_learned_and_messages_keep_their_words() {
    let frames: Vec<(&str, String)> = [
        (
            "general (Channel) - Northwind - Slack",
            "Lunch is at noon on Friday.",
        ),
        (
            "design-review (Channel) - Northwind - Slack",
            "Can someone check the copy before 3 PM?",
        ),
        (
            "launch-plan (Channel) - Northwind - Slack",
            "Shipping 0.3 after lunch.",
        ),
    ]
    .iter()
    .map(|(title, message)| {
        (
            *title,
            format!("# general\n# design-review\n# launch-plan\n{message}"),
        )
    })
    .collect();
    let learned = learn(SLACK, &frames);
    assert!(learned.contains("# general") && learned.contains("# launch-plan"));
    assert!(!learned.contains("Shipping 0.3 after lunch."));
    let old = "       # general Pushed the new onboarding flow to staging.\n       # design-review Can someone check the copy?";
    let read = reading_with(
        &stored(SLACK, "launch-plan (Channel) - Northwind - Slack", old),
        SCREEN,
        Some(SLACK),
        None,
        Some(&learned),
    );
    assert_eq!(
        read.main,
        "Pushed the new onboarding flow to staging.\nCan someone check the copy?"
    );
    assert_eq!(lines_of(&read.rest), vec!["# general", "# design-review"]);
    assert_no_word_lost(old, &read);
}

#[test]
fn a_document_shown_for_an_hour_under_one_title_loses_nothing() {
    // The same paragraphs in forty frames of one document: they recur, but
    // under one title, so none of them is chrome.
    let text = "Launch plan\nThe beta opens on October 21.\nPricing: Team at $18 a seat.";
    let frames: Vec<(&str, String)> = (0..40).map(|_| ("Launch plan", text.to_owned())).collect();
    let learned = learn("com.apple.Notes", &frames);
    assert!(learned.is_empty());
    let read = reading_with(
        &stored("com.apple.Notes", "Launch plan", text),
        SCREEN,
        Some("com.apple.Notes"),
        None,
        Some(&learned),
    );
    assert_eq!(read.main, text);
}

#[test]
fn a_line_that_changes_is_never_learned() {
    // A clock in the corner changes every frame; a page's text changes with
    // the page. Neither is ever chrome by the many-frame rule.
    let frames: Vec<(&str, String)> = (0..12)
        .map(|n| {
            let title = ["One", "Two", "Three"][n % 3];
            (
                title,
                format!("Updated 10:{n:02} AM\nParagraph {n} of the page."),
            )
        })
        .collect();
    let learned = learn(CHROME, &frames);
    assert!(learned.is_empty(), "{learned:?}");
}

// ---------------------------------------------------------------------------
// Property: chrome moves, nothing is lost
// ---------------------------------------------------------------------------

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
    "OK",
    "5",
    "GB",
    "seat,",
    "known",
    "(Ravi)",
    "x",
    "X",
    "=",
    "{",
    "}",
    "->",
    "$18",
    "12:31",
    "+",
    "\u{d7}",
    "caf\u{e9}",
    "<",
    "Tuesday.",
    "and",
    "colleagues",
    "--",
    "p...",
    "M\u{2026}",
    "example.org/page",
    "Search",
    "EXPLORER",
    "Message",
    "#launch-plan",
    "Ln",
    "14,",
    "Col",
    "37",
    ">",
    "Threads",
    "All",
    "Bookmarks",
];

const CHROME_LIKE: &[&str] = &[
    REPORTED_TAB_STRIP,
    "< > C example.org/page \u{2606}",
    "Gmail Maps All Bookmarks",
    "File Edit View Insert Format Tools Extensions Help",
    "All Images Videos News More Tools",
    "Share",
    "Dev Notes Articles Topics About Subscribe",
    "Delivered",
    "iMessage",
    "EXPLORER",
    "Ln 3, Col 9 UTF-8",
    "a > b > c",
    "Message #general",
    "Direct messages",
];

#[test]
fn chrome_moves_and_no_word_is_ever_lost() {
    let mut rng = Lcg(42);
    let apps = [CHROME, SAFARI, ARC, VSCODE, SLACK, "com.apple.MobileSMS"];
    for case in 0..1_500 {
        let mut lines = Vec::new();
        for _ in 0..=rng.below(12) {
            if rng.below(5) == 0 {
                lines.push(rng.pick(CHROME_LIKE).to_owned());
                continue;
            }
            if rng.below(7) == 0 {
                lines.push(String::new());
                continue;
            }
            let words: Vec<&str> = (0..=rng.below(8)).map(|_| rng.pick(WORDS)).collect();
            lines.push(words.join(" "));
        }
        let text = lines.join("\n");
        let app = apps[usize::try_from(rng.below(apps.len() as u64)).unwrap()];
        let stored = stored(app, "Example", &text);
        let read = reading(&stored, SCREEN, Some(app), None);
        assert_no_word_lost(&text, &read);
        assert!(
            !read.main.contains('\u{1e}') && !read.rest.contains('\u{1e}'),
            "case {case}"
        );
        // A list row is the start of `main`, or of `rest` when `main` is empty.
        let shown = if read.main.is_empty() {
            &read.rest
        } else {
            &read.main
        };
        assert_eq!(
            reading_prefix(&stored, SCREEN, Some(app), 280),
            shown.chars().take(280).collect::<String>(),
            "case {case}\n{text:?}"
        );
    }
}
