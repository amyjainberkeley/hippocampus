//! SPEC 4.11's budget for `reading_blocks::blocks`, in a test binary of its
//! own: the golden and property tests beside it in `reading_blocks.rs` keep
//! every core busy while they run, which no timing survives.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use mci_brain::reading::body;
use mci_brain::reading_blocks::{blocks, Window};
use mci_brain::EventSource;

#[test]
fn blocks_of_a_64_kb_reading_take_under_2_ms() {
    // SPEC 4.11's budget is for a release build on an M1; a debug build is
    // about twenty times slower. The best of ten keeps a busy machine from
    // failing it.
    let stored = std::fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/reading/blocks/article.old.txt"),
    )
    .unwrap();
    let article = body(&stored).to_owned();
    let mut main = String::new();
    while main.len() < 64 * 1024 {
        main.push_str(&article);
        main.push_str("\n\n");
    }
    let window = Window {
        app: Some("com.google.Chrome"),
        title: Some("Rounding half to even \u{b7} Dev Notes"),
        url: Some("https://devnotes.example/rounding"),
    };
    let budget = if cfg!(debug_assertions) {
        Duration::from_millis(60)
    } else {
        Duration::from_millis(2)
    };
    let best = (0..10)
        .map(|_| {
            let started = Instant::now();
            let made = blocks(&main, &window, EventSource::ScreenOcr);
            assert!(!made.is_empty());
            started.elapsed()
        })
        .min()
        .unwrap();
    eprintln!("blocks of {} KB: best of ten {best:?}", main.len() / 1024);
    assert!(best < budget, "blocks of 64 KB took {best:?}");
}
