//! Deterministic, evidence-cited brief author available without a model.

use std::collections::HashSet;

use mci_brain::{EventId, EventRecord};

use crate::author::{AuthorError, BriefAuthor};
use crate::model::{Brief, BriefId, BriefState};

/// Zero-download brief author for the default local path.
///
/// It does not infer facts. Finite lexical rules filter recognized chrome
/// and rank source lines. Whitespace is normalized and Markdown is escaped;
/// every bullet cites the event containing that evidence. These rules do not
/// establish semantic understanding or the truth of captured claims.
#[derive(Debug, Default, Clone, Copy)]
pub struct ExtractiveBriefAuthor;

impl ExtractiveBriefAuthor {
    /// Maximum number of evidence bullets written to one brief.
    pub const MAX_BULLETS: usize = 9;
    /// Bound the rendered body after escaping; never truncate a source sentence.
    pub const MAX_BODY_BYTES: usize = 16_384;
    const MAX_LINE_BYTES: usize = 2_048;
    const MAX_SOURCE_BYTES: usize = 256;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DigestSection {
    Changed,
    OpenLoop,
    Recent,
}

struct DigestItem {
    event_id: EventId,
    ts_us: u64,
    section: DigestSection,
    rank: u8,
    source: String,
    evidence: String,
}

impl BriefAuthor for ExtractiveBriefAuthor {
    fn author(&self, retrieval: &[EventRecord], topic: &str) -> Result<Brief, AuthorError> {
        if retrieval.is_empty() {
            return Err(AuthorError::NoEvents);
        }

        let mut seen = HashSet::new();
        let mut items = Vec::new();
        let mut records = retrieval.iter().collect::<Vec<_>>();
        records.sort_by_key(|record| std::cmp::Reverse((record.ts_us, record.event_id)));
        for record in records {
            for evidence in clean_evidence(record) {
                // Only collapse OCR repeats in the same source context. Identical
                // short statements in different documents may describe different work.
                let key = (
                    record.app_bundle_id.as_deref(),
                    record.window_title.as_deref().map(normalize_whitespace),
                    record.url.as_deref(),
                    evidence.to_lowercase(),
                );
                if !seen.insert(key) {
                    continue;
                }
                let section = classify_evidence(&evidence);
                items.push(DigestItem {
                    event_id: record.event_id,
                    ts_us: record.ts_us,
                    section,
                    rank: evidence_rank(&evidence, section),
                    source: evidence_source(record),
                    evidence,
                });
            }
        }
        if items.is_empty() {
            return Err(AuthorError::NoEvents);
        }

        items.sort_by_key(|item| std::cmp::Reverse((item.rank, item.ts_us, item.event_id)));
        let selected = select_evidence(&items);

        let mut body = String::new();
        let mut citations = Vec::with_capacity(selected.len());
        for (section, heading) in [
            (DigestSection::Changed, "What changed"),
            (DigestSection::OpenLoop, "Open loops"),
            (DigestSection::Recent, "Recent activity"),
        ] {
            let section_items = selected
                .iter()
                .copied()
                .filter(|item| item.section == section)
                .collect::<Vec<_>>();
            if section_items.is_empty() {
                continue;
            }
            let mut section_started = false;
            for item in section_items {
                let mut row = String::from("- ");
                if !item.source.is_empty() {
                    row.push_str(&escape_markdown(&item.source));
                    row.push_str(": ");
                }
                row.push_str(&escape_markdown(&item.evidence));
                row.push_str(" [event:");
                row.push_str(&item.event_id.0.to_string());
                row.push_str("]\n");
                let heading_bytes = if section_started {
                    0
                } else {
                    heading.len() + 5
                };
                if body.len() + heading_bytes + row.len() > Self::MAX_BODY_BYTES {
                    continue;
                }
                if !section_started {
                    if !body.is_empty() {
                        body.push('\n');
                    }
                    body.push_str("## ");
                    body.push_str(heading);
                    body.push('\n');
                    section_started = true;
                }
                body.push_str(&row);
                if !citations.contains(&item.event_id) {
                    citations.push(item.event_id);
                }
            }
        }

        let now_us = selected.iter().map(|item| item.ts_us).max().unwrap_or(0);
        Ok(Brief {
            id: BriefId(0),
            title: topic.to_owned(),
            body: body.trim_end().to_owned(),
            citations,
            state: BriefState::Draft,
            created_ts_us: now_us,
            updated_ts_us: now_us,
            human_approver_id: None,
        })
    }

    fn model_id(&self) -> &'static str {
        "hippocampus-extractive"
    }

    fn model_version(&self) -> &'static str {
        "2"
    }
}

fn select_evidence(items: &[DigestItem]) -> Vec<&DigestItem> {
    let mut indices = Vec::new();
    // Reserve room for each explicit work category before filling the cap.
    // A burst of completed updates must not displace every open loop.
    for section in [
        DigestSection::Changed,
        DigestSection::OpenLoop,
        DigestSection::Recent,
    ] {
        if let Some(index) = items
            .iter()
            .position(|item| item.section == section && item.rank > 0)
        {
            indices.push(index);
        }
    }
    for index in 0..items.len() {
        if indices.len() == ExtractiveBriefAuthor::MAX_BULLETS {
            break;
        }
        if !indices.contains(&index) {
            indices.push(index);
        }
    }
    indices.sort_unstable();
    indices.iter().map(|&index| &items[index]).collect()
}

fn normalize_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn clean_evidence(record: &EventRecord) -> Vec<String> {
    let text = &record.text_snippet;
    let without_header = text
        .strip_prefix("[app=")
        .and_then(|rest| rest.split_once("]\n"))
        .map_or(text.as_str(), |(_, body)| body);
    without_header
        .lines()
        .filter(|line| line.len() <= ExtractiveBriefAuthor::MAX_LINE_BYTES)
        .map(normalize_whitespace)
        .map(|line| strip_menu_prefix(&line).to_owned())
        .filter(|line| !line.is_empty() && !is_chrome(line, record) && !is_directive(line))
        .collect()
}

fn strip_menu_prefix(line: &str) -> &str {
    const MENUS: &[&str] = &[
        "finder file edit view go window help",
        "file edit view go window help",
        "file edit view window help",
    ];
    let lower = line.to_lowercase();
    for menu in MENUS {
        if let Some(rest) = lower.strip_prefix(menu) {
            if rest.is_empty() || rest.starts_with(' ') {
                return line[menu.len()..].trim_start();
            }
        }
    }
    line
}

fn is_chrome(line: &str, record: &EventRecord) -> bool {
    let lower = line.to_lowercase();
    match record.app_bundle_id.as_deref() {
        Some("com.apple.finder") => {
            const LABELS: &[&str] = &[
                "finder",
                "file",
                "edit",
                "view",
                "go",
                "window",
                "help",
                "recents",
                "applications",
                "desktop",
                "documents",
                "downloads",
                "airdrop",
                "favorites",
                "locations",
                "tags",
                "icloud",
                "icloud drive",
                "shared",
                "network",
                "trash",
                "search",
                "name",
                "date modified",
                "size",
                "kind",
            ];
            LABELS.contains(&lower.as_str()) || finder_status(&lower)
        }
        Some("com.apple.controlcenter" | "com.apple.systemuiserver") => {
            const LABELS: &[&str] = &[
                "control center",
                "wi-fi",
                "bluetooth",
                "airdrop",
                "focus",
                "display",
                "sound",
                "battery",
                "screen mirroring",
                "now playing",
            ];
            LABELS.contains(&lower.as_str())
                || lower
                    .strip_suffix('%')
                    .is_some_and(|n| n.parse::<u8>().is_ok_and(|n| n <= 100))
        }
        _ => false,
    }
}

fn finder_status(line: &str) -> bool {
    let Some((count, remaining)) = line.split_once(' ') else {
        return false;
    };
    if count.parse::<u64>().is_err() {
        return false;
    }
    if matches!(remaining, "item" | "items") {
        return true;
    }
    let Some(space) = remaining
        .strip_prefix("items, ")
        .or_else(|| remaining.strip_prefix("item, "))
    else {
        return false;
    };
    let words = space.split_whitespace().collect::<Vec<_>>();
    matches!(words.as_slice(), [size, unit, "available"]
        if size.parse::<f64>().is_ok_and(|n| n.is_finite() && n >= 0.0)
            && matches!(*unit, "kb" | "mb" | "gb" | "tb"))
}

fn is_directive(line: &str) -> bool {
    // A narrow filter for recognizable instruction/role lines, not an injection
    // detector. All remaining captured text is rendered inert below.
    let lower = line.to_lowercase();
    [
        "ignore previous instructions",
        "ignore all previous instructions",
        "ignore the above instructions",
        "system:",
        "assistant:",
        "developer:",
        "[event:",
        "[event_id:",
        "[eventid:",
        "[event :",
        "[inst]",
        "<|im_start|>",
    ]
    .iter()
    .any(|prefix| lower.starts_with(prefix))
}

fn escape_markdown(text: &str) -> String {
    use std::fmt::Write;
    let mut escaped = String::new();
    let chars = text.chars().collect::<Vec<_>>();
    for (index, &ch) in chars.iter().enumerate() {
        // CommonMark does not emphasize intraword underscores. Preserve code
        // identifiers in the plain-text view without admitting delimiter runs.
        let intraword_underscore = ch == '_'
            && index > 0
            && chars[index - 1].is_alphanumeric()
            && chars
                .get(index + 1)
                .is_some_and(|next| next.is_alphanumeric());
        if (matches!(ch, '&' | '<' | '>' | '[' | ']' | '*' | '_' | '`' | '\\')
            && !intraword_underscore)
            || (index == 0 && ch == '#')
        {
            let _ = write!(escaped, "&#{};", u32::from(ch));
        } else {
            escaped.push(ch);
        }
    }
    escaped
}

fn has_signal(evidence: &str, signals: &[&str]) -> bool {
    let lower = evidence.to_lowercase();
    let words = lower
        .split_whitespace()
        .map(|word| word.trim_matches(|ch: char| !ch.is_alphanumeric()))
        .collect::<Vec<_>>();
    signals.iter().any(|signal| {
        let tokens = signal.split_whitespace().collect::<Vec<_>>();
        words.windows(tokens.len()).any(|window| window == tokens)
    })
}

fn evidence_rank(evidence: &str, section: DigestSection) -> u8 {
    if section != DigestSection::Recent {
        return 2;
    }
    u8::from(has_signal(
        evidence,
        &[
            "reading",
            "reviewing",
            "reviewed",
            "writing",
            "wrote",
            "drafting",
            "editing",
            "investigating",
            "testing",
            "tracing",
            "research",
            "copied",
            "moved",
            "cargo test",
            "git commit",
            "gh pr",
        ],
    ))
}

fn classify_evidence(evidence: &str) -> DigestSection {
    const OPEN_LOOP_SIGNALS: &[&str] = &[
        "blocked",
        "deadline",
        "due",
        "follow up",
        "follow-up",
        "needs",
        "next step",
        "todo",
        "to do",
        "waiting",
    ];
    const CHANGE_SIGNALS: &[&str] = &[
        "approved",
        "completed",
        "created",
        "decided",
        "deployed",
        "fixed",
        "merged",
        "sent",
        "shipped",
        "updated",
    ];
    if has_signal(evidence, OPEN_LOOP_SIGNALS) {
        DigestSection::OpenLoop
    } else if has_signal(evidence, CHANGE_SIGNALS) {
        DigestSection::Changed
    } else {
        DigestSection::Recent
    }
}

fn evidence_source(record: &EventRecord) -> String {
    if let Some(title) = record.window_title.as_deref().map(str::trim) {
        if !title.is_empty() && title.len() <= ExtractiveBriefAuthor::MAX_SOURCE_BYTES {
            return normalize_whitespace(title);
        }
    }
    normalize_whitespace(
        record
            .app_bundle_id
            .as_deref()
            .and_then(|bundle| bundle.rsplit('.').next())
            .filter(|label| label.len() <= ExtractiveBriefAuthor::MAX_SOURCE_BYTES)
            .unwrap_or(""),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(id: u64, ts_us: u64, app: &str, title: &str, text: &str) -> EventRecord {
        EventRecord {
            event_id: EventId(id),
            ts_us,
            app_bundle_id: Some(app.to_owned()),
            window_title: Some(title.to_owned()),
            url: None,
            text_snippet: text.to_owned(),
        }
    }

    #[test]
    fn produces_a_compact_evidence_cited_digest() {
        let author = ExtractiveBriefAuthor;
        let records = vec![
            event(
                1,
                1_000_000,
                "com.google.Chrome",
                "Pull request #412 - GitHub",
                "[app=com.google.Chrome | title=Pull request #412 - GitHub]\nMerged PR #412 after CI passed.",
            ),
            event(
                2,
                2_000_000,
                "com.tinyspeck.slackmacgap",
                "launch-war-room",
                "Follow up with Maya before Friday's launch review.",
            ),
            event(
                3,
                3_000_000,
                "com.microsoft.VSCode",
                "hippocampus - Visual Studio Code",
                "Reading src/lib.rs while tracing the capture pipeline.",
            ),
        ];

        let brief = author.author(&records, "Daily brief").expect("brief");

        assert_eq!(brief.title, "Daily brief");
        assert_eq!(brief.state, BriefState::Draft);
        assert_eq!(brief.human_approver_id, None);
        assert!(brief.body.contains("## What changed"), "{}", brief.body);
        assert!(brief.body.contains("## Open loops"), "{}", brief.body);
        assert!(brief.body.contains("## Recent activity"), "{}", brief.body);
        assert!(brief
            .body
            .contains("Merged PR #412 after CI passed. [event:1]"));
        assert!(brief
            .body
            .contains("Follow up with Maya before Friday's launch review. [event:2]"));
        assert!(brief
            .body
            .contains("Reading src/lib.rs while tracing the capture pipeline. [event:3]"));
        assert!(!brief.body.contains("[app=com.google.Chrome"));
        assert_eq!(brief.citations, vec![EventId(1), EventId(2), EventId(3)]);
        assert_eq!(author.model_id(), "hippocampus-extractive");
        assert_eq!(author.model_version(), "2");
    }

    #[test]
    fn deduplicates_capture_churn_and_keeps_the_newest_evidence() {
        let author = ExtractiveBriefAuthor;
        let records = vec![
            event(
                10,
                1_000_000,
                "com.apple.Safari",
                "Pricing",
                "Updated the pricing page",
            ),
            event(
                11,
                2_000_000,
                "com.apple.Safari",
                "Pricing",
                "  Updated   the pricing page  ",
            ),
        ];

        let brief = author.author(&records, "Daily brief").expect("brief");

        assert_eq!(brief.body.matches("Updated the pricing page").count(), 1);
        assert!(brief.body.contains("[event:11]"), "{}", brief.body);
        assert!(!brief.body.contains("[event:10]"), "{}", brief.body);
        assert_eq!(brief.citations, vec![EventId(11)]);
    }

    #[test]
    fn caps_output_without_losing_open_loops_to_noise() {
        let author = ExtractiveBriefAuthor;
        let mut records = (1..=20)
            .map(|id| {
                event(
                    id,
                    id * 1_000_000,
                    "com.apple.Safari",
                    "Documentation",
                    &format!("Reading reference page {id}"),
                )
            })
            .collect::<Vec<_>>();
        records.push(event(
            99,
            500_000,
            "com.tinyspeck.slackmacgap",
            "launch",
            "Blocked on the signing certificate",
        ));

        let brief = author.author(&records, "Daily brief").expect("brief");
        let bullet_count = brief
            .body
            .lines()
            .filter(|line| line.starts_with("- "))
            .count();

        assert!(bullet_count <= ExtractiveBriefAuthor::MAX_BULLETS);
        assert!(brief
            .body
            .contains("Blocked on the signing certificate [event:99]"));
        assert!(brief.citations.contains(&EventId(99)));
    }
}
