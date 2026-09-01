//! Is the retrieval score usable as a confidence signal?
//!
//! # The finding this exists to document
//!
//! No, not the fused one. Measured against a real 1,909-event brain, the
//! ADR-0010 fused score ranks questions the brain *cannot* answer ABOVE
//! ones it can:
//!
//! ```text
//!   "what is the capital of Mongolia?"   0.635   <- nothing about it
//!   "who won the 1978 World Cup?"        0.575   <- nothing about it
//!   "why can't we sign the app?"         0.487   <- correct answer, ranked lower
//! ```
//!
//! That is not a bug in fusion, it is what min-max normalization means.
//! Normalization is per query: it rescales that query's own candidate set
//! so the best candidate lands near 1 and the worst near 0. Every query
//! therefore produces a similar-looking top score whether or not anything
//! relevant exists. The number is a *within-query rank*, and reading it
//! as a *cross-query confidence* is a category error.
//!
//! This matters because "return nothing when you know nothing" is the
//! single most valuable behaviour a memory can have, and the obvious
//! implementation — threshold the score recall already returns — would
//! have filtered out correct answers while keeping confident nonsense.
//!
//! # What is calibrated
//!
//! The raw semantic cosine, before fusion touches it, separates cleanly:
//!
//! ```text
//!   in-brain       0.6165 .. 0.7078
//!   not-in-brain   0.5279 .. 0.6022
//! ```
//!
//! Cosine between a query and a document embedding means the same thing
//! from one query to the next, so it survives the comparison that the
//! normalized score cannot. A relevance floor should be built on this.
//!
//! The sample here is eight questions, which is enough to show the
//! mechanism and not enough to fix a threshold. Pick the number from the
//! benchmark, not from this file.
//!
//! Run:
//! ```sh
//! MCI_DB_KEY_HEX=$(cat ~/Library/Application\ Support/MCI/dev.key) \
//!   cargo run --release -p mci-agent --example score_probe
//! ```

use std::sync::Arc;

use mci_brain::{BrainStore, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

fn main() {
    let key_hex = std::env::var("MCI_DB_KEY_HEX").expect("MCI_DB_KEY_HEX");
    let mut key = [0u8; 32];
    for (i, b) in key.iter_mut().enumerate() {
        *b = u8::from_str_radix(&key_hex[i * 2..i * 2 + 2], 16).expect("hex");
    }
    let home = std::env::var("HOME").unwrap();
    let db = std::path::PathBuf::from(&home).join("Library/Application Support/MCI/mci.sqlite");
    let store = Arc::new(
        SqlCipherBrainStore::open_readonly(&db, &DbKey::from_bytes(key)).expect("open brain"),
    );

    let (emb, is_real) = mci_agent::embedder_load::load_query_embedder_backend();
    assert!(is_real, "need the real embedder");

    let cases: &[(&str, bool)] = &[
        ("why can't we sign the app?", true),
        ("what broke screen capture?", true),
        ("what is the Apple team ID?", true),
        ("what did we decide about the daily streak repo?", true),
        ("what is the capital of Mongolia?", false),
        ("how do I bake sourdough bread?", false),
        ("who won the 1978 World Cup?", false),
        ("what is the airspeed velocity of a swallow?", false),
    ];

    println!(
        "{:<48} {:>8} {:>8} {:>8}",
        "query", "top", "mean3", "in-brain"
    );
    for (q, in_brain) in cases {
        let v = emb.embed_one(q).expect("embed");
        let hits = store.vec_search(&v, 3).expect("vec_search");
        let top = hits.first().map_or(0.0, |h| h.1);
        let mean3 = if hits.is_empty() {
            0.0
        } else {
            hits.iter().map(|h| h.1).sum::<f32>() / hits.len() as f32
        };
        println!("{q:<48} {top:>8.4} {mean3:>8.4} {:>8}", in_brain);
    }
}
