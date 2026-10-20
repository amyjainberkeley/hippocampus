//! A reading's text as blocks (`mci_brain::reading_blocks`, SPEC 4.2 and
//! 4.11): nothing is invented, nothing that was read is lost, and the same
//! reading always gives the same blocks.

use mci_brain::reading_blocks::{blocks, markdown, Block, Window};
use mci_brain::EventSource;

const ARTICLE: &str = "Rounding half to even\nRound half up looks fair, but every tie goes the same way.\n\nMost payment processors already round this way.";

fn window() -> Window<'static> {
    Window {
        app: Some("com.google.Chrome"),
        title: Some("Rounding half to even \u{00B7} Dev Notes"),
        url: Some("https://devnotes.example/rounding"),
    }
}

/// Every word of every block was read: blocks only split and mark text.
fn words(text: &str) -> Vec<&str> {
    text.split_whitespace().collect()
}

#[test]
fn a_reading_with_no_text_has_no_blocks() {
    for main in ["", " ", "\n\n", "\t \n"] {
        assert!(
            blocks(main, &window(), EventSource::ScreenOcr).is_empty(),
            "{main:?}"
        );
    }
}

#[test]
fn no_block_holds_a_word_that_was_not_read() {
    let made = blocks(ARTICLE, &window(), EventSource::BrowserPage);
    assert!(!made.is_empty());
    let read = words(ARTICLE);
    for block in &made {
        for word in words(block.text()) {
            assert!(read.contains(&word), "{word} was never read");
        }
    }
}

#[test]
fn every_word_that_was_read_is_in_a_block() {
    let made = blocks(ARTICLE, &window(), EventSource::ScreenOcr);
    let held: Vec<&str> = made.iter().flat_map(|block| words(block.text())).collect();
    assert_eq!(held, words(ARTICLE));
}

#[test]
fn the_same_reading_gives_the_same_blocks() {
    let first = blocks(ARTICLE, &window(), EventSource::ScreenOcr);
    let second = blocks(ARTICLE, &window(), EventSource::ScreenOcr);
    assert_eq!(first, second);
    assert_eq!(markdown(&first), markdown(&second));
}

#[test]
fn markdown_keeps_every_word_in_order() {
    let made = blocks(ARTICLE, &window(), EventSource::ScreenOcr);
    let text = markdown(&made);
    let kept: Vec<&str> = words(&text)
        .into_iter()
        .filter(|word| word.chars().any(char::is_alphanumeric))
        .collect();
    let read: Vec<&str> = words(ARTICLE)
        .into_iter()
        .filter(|word| word.chars().any(char::is_alphanumeric))
        .collect();
    assert_eq!(kept, read);
}

#[test]
fn a_paragraph_holds_its_text_as_read() {
    let block = Block::Paragraph {
        text: "Per-seat pricing grows with the customer.".into(),
    };
    assert_eq!(block.text(), "Per-seat pricing grows with the customer.");
    assert_eq!(
        markdown(&[block]),
        "Per-seat pricing grows with the customer."
    );
}
