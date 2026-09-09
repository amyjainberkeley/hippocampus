use std::collections::{HashMap, HashSet, VecDeque};

use mci_brain::fts_sanitizer::{sanitize_fts5_query, LexicalAlternative};

use super::{display_body, snippet, SNIPPET_CHAR_CAP};

/// Literal word locations for display only; retrieval remains authoritative.
/// The store does not expose FTS offsets or its Porter/diacritic normalization.
/// When no literal word is found, return a body prefix without implying a match.
pub(super) struct SearchSnippet {
    words: HashSet<String>,
}

impl SearchSnippet {
    pub(super) fn new(alternatives: &[LexicalAlternative<'_>]) -> Self {
        let mut words = HashSet::new();
        for alternative in alternatives {
            let (LexicalAlternative::Keywords(text) | LexicalAlternative::Phrase(text)) =
                alternative;
            let literal = sanitize_fts5_query(text);
            words.extend(
                literal
                    .split(|ch: char| !ch.is_alphanumeric())
                    .filter(|word| !word.is_empty())
                    .map(str::to_lowercase),
            );
        }
        Self { words }
    }

    pub(super) fn excerpt(&self, text: &str) -> String {
        let body = display_body(text);
        if self.words.is_empty() {
            return snippet(body);
        }

        // Keep only matches in one display-sized window. Original scalar offsets
        // avoid indexing UTF-8 with offsets from case-folded (possibly longer) text.
        let mut window: VecDeque<(usize, usize, &str)> = VecDeque::new();
        let mut counts: HashMap<&str, usize> = HashMap::new();
        let mut best = (0, 0, 0); // distinct words, first scalar, last scalar
        let mut offset = 0;
        for segment in body.split_inclusive(|ch: char| !ch.is_alphanumeric()) {
            let word = segment.trim_end_matches(|ch: char| !ch.is_alphanumeric());
            let start = offset;
            offset += segment.chars().count();
            let Some(matched) = self.words.get(&word.to_lowercase()) else {
                continue;
            };
            let end = start + word.chars().count().min(SNIPPET_CHAR_CAP);
            window.push_back((start, end, matched));
            *counts.entry(matched).or_default() += 1;
            while let Some(&(first, _, term)) = window.front() {
                if end - first <= SNIPPET_CHAR_CAP && counts[term] == 1 {
                    break;
                }
                window.pop_front();
                let count = counts.get_mut(term).expect("window term is counted");
                *count -= 1;
                if *count == 0 {
                    counts.remove(term);
                }
            }
            let first = window.front().expect("current match fits the window").0;
            let distinct = counts.len();
            if distinct > best.0 || (distinct == best.0 && end - first < best.2 - best.1) {
                best = (distinct, first, end);
            }
        }
        if best.0 == 0 {
            return snippet(body);
        }

        // HitRow has a three-line budget: start on the matching line with
        // modest left context, without backfilling earlier lines near EOF.
        let line_start = body
            .chars()
            .take(best.1)
            .enumerate()
            .filter(|(_, ch)| matches!(ch, '\n' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'))
            .map(|(index, _)| index + 1)
            .last()
            .unwrap_or(0);
        let context = (SNIPPET_CHAR_CAP - (best.2 - best.1)).min(32);
        let start = best.1.saturating_sub(context).max(line_start);
        body.chars().skip(start).take(SNIPPET_CHAR_CAP).collect()
    }
}
