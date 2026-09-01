//! FTS5 query sanitizer — prevents raw user queries from panicking the
//! retriever when they contain `SQLite` FTS5 syntax metacharacters.
//!
//! # The bug this closes
//!
//! Cycle 8.55 PR #111 uncovered a production panic: a user searching
//! for a URL (`https://arxiv.org/abs/1234`) triggered
//! `row fts5: no such column: https` from `events_fts MATCH ?1`. `SQLite`
//! FTS5's MATCH grammar (`docs.sqlite.org/fts5.html §3`) parses
//! `column:term` as a column-restricted match — so `https:` gets read
//! as the (non-existent) column name `https`, aborting the query and
//! bubbling a `StoreError::Backend` up through the retriever.
//!
//! # Fix — pre-parse phrase-wrapping
//!
//! Sanitizing the query BEFORE it hits `MATCH` is the right layer:
//! FTS5 offers no runtime "treat literally" flag, but wrapping a
//! token in double quotes turns it into an unambiguous *phrase*
//! (`"https://arxiv.org"`), which the tokenizer then splits on non-
//! wordchar boundaries and matches as an AND of the resulting terms.
//! Column-qualifier parsing does not run inside a quoted phrase, so
//! the panic is impossible by construction after this pass.
//!
//! # Scope
//!
//! Pure `&str -> String` function, no I/O, no allocations beyond the
//! output. Preserves clean keyword queries verbatim (no-op fast path)
//! so normal recall paths stay byte-identical to the pre-fix behavior.
//! Only phrase-wraps tokens that *would* trigger FTS5 syntax:
//!
//! - URL-like tokens (`://` present) → phrase-wrap the whole
//!   whitespace-delimited token.
//! - Email-like tokens (`@` between two word-ish sides) → phrase-wrap.
//! - Tokens containing a standalone `:` (the `column:term` panic
//!   trigger) → phrase-wrap.
//! - Tokens containing an FTS5-reserved metacharacter that would
//!   otherwise be parsed as an operator (`"` `(` `)` `*` `^`) →
//!   phrase-wrap (and double-any internal `"` per the FTS5 phrase
//!   escape convention).
//!
//! # OS-purity
//!
//! Nothing OS-specific — pure Rust on `&str`. Composes with any
//! `BrainStore` impl; the in-memory stub sees the same sanitized
//! string, but its substring matcher is a no-op on the added quotes
//! (they never appear inside stored event text). Ranking / scoring
//! is untouched — this is a pre-parse fix, not a retrieval-shape
//! change.

/// Sanitize a raw user query for safe substitution into an FTS5
/// `MATCH` expression.
///
/// The output is a valid FTS5 MATCH string that will not trigger the
/// `no such column: <token>` panic on URL / email / colon-token
/// input. Clean keyword queries pass through unchanged (byte-identical),
/// so callers can invoke this unconditionally on the retrieval hot path.
///
/// # Examples
///
/// ```
/// use mci_brain::fts_sanitizer::sanitize_fts5_query;
///
/// // Clean keyword query — unchanged.
/// assert_eq!(sanitize_fts5_query("hello world"), "hello world");
///
/// // URL — phrase-wrapped.
/// assert_eq!(
///     sanitize_fts5_query("https://arxiv.org/abs/1234"),
///     "\"https://arxiv.org/abs/1234\"",
/// );
///
/// // Mixed — only the URL token is wrapped.
/// assert_eq!(
///     sanitize_fts5_query("find the article about https://arxiv.org/abs/1234"),
///     "find the article about \"https://arxiv.org/abs/1234\"",
/// );
/// ```
#[must_use]
pub fn sanitize_fts5_query(raw: &str) -> String {
    // Fast path: if the input contains none of the trigger characters
    // and none of the FTS5 operator characters, it is guaranteed a
    // no-op sanitization. Keeps normal keyword queries byte-identical
    // to the pre-fix behavior (zero-copy semantics, one allocation
    // for the returned String).
    if !needs_sanitization(raw) {
        return raw.to_string();
    }

    // Whitespace-delimited pass. FTS5's tokenizer treats runs of
    // whitespace as term separators; we mirror that boundary so a
    // wrapped token can never bleed into its neighbor. `split_whitespace`
    // is Unicode-aware (uses `char::is_whitespace`), matching the
    // "handle Unicode properly" constraint from the mission.
    let mut out = String::with_capacity(raw.len() + 8);
    let mut first = true;
    for tok in raw.split_whitespace() {
        if !first {
            out.push(' ');
        }
        first = false;
        if token_needs_wrap(tok) {
            push_phrase_wrapped(&mut out, tok);
        } else {
            out.push_str(tok);
        }
    }
    out
}

/// Cheap pre-scan: does the input contain any character that could
/// possibly need sanitization? If not, the fast-path return above
/// keeps clean queries byte-identical.
///
/// This used to list a handful of operator characters. That was far too
/// narrow: FTS5 accepts only alphanumerics and non-ASCII inside a
/// bareword, and raises a syntax error on essentially every other ASCII
/// punctuation mark. Thirty of the thirty-five ASCII punctuation
/// characters fail, `?` and `'` among them, so `what did I do?` and
/// `what's next` both errored out of recall entirely.
fn needs_sanitization(s: &str) -> bool {
    s.bytes()
        .any(|b| !is_bareword_byte(b) && !b.is_ascii_whitespace())
}

/// Bytes FTS5 will accept unquoted inside a bareword.
///
/// Alphanumerics, underscore, and anything non-ASCII (continuation and
/// lead bytes of a multi-byte UTF-8 sequence are all >= 0x80, so accented
/// and CJK text is left alone rather than being needlessly quoted).
const fn is_bareword_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b >= 0x80
}

/// Does this individual whitespace-delimited token need phrase-wrapping?
///
/// The rules mirror the module-level doc: URL-ish, email-ish, colon-
/// bearing, or contains any FTS5 operator metacharacter.
fn token_needs_wrap(tok: &str) -> bool {
    if tok.is_empty() {
        return false;
    }
    // URL: any occurrence of "://" — the panic-trigger case.
    if tok.contains("://") {
        return true;
    }
    // Email-ish: "@" with non-empty local and domain sides.
    if let Some(idx) = tok.find('@') {
        let (lhs, rhs) = tok.split_at(idx);
        let rhs = &rhs[1..];
        if !lhs.is_empty() && !rhs.is_empty() {
            return true;
        }
    }
    // Any colon — `column:term` parsing is the whole point of this
    // sanitizer.
    if tok.contains(':') {
        return true;
    }
    // Anything FTS5 will not accept in a bareword. This covers the
    // operator metacharacters (`"` `(` `)` `*` `^`) that were listed
    // here before, and also the ordinary punctuation that is far more
    // common in a real question: `?` `!` `.` `,` `'` `-` `%` and the
    // rest. Each of those is a syntax error to FTS5, not a no-op.
    //
    // Wrapping rather than stripping, because wrapping is what the rest
    // of this module already does and it is the conservative choice: a
    // wrapped token matches the terms it tokenizes into, in order, so
    // `"what's"` finds `what s` adjacent and `"do?"` finds `do`. A token
    // that tokenizes to nothing becomes an empty phrase, which FTS5
    // ignores rather than treating as an unsatisfiable AND term.
    if tok.bytes().any(|b| !is_bareword_byte(b)) {
        return true;
    }
    false
}

/// Push `tok` into `out` wrapped in FTS5 phrase quotes, doubling any
/// internal `"` per the FTS5 escape convention
/// (`docs.sqlite.org/fts5.html §3` — "A string is a sequence of
/// characters enclosed in double-quote characters. To include a
/// double-quote character in a string, escape it as two doubles.").
fn push_phrase_wrapped(out: &mut String, tok: &str) {
    out.push('"');
    for ch in tok.chars() {
        if ch == '"' {
            out.push('"');
            out.push('"');
        } else {
            out.push(ch);
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- the regression that made recall unusable ------------------
    //
    // Claude Code hands `mci_recall` whatever the user typed, and people
    // type questions. Every one of these produced
    // `fts5: syntax error near "?"` (or `'`, or `!`, ...) before the
    // sanitizer covered the whole non-bareword set, which meant the tool
    // returned an error rather than results for most real queries.

    #[test]
    fn a_trailing_question_mark_is_handled() {
        assert_eq!(
            sanitize_fts5_query("what did I do?"),
            "what did I \"do?\"",
            "a question ending in '?' is the single most common recall query"
        );
    }

    #[test]
    fn apostrophes_are_handled() {
        assert_eq!(sanitize_fts5_query("what's next"), "\"what's\" next");
        assert_eq!(sanitize_fts5_query("don't stop"), "\"don't\" stop");
    }

    #[test]
    fn ordinary_sentence_punctuation_is_handled() {
        for raw in [
            "hi!",
            "50% done",
            "the end.",
            "a, b",
            "re-run it",
            "cost is $5",
            "a/b",
            "why not; really",
        ] {
            let out = sanitize_fts5_query(raw);
            assert!(
                out.contains('"'),
                "{raw:?} contains punctuation FTS5 rejects and must be wrapped, got {out:?}"
            );
        }
    }

    #[test]
    fn clean_queries_are_still_untouched() {
        for raw in [
            "hello world",
            "screen capture",
            "abc123 def_456",
            "café über",
        ] {
            assert_eq!(
                sanitize_fts5_query(raw),
                raw,
                "{raw:?} needs no sanitization and must pass through byte-identical"
            );
        }
    }

    #[test]
    fn every_ascii_punctuation_mark_survives_a_round_trip() {
        // Empirically, 30 of these 32 are a hard syntax error to FTS5 when
        // left bare. Rather than encode which, assert the invariant that
        // matters: after sanitization no token is left bare with one.
        for c in "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".chars() {
            let raw = format!("screen{c} capture");
            let out = sanitize_fts5_query(&raw);
            if c == '_' {
                assert_eq!(out, raw, "'_' is a legal bareword byte");
                continue;
            }
            assert!(out.starts_with('"'), "{raw:?} must be wrapped, got {out:?}");
        }
    }

    // --- fast-path: clean queries stay byte-identical ---------------

    #[test]
    fn empty_input_is_empty_output() {
        assert_eq!(sanitize_fts5_query(""), "");
    }

    #[test]
    fn single_word_passes_through() {
        assert_eq!(sanitize_fts5_query("hello"), "hello");
    }

    #[test]
    fn multi_word_passes_through() {
        assert_eq!(sanitize_fts5_query("hello world"), "hello world");
    }

    #[test]
    fn hyphenated_token_is_wrapped() {
        // This test used to assert pass-through, on the belief that FTS5
        // "tokenizes hyphens as separators but does not error". It does
        // error: `state-of-the-art` raises `no such column: of`, because
        // `-` introduces a column filter. The expectation was written
        // from what the function did rather than from what FTS5 accepts.
        assert_eq!(
            sanitize_fts5_query("state-of-the-art"),
            "\"state-of-the-art\""
        );
    }

    #[test]
    fn unicode_keyword_passes_through() {
        assert_eq!(sanitize_fts5_query("café résumé"), "café résumé");
    }

    // --- URL cases: the primary bug ---------------------------------

    #[test]
    fn https_url_is_phrase_wrapped() {
        assert_eq!(
            sanitize_fts5_query("https://arxiv.org/abs/1234"),
            "\"https://arxiv.org/abs/1234\"",
        );
    }

    #[test]
    fn http_url_is_phrase_wrapped() {
        assert_eq!(
            sanitize_fts5_query("http://example.com"),
            "\"http://example.com\"",
        );
    }

    #[test]
    fn url_inside_sentence_only_wraps_the_url() {
        assert_eq!(
            sanitize_fts5_query("find the article about https://arxiv.org/abs/1234"),
            "find the article about \"https://arxiv.org/abs/1234\"",
        );
    }

    #[test]
    fn multiple_urls_each_wrapped_independently() {
        assert_eq!(
            sanitize_fts5_query("https://a.com and https://b.org"),
            "\"https://a.com\" and \"https://b.org\"",
        );
    }

    #[test]
    fn unicode_url_is_phrase_wrapped() {
        // Real-world: user pastes a Wikipedia URL with a non-ASCII slug.
        assert_eq!(
            sanitize_fts5_query("https://en.wikipedia.org/wiki/Café"),
            "\"https://en.wikipedia.org/wiki/Café\"",
        );
    }

    // --- email cases -------------------------------------------------

    #[test]
    fn email_is_phrase_wrapped() {
        assert_eq!(
            sanitize_fts5_query("amy@newtandem.com"),
            "\"amy@newtandem.com\"",
        );
    }

    #[test]
    fn email_inside_sentence_only_wraps_the_email() {
        assert_eq!(
            sanitize_fts5_query("email amy@newtandem.com about it"),
            "email \"amy@newtandem.com\" about it",
        );
    }

    #[test]
    fn bare_at_symbol_is_wrapped() {
        // Previously asserted pass-through because a lone `@` is not
        // email-ish. Being email-ish was never the question: FTS5 rejects
        // a bare `@` outright with `syntax error near "@"`.
        assert_eq!(sanitize_fts5_query("hello @ world"), "hello \"@\" world");
    }

    // --- colon cases: the panic trigger -----------------------------

    #[test]
    fn keyvalue_colon_is_phrase_wrapped() {
        // `key:value` would be parsed by FTS5 as column `key`
        // matching `value` — panics if `key` is not a real column.
        assert_eq!(sanitize_fts5_query("timezone:PST"), "\"timezone:PST\"",);
    }

    #[test]
    fn timestamp_colon_is_phrase_wrapped() {
        assert_eq!(sanitize_fts5_query("14:30"), "\"14:30\"");
    }

    #[test]
    fn trailing_colon_is_phrase_wrapped() {
        assert_eq!(sanitize_fts5_query("note:"), "\"note:\"");
    }

    // --- FTS5 operator metacharacters -------------------------------

    #[test]
    fn embedded_double_quote_is_escaped() {
        // User pastes something with a literal `"` — must be doubled
        // inside the phrase wrapping (FTS5 escape convention).
        assert_eq!(sanitize_fts5_query("foo\"bar"), "\"foo\"\"bar\"",);
    }

    #[test]
    fn asterisk_in_token_is_phrase_wrapped() {
        // `foo*` is FTS5 prefix syntax — wrapping neutralizes it so
        // user queries containing `*` in the middle of a token do not
        // silently become prefix matches.
        assert_eq!(sanitize_fts5_query("foo*bar"), "\"foo*bar\"");
    }

    #[test]
    fn parens_in_token_are_phrase_wrapped() {
        assert_eq!(sanitize_fts5_query("foo(bar)"), "\"foo(bar)\"");
    }

    // --- edge cases -------------------------------------------------

    #[test]
    fn all_whitespace_passes_through_on_fast_path() {
        // No metacharacters → fast path returns the input verbatim.
        // Whitespace collapse happens downstream only if the token
        // walk is triggered by a metachar hit.
        assert_eq!(sanitize_fts5_query("   \t\n"), "   \t\n");
    }

    #[test]
    fn leading_and_trailing_whitespace_preserved_on_fast_path() {
        // Fast path — clean tokens, no metacharacters → byte-identical.
        assert_eq!(sanitize_fts5_query("  hello  world  "), "  hello  world  ");
    }

    #[test]
    fn whitespace_collapses_on_metachar_slow_path() {
        // Once a metachar is present the token walk runs and
        // `split_whitespace` collapses runs to single spaces. This is
        // acceptable — FTS5 treats runs of whitespace identically to
        // a single space in MATCH grammar, so the change of shape is
        // semantically a no-op.
        assert_eq!(
            sanitize_fts5_query("  hello   https://a.com  "),
            "hello \"https://a.com\"",
        );
    }

    #[test]
    fn single_char_token_passes_through() {
        assert_eq!(sanitize_fts5_query("a"), "a");
    }

    #[test]
    fn html_entity_looking_input_is_wrapped() {
        // `&` was not in the old metacharacter list, so this passed
        // through and then failed with `syntax error near "&"`. "Not a
        // metacharacter" and "legal in a bareword" are different sets,
        // and only the second one matters.
        assert_eq!(
            sanitize_fts5_query("hello &amp; world"),
            "hello \"&amp;\" world"
        );
    }

    #[test]
    fn mixed_urls_emails_and_keywords() {
        assert_eq!(
            sanitize_fts5_query("see https://a.com or email me@x.io re foo"),
            "see \"https://a.com\" or email \"me@x.io\" re foo",
        );
    }

    #[test]
    fn sanitize_is_idempotent_on_clean_input() {
        // Sanitizing a clean query twice must equal sanitizing once —
        // the fast path is a proper no-op.
        let clean = "hello world";
        assert_eq!(
            sanitize_fts5_query(clean),
            sanitize_fts5_query(&sanitize_fts5_query(clean)),
        );
    }
}
