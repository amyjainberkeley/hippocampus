//! Deterministic, evidence-cited brief author available without a model.

use std::collections::HashSet;

use mci_brain::{EventId, EventRecord};

use crate::author::{AuthorError, BriefAuthor};
use crate::model::{Brief, BriefId, BriefState};

/// Zero-download brief author for the default local path.
///
/// It does not infer facts. It removes capture metadata already represented
/// by event fields, deduplicates OCR churn, and arranges verbatim evidence
/// into useful sections. Every bullet cites the exact source event.
#[derive(Debug, Default, Clone, Copy)]
pub struct ExtractiveBriefAuthor;

impl ExtractiveBriefAuthor {
    /// Maximum number of evidence bullets written to one brief.
    pub const MAX_BULLETS: usize = 9;
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
        for record in retrieval.iter().rev() {
            let evidence = clean_evidence(&record.text_snippet);
            if evidence.is_empty() || !seen.insert(evidence.to_lowercase()) {
                continue;
            }
            items.push(DigestItem {
                event_id: record.event_id,
                ts_us: record.ts_us,
                section: classify_evidence(&evidence),
                source: evidence_source(record),
                evidence,
            });
        }
        if items.is_empty() {
            return Err(AuthorError::NoEvents);
        }

        let mut selected = Vec::new();
        for section in [
            DigestSection::Changed,
            DigestSection::OpenLoop,
            DigestSection::Recent,
        ] {
            for item in items.iter().filter(|item| item.section == section) {
                if selected.len() == Self::MAX_BULLETS {
                    break;
                }
                selected.push(item);
            }
        }

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
            if !body.is_empty() {
                body.push('\n');
            }
            body.push_str("## ");
            body.push_str(heading);
            body.push('\n');
            for item in section_items {
                body.push_str("- ");
                if !item.source.is_empty() {
                    body.push_str(&item.source);
                    body.push_str(": ");
                }
                body.push_str(&item.evidence);
                body.push_str(" [event:");
                body.push_str(&item.event_id.0.to_string());
                body.push_str("]\n");
                citations.push(item.event_id);
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
        "1"
    }
}

fn clean_evidence(text: &str) -> String {
    let without_header = text
        .strip_prefix('[')
        .and_then(|rest| rest.split_once("]\n"))
        .map_or(text, |(_, body)| body);
    without_header
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn classify_evidence(evidence: &str) -> DigestSection {
    const OPEN_LOOP_SIGNALS: &[&str] = &[
        "blocked",
        "deadline",
        "due ",
        "follow up",
        "follow-up",
        "needs ",
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
    let lower = evidence.to_lowercase();
    if OPEN_LOOP_SIGNALS
        .iter()
        .any(|signal| lower.contains(signal))
    {
        DigestSection::OpenLoop
    } else if CHANGE_SIGNALS.iter().any(|signal| lower.contains(signal)) {
        DigestSection::Changed
    } else {
        DigestSection::Recent
    }
}

fn evidence_source(record: &EventRecord) -> String {
    if let Some(title) = record.window_title.as_deref().map(str::trim) {
        if !title.is_empty() {
            return title.to_owned();
        }
    }
    record
        .app_bundle_id
        .as_deref()
        .and_then(|bundle| bundle.rsplit('.').next())
        .unwrap_or("")
        .to_owned()
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
        assert_eq!(author.model_version(), "1");
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
