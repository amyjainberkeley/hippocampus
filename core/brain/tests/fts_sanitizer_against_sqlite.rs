//! Execute sanitized queries against a real FTS5 table.
//!
//! # Why this file exists
//!
//! `sanitize_fts5_query`'s unit tests assert the *shape* of the string it
//! returns. Every one of them passed while the function was emitting
//! queries FTS5 rejects outright, because three of those expectations had
//! been written from what the function did rather than from what `SQLite`
//! accepts. `what did I do?` reached the engine as a bareword and came
//! back as `fts5: syntax error near "?"`, so `mci_recall` returned an
//! error instead of results for most natural questions.
//!
//! Asserting on the output string cannot catch that. Only running it can.
//! So this file feeds the sanitizer realistic input and executes the
//! result, which is the property that actually matters: whatever comes
//! out of the sanitizer, `SQLite` will run it.

use mci_brain::fts_sanitizer::sanitize_fts5_query;
use rusqlite::Connection;

fn corpus() -> Connection {
    let conn = Connection::open_in_memory().expect("open in-memory sqlite");
    conn.execute_batch(
        "CREATE VIRTUAL TABLE t USING fts5(body);
         INSERT INTO t VALUES ('hello world screen capture');
         INSERT INTO t VALUES ('state of the art design work');
         INSERT INTO t VALUES ('the meeting cost 50 percent more');",
    )
    .expect("create fts5 table");
    conn
}

/// Every one of these is something a person plausibly types into recall.
const REALISTIC_QUERIES: &[&str] = &[
    // The case that broke recall in production.
    "what did I do?",
    "what did I work on yesterday?",
    "why did that fail?",
    // Contractions: an apostrophe is a syntax error bare.
    "what's next",
    "don't stop",
    "the client's request",
    // Ordinary sentence punctuation.
    "hi!",
    "the end.",
    "a, b, and c",
    "why not; really",
    "50% done",
    "cost is $5",
    "re-run the build",
    "state-of-the-art",
    // Things the sanitizer already handled, kept so the widened rule
    // cannot regress them.
    "https://example.com/a/b",
    "someone@example.com",
    "column:value",
    "a (b) c",
    "star * search",
    "caret ^ token",
    "quote \" inside",
    // Uppercase words from pasted text must not become boolean syntax.
    "AND",
    "OR",
    "NOT",
    "AND screen",
    "screen OR",
    "screen AND NOT capture",
    "\"screen NOT capture\"",
    "\"src/cache.rs NOT failed\"",
    // Structural edge cases.
    "",
    "   ",
    "?",
    "!!!",
    "---",
    "hello @ world",
    "hello &amp; world",
    // Non-ASCII must not be mangled into an error either.
    "café über",
    "検索クエリ",
    "emoji 🧠 memory",
];

#[test]
fn every_sanitized_query_executes() {
    let conn = corpus();
    let mut failures: Vec<String> = Vec::new();

    for raw in REALISTIC_QUERIES {
        let sanitized = sanitize_fts5_query(raw);
        if sanitized.trim().is_empty() {
            // Callers treat an empty sanitization as "no lexical arm",
            // and never hand it to SQLite.
            continue;
        }
        let mut stmt = conn
            .prepare("SELECT count(*) FROM t WHERE t MATCH ?1")
            .expect("prepare");
        if let Err(e) = stmt.query_row([&sanitized], |r| r.get::<_, i64>(0)) {
            failures.push(format!("  {raw:?} -> {sanitized:?} -> {e}"));
        }
    }

    assert!(
        failures.is_empty(),
        "sanitized queries must always be executable by FTS5, but {} failed:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

/// The sanitizer must not quietly destroy recall while making queries
/// legal. Stripping every token would also pass the test above.
///
/// Note on how these are phrased: FTS5 implicitly ANDs the terms of a
/// query, so a full natural question ("what about screen capture?")
/// matches nothing unless the document happens to contain "what" and
/// "about" too. That is FTS5 working as designed, not the sanitizer
/// dropping content, and it is why the lexical-only arm of the retrieval
/// benchmark scores near zero on conversational questions. These cases
/// therefore use terms that genuinely appear in the corpus.
#[test]
fn sanitizing_preserves_the_ability_to_match() {
    let conn = corpus();
    let cases: &[(&str, &str)] = &[
        ("screen capture", "plain terms still match"),
        ("screen capture?", "a trailing '?' must not kill the match"),
        (
            "state-of-the-art",
            "a hyphenated phrase must still find its row",
        ),
        ("hello world", "untouched queries are unaffected"),
    ];

    for (raw, why) in cases {
        let sanitized = sanitize_fts5_query(raw);
        let n: i64 = conn
            .prepare("SELECT count(*) FROM t WHERE t MATCH ?1")
            .expect("prepare")
            .query_row([&sanitized], |r| r.get(0))
            .unwrap_or_else(|e| panic!("{raw:?} -> {sanitized:?}: {e}"));
        assert!(n > 0, "{why}: {raw:?} -> {sanitized:?} matched nothing");
    }
}

#[test]
fn boolean_words_in_pasted_text_are_literal_search_terms() {
    let conn = corpus();
    for body in [
        "screen AND capture",
        "screen OR capture",
        "screen NOT capture",
        "src/cache.rs NOT failed",
        "src/cache.rs failed",
        "src/cache.rs",
    ] {
        conn.execute("INSERT INTO t(body) VALUES (?1)", [body])
            .expect("insert synthetic text");
    }

    let cases = [
        ("AND", "screen AND capture"),
        ("OR", "screen OR capture"),
        ("screen NOT capture", "screen NOT capture"),
        ("screen AND capture", "screen AND capture"),
        ("screen OR capture", "screen OR capture"),
        ("\"screen NOT capture\"", "screen NOT capture"),
        ("\"screen AND capture\"", "screen AND capture"),
        ("\"screen OR capture\"", "screen OR capture"),
        ("src/cache.rs NOT failed", "src/cache.rs NOT failed"),
        ("\"src/cache.rs NOT failed\"", "src/cache.rs NOT failed"),
    ];
    let mut failures = Vec::new();
    for (raw, expected) in cases {
        let sanitized = sanitize_fts5_query(raw);
        let result = conn
            .prepare("SELECT body FROM t WHERE t MATCH ?1 ORDER BY rowid")
            .expect("prepare")
            .query_map([&sanitized], |row| row.get::<_, String>(0))
            .expect("bind query")
            .collect::<Result<Vec<_>, _>>();
        match result {
            Ok(bodies) if bodies == [expected] => {}
            result => failures.push(format!(
                "{raw:?}: expected only {expected:?}, got {result:?}"
            )),
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// Pin the exact failure that shipped, so it cannot come back quietly.
#[test]
fn the_question_mark_regression_stays_fixed() {
    let conn = corpus();
    let raw = "what did I do?";

    let bare = conn
        .prepare("SELECT count(*) FROM t WHERE t MATCH ?1")
        .expect("prepare")
        .query_row([raw], |r| r.get::<_, i64>(0));
    assert!(
        bare.is_err(),
        "unsanitized {raw:?} is expected to be an FTS5 syntax error; \
         if SQLite has started accepting it, this guard is no longer \
         proving anything and should be revisited"
    );

    let sanitized = sanitize_fts5_query(raw);
    conn.prepare("SELECT count(*) FROM t WHERE t MATCH ?1")
        .expect("prepare")
        .query_row([&sanitized], |r| r.get::<_, i64>(0))
        .expect("the sanitized form must execute");
}
