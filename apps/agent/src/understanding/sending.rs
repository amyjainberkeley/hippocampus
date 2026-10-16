//! What an AI tool may be told about the person.
//!
//! A line Hippocampus inferred goes to an AI tool, in the block a new session
//! starts with or when the tool looks the person up, only once it is
//! corroborated:
//! - the model is sure of it: confidence at least
//!   [`ABOUT_YOU_MIN_CONFIDENCE`];
//! - at least [`MIN_SUPPORTING_EVENTS`] of the moments it rests on show it in
//!   what the window said: [`MIN_SHARED_WORDS`] or more of its words are in
//!   the reading's `main`, which leaves out the app's name, the window's
//!   title and the labels the reader sets apart (tabs, sidebars, menus). A
//!   line made from a title or a mailbox's name has no such moment;
//! - those moments fall in sessions on at least [`MIN_DAYS`] different days;
//! - neither the line nor the model's reasoning for it is about an area in
//!   [`sensitive_area`]: looking for work, health, money, relationships,
//!   faith, politics, sexuality, immigration or the law. A line about who
//!   the person works with is about relationships too;
//! - it does not say again, in the same words or others, a line the person
//!   forgot ([`restates`]).
//!
//! A line the person confirmed in You is sent whatever its scores: they said
//! it is right. A line they forgot is never sent.
//!
//! The You page reads every line, sent or not, so the person can confirm or
//! forget it; what it says is sent comes from here.

use std::collections::{BTreeSet, HashSet};

use mci_brain::reading;
use mci_brain::understanding::{
    EventHead, ObservedEvent, Proposition, PropositionKind, PropositionStatus,
};
use mci_brain::{EventSource, SqlCipherBrainStore, StoreError};

use super::apps;
use super::observe::SESSION_GAP_US;
use super::query::ABOUT_YOU_MIN_CONFIDENCE;
use crate::brief_worker::local_date_string;

/// Moments that must show a line before it is sent.
pub const MIN_SUPPORTING_EVENTS: usize = 3;
/// …in sessions on at least this many different days.
pub const MIN_DAYS: usize = 2;
/// A moment shows a line when what it said holds this many of the line's
/// words.
pub const MIN_SHARED_WORDS: usize = 2;
/// The newest moments of a line that are read to check it.
const MAX_MOMENTS_READ: usize = 32;
/// Forgotten lines compared with each line.
const FORGOTTEN_READ: usize = 500;

/// Why a line is not sent to AI tools.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Held {
    /// The model is not sure enough of it.
    NotSure,
    /// It is about a sensitive area: only the person can let it go.
    Sensitive,
    /// The person forgot it, or it says again what they forgot.
    Forgotten,
    /// It has fewer than [`MIN_SHARED_WORDS`] words of its own to look for:
    /// "Sam is working on several things" could be said of anyone.
    TooPlain,
    /// Its words are in the moments' app names, titles or labels, not in
    /// what the windows said.
    OnlyNamesAndLabels,
    /// Fewer than [`MIN_SUPPORTING_EVENTS`] moments show it.
    TooFewMoments,
    /// The moments that show it are all from one day.
    OneDay,
}

/// Whether a line may go to AI tools.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sending {
    /// The person confirmed it in You.
    Confirmed,
    /// It met every rule.
    Corroborated,
    /// It is not sent, for this reason.
    Held(Held),
}

impl Sending {
    /// Whether an AI tool may be given the line.
    #[must_use]
    pub fn allowed(self) -> bool {
        !matches!(self, Self::Held(_))
    }

    /// Whether the person confirmed it.
    #[must_use]
    pub fn confirmed(self) -> bool {
        self == Self::Confirmed
    }
}

/// What deciding needs besides the line itself: the person's verdicts and
/// their time zone, read once for any number of lines.
pub struct Gate {
    confirmed: HashSet<i64>,
    forgotten: Vec<BTreeSet<String>>,
    tz: i32,
}

impl Gate {
    /// Read the confirmed ids and the forgotten lines.
    ///
    /// # Errors
    /// Store failures.
    pub fn read(store: &SqlCipherBrainStore, tz: i32) -> Result<Self, StoreError> {
        let forgotten = store
            .propositions_with_status(PropositionStatus::Rejected, FORGOTTEN_READ)?
            .iter()
            .map(|p| keywords(&p.text))
            .collect();
        Ok(Self::new(store.confirmed_proposition_ids()?, forgotten, tz))
    }

    /// A gate over the given verdicts: confirmed ids, and the words of each
    /// forgotten line ([`keywords`]).
    #[must_use]
    pub fn new(confirmed: HashSet<i64>, forgotten: Vec<BTreeSet<String>>, tz: i32) -> Self {
        Self {
            confirmed,
            forgotten,
            tz,
        }
    }

    /// Whether the person confirmed `p`.
    #[must_use]
    pub fn is_confirmed(&self, p: &Proposition) -> bool {
        self.confirmed.contains(&p.id)
    }

    /// Whether `p` may go to AI tools, reading the moments it rests on only
    /// when nothing else has decided.
    ///
    /// # Errors
    /// Store failures.
    pub fn sending(
        &self,
        store: &SqlCipherBrainStore,
        p: &Proposition,
    ) -> Result<Sending, StoreError> {
        if let Some(decided) = self.without_moments(p) {
            return Ok(decided);
        }
        let heads = store.event_heads(&p.evidence)?;
        self.sending_from_heads(store, p, heads)
    }

    /// [`Self::sending`], with the heads of the moments `p` rests on already
    /// read: their times decide how many there are and on how many days, and
    /// only then is what they said read.
    ///
    /// # Errors
    /// Store failures.
    pub fn sending_from_heads(
        &self,
        store: &SqlCipherBrainStore,
        p: &Proposition,
        mut heads: Vec<EventHead>,
    ) -> Result<Sending, StoreError> {
        if let Some(decided) = self.without_moments(p) {
            return Ok(decided);
        }
        if heads.len() < MIN_SUPPORTING_EVENTS {
            return Ok(Sending::Held(Held::TooFewMoments));
        }
        let times: Vec<u64> = heads.iter().map(|h| h.ts_us).collect();
        if session_days(&times, self.tz) < MIN_DAYS {
            return Ok(Sending::Held(Held::OneDay));
        }
        heads.sort_by_key(|h| std::cmp::Reverse((h.ts_us, h.id)));
        let newest: Vec<i64> = heads.iter().take(MAX_MOMENTS_READ).map(|h| h.id).collect();
        let moments = store.observed_events_by_id(&newest)?;
        Ok(self.judge_moments(p, &moments))
    }

    /// What can be decided from the line alone: a confirmation, a forgotten
    /// line, a low score, a sensitive area, or words too plain to look for.
    /// `None` when the moments decide.
    #[must_use]
    pub fn without_moments(&self, p: &Proposition) -> Option<Sending> {
        if p.status == PropositionStatus::Rejected {
            return Some(Sending::Held(Held::Forgotten));
        }
        if self.is_confirmed(p) {
            return Some(Sending::Confirmed);
        }
        if p.confidence < ABOUT_YOU_MIN_CONFIDENCE {
            return Some(Sending::Held(Held::NotSure));
        }
        if p.kind == PropositionKind::Relationship
            || sensitive_area(&p.text).is_some()
            || sensitive_area(&p.reasoning).is_some()
        {
            return Some(Sending::Held(Held::Sensitive));
        }
        let words = keywords(&p.text);
        if self.forgotten.iter().any(|f| restates(&words, f)) {
            return Some(Sending::Held(Held::Forgotten));
        }
        if words.len() < MIN_SHARED_WORDS {
            return Some(Sending::Held(Held::TooPlain));
        }
        if p.evidence.len() < MIN_SUPPORTING_EVENTS {
            return Some(Sending::Held(Held::TooFewMoments));
        }
        None
    }

    /// Decide from what the moments said. `moments` are some or all of the
    /// moments `p` rests on.
    #[must_use]
    pub fn judge_moments(&self, p: &Proposition, moments: &[ObservedEvent]) -> Sending {
        if let Some(decided) = self.without_moments(p) {
            return decided;
        }
        let words = keywords(&p.text);
        let mut shown_at = Vec::new();
        let mut in_labels = false;
        for moment in moments {
            let said = reading::reading(
                &moment.text,
                EventSource::from_stored(&moment.source),
                moment.app_bundle_id.as_deref(),
                moment.window_title.as_deref(),
            );
            if shares_enough(&words, &folded_words(&said.main)) {
                shown_at.push(moment.ts_us);
            } else if !in_labels {
                let labels = format!(
                    "{} {} {}",
                    moment
                        .app_bundle_id
                        .as_deref()
                        .map(apps::name)
                        .unwrap_or_default(),
                    moment.window_title.as_deref().unwrap_or_default(),
                    said.rest
                );
                in_labels = !folded_words(&labels).is_disjoint(&words);
            }
        }
        if shown_at.is_empty() && in_labels {
            Sending::Held(Held::OnlyNamesAndLabels)
        } else if shown_at.len() < MIN_SUPPORTING_EVENTS {
            Sending::Held(Held::TooFewMoments)
        } else if session_days(&shown_at, self.tz) < MIN_DAYS {
            Sending::Held(Held::OneDay)
        } else {
            Sending::Corroborated
        }
    }
}

/// Whether `shown` holds enough of a line's `words` to show it.
fn shares_enough(words: &BTreeSet<String>, shown: &BTreeSet<String>) -> bool {
    words.intersection(shown).count() >= MIN_SHARED_WORDS
}

/// Local dates of the sessions among moments at `times`: moments closer than
/// a session's idle gap ([`SESSION_GAP_US`]) are one session, dated by its
/// first moment.
#[must_use]
pub fn session_days(times: &[u64], tz: i32) -> usize {
    let mut sorted = times.to_vec();
    sorted.sort_unstable();
    let mut days = BTreeSet::new();
    let mut last: Option<u64> = None;
    for ts in sorted {
        if last.is_none_or(|last| ts.saturating_sub(last) >= SESSION_GAP_US) {
            days.insert(local_date_string(
                i64::try_from(ts / 1_000_000).unwrap_or(0),
                tz,
            ));
        }
        last = Some(ts);
    }
    days.len()
}

/// Function words of four letters or more, and words about how often or how
/// much: none of them is something a window would show of one line.
const PLAIN: &[&str] = &[
    "about",
    "across",
    "after",
    "again",
    "also",
    "always",
    "around",
    "been",
    "before",
    "being",
    "between",
    "both",
    "could",
    "daily",
    "does",
    "doing",
    "done",
    "during",
    "each",
    "every",
    "frequently",
    "from",
    "have",
    "having",
    "into",
    "just",
    "makes",
    "many",
    "more",
    "most",
    "much",
    "never",
    "often",
    "only",
    "onto",
    "other",
    "others",
    "over",
    "rather",
    "really",
    "regularly",
    "should",
    "sometimes",
    "such",
    "tends",
    "than",
    "them",
    "then",
    "there",
    "these",
    "those",
    "through",
    "under",
    "until",
    "usually",
    "very",
    "weekly",
    "were",
    "what",
    "when",
    "where",
    "which",
    "whose",
    "will",
    "within",
    "without",
    "would",
    "your",
];

/// Lower-cased words of `text`, with plurals folded: "tests" is "test",
/// while "status", "analysis" and "process" stay as they are.
fn tokens(text: &str) -> impl Iterator<Item = String> + '_ {
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(str::to_lowercase)
}

fn fold(word: String) -> String {
    let ends = |tail: &str| word.ends_with(tail);
    if word.chars().count() >= 4 && ends("s") && !ends("ss") && !ends("us") && !ends("is") {
        let mut word = word;
        word.pop();
        word
    } else {
        word
    }
}

/// Every word of `text`, folded, for finding a line's words in it.
fn folded_words(text: &str) -> BTreeSet<String> {
    tokens(text).map(fold).collect()
}

/// The words of a line that a window would have to show: four letters or
/// more, folded, without the person's name (the first word, since every
/// line starts with it), words like "project" or "working" that fit any
/// line ([`super::gum::GENERIC`]) and function words.
#[must_use]
pub fn keywords(text: &str) -> BTreeSet<String> {
    let subject = text
        .split(|c: char| !c.is_alphanumeric())
        .find(|w| !w.is_empty())
        .filter(|w| w.chars().next().is_some_and(char::is_uppercase))
        .map(str::to_lowercase);
    tokens(text)
        .filter(|w| w.chars().count() >= 4)
        .filter(|w| subject.as_deref() != Some(w.as_str()))
        .filter(|w| !super::gum::GENERIC.contains(&w.as_str()) && !PLAIN.contains(&w.as_str()))
        .map(fold)
        .collect()
}

/// Whether a line with `words` says again what a forgotten line with
/// `forgotten` said: they share two words or more, and at least three in
/// five of the shorter one's.
#[must_use]
pub fn restates(words: &BTreeSet<String>, forgotten: &BTreeSet<String>) -> bool {
    let shared = words.intersection(forgotten).count();
    let shorter = words.len().min(forgotten.len());
    shared >= 2 && shared * 5 >= shorter * 3
}

/// The areas no inferred line is sent about until the person confirms it,
/// each with the words and phrases that place a line in it. A word that is
/// also everyday technical language ("application", "position", "budget",
/// "partner", "race") is left out; one that is mostly personal ("interview",
/// "health") is in, and a line that uses it in a technical sense waits for
/// the person's Right.
const SENSITIVE: &[(&str, &[&str])] = &[
    (
        "looking for work",
        &[
            "job",
            "jobs",
            "résumé",
            "cv",
            "cover letter",
            "recruiter",
            "recruiters",
            "recruiting",
            "hiring",
            "career",
            "careers",
            "internship",
            "internships",
            "interview",
            "interviews",
            "interviewing",
            "job offer",
            "offer letter",
            "applying for",
            "applies for",
            "applied for",
            "apply for",
            "applying to",
            "application for",
            "applications for",
            "layoff",
            "layoffs",
            "laid off",
            "unemployed",
            "unemployment",
            "severance",
            "resign",
            "resigning",
            "resignation",
        ],
    ),
    (
        "health",
        &[
            "health",
            "healthcare",
            "medical",
            "medicine",
            "medication",
            "medications",
            "doctor",
            "doctors",
            "physician",
            "clinic",
            "hospital",
            "diagnosis",
            "diagnosed",
            "symptom",
            "symptoms",
            "therapy",
            "therapist",
            "counseling",
            "counselling",
            "psychiatrist",
            "psychologist",
            "psychiatric",
            "depression",
            "depressed",
            "anxiety",
            "adhd",
            "autism",
            "autistic",
            "bipolar",
            "ptsd",
            "prescription",
            "prescriptions",
            "pharmacy",
            "illness",
            "disease",
            "sick",
            "injury",
            "injured",
            "surgery",
            "pregnant",
            "pregnancy",
            "fertility",
            "ivf",
            "miscarriage",
            "abortion",
            "contraception",
            "menstrual",
            "cancer",
            "diabetes",
            "diabetic",
            "covid",
            "hiv",
            "insulin",
            "rehab",
            "addiction",
            "sobriety",
            "sober",
            "alcoholism",
            "overdose",
            "suicide",
            "suicidal",
            "self harm",
            "disability",
            "disabled",
            "dieting",
            "calories",
            "weight loss",
            "eating disorder",
            "mental health",
            "mental illness",
            "blood pressure",
            "vaccine",
            "vaccination",
            "allergy",
            "allergies",
            "dentist",
            "dental",
            "migraine",
            "insomnia",
        ],
    ),
    (
        "money",
        &[
            "money",
            "finance",
            "finances",
            "financial",
            "bank",
            "banking",
            "loan",
            "loans",
            "debt",
            "debts",
            "mortgage",
            "salary",
            "salaries",
            "income",
            "paycheck",
            "wage",
            "wages",
            "taxes",
            "tax return",
            "tax returns",
            "irs",
            "invest",
            "investing",
            "investment",
            "investments",
            "stocks",
            "crypto",
            "cryptocurrency",
            "bitcoin",
            "ethereum",
            "savings",
            "retirement",
            "401k",
            "insurance",
            "bills",
            "bankruptcy",
            "budgeting",
            "net worth",
            "credit card",
            "credit score",
            "credit report",
            "rent",
            "landlord",
            "venmo",
            "zelle",
        ],
    ),
    (
        "relationships",
        &[
            "relationship",
            "relationships",
            "dating",
            "dating app",
            "boyfriend",
            "girlfriend",
            "husband",
            "wife",
            "spouse",
            "fiance",
            "fiancé",
            "fiancee",
            "fiancée",
            "marriage",
            "married",
            "wedding",
            "divorce",
            "divorced",
            "breakup",
            "broke up",
            "break up",
            "romantic",
            "romance",
            "tinder",
            "bumble",
            "custody",
        ],
    ),
    (
        "beliefs, identity or the law",
        &[
            "religion",
            "religious",
            "church",
            "mosque",
            "synagogue",
            "faith",
            "prayer",
            "praying",
            "political",
            "politics",
            "election",
            "elections",
            "voting",
            "democrat",
            "democrats",
            "republican",
            "republicans",
            "protest",
            "protests",
            "sexuality",
            "sexual",
            "gay",
            "lesbian",
            "bisexual",
            "lgbt",
            "lgbtq",
            "queer",
            "transgender",
            "immigration",
            "immigrant",
            "citizenship",
            "deportation",
            "asylum",
            "visa",
            "green card",
            "lawsuit",
            "lawyer",
            "attorney",
            "arrest",
            "arrested",
            "criminal",
            "police",
            "probation",
            "ethnicity",
            "ethnic",
            "racial",
        ],
    ),
];

/// Technical phrases that use a sensitive word in another sense.
const NOT_SENSITIVE: &[&str] = &[
    "health check",
    "health checks",
    "healthcheck",
    "healthchecks",
    "helper health",
];

/// The sensitive area `text` is about, if any ([`SENSITIVE`]): a whole word
/// or phrase, in any case.
#[must_use]
pub fn sensitive_area(text: &str) -> Option<&'static str> {
    let mut padded = format!(" {} ", tokens(text).collect::<Vec<_>>().join(" "));
    for phrase in NOT_SENSITIVE {
        padded = padded.replace(&format!(" {phrase} "), " ");
    }
    SENSITIVE
        .iter()
        .find(|(_, terms)| {
            terms
                .iter()
                .any(|term| padded.contains(&format!(" {term} ")))
        })
        .map(|(area, _)| *area)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: u64 = 86_400_000_000;
    const MIN: u64 = 60_000_000;
    /// 2026-10-12 17:00 UTC, 10:00 in Los Angeles.
    const MONDAY: u64 = 1_791_910_800_000_000;
    const PDT: i32 = -7 * 3600;

    fn line(id: i64, text: &str, kind: PropositionKind, confidence: f64) -> Proposition {
        Proposition {
            id,
            text: text.into(),
            reasoning: String::new(),
            kind,
            confidence,
            decay: 0.3,
            status: PropositionStatus::Active,
            created_us: 0,
            updated_us: MONDAY,
            revised_from: None,
            model: "test".into(),
            evidence: vec![1, 2, 3, 4],
        }
    }

    fn moment(id: i64, ts_us: u64, title: &str, text: &str) -> ObservedEvent {
        ObservedEvent {
            id,
            ts_us,
            app_bundle_id: Some("com.apple.Notes".into()),
            window_title: Some(title.into()),
            url: None,
            text: text.into(),
            source: "screen_ocr".into(),
        }
    }

    fn gate() -> Gate {
        Gate::new(HashSet::new(), Vec::new(), PDT)
    }

    fn pricing() -> Proposition {
        line(
            7,
            "Sam is pricing the Team plan for Trailhead Bikes.",
            PropositionKind::Project,
            0.8,
        )
    }

    /// Three moments that say what `pricing` claims, on two days.
    fn pricing_moments() -> Vec<ObservedEvent> {
        vec![
            moment(
                1,
                MONDAY,
                "Launch plan",
                "Trailhead Bikes pricing: Team plan $18 a seat",
            ),
            moment(
                2,
                MONDAY + 2 * MIN,
                "Launch plan",
                "Team pricing for Trailhead",
            ),
            moment(
                3,
                MONDAY + DAY,
                "Launch plan",
                "Trailhead Bikes Team plan pricing, annual",
            ),
        ]
    }

    #[test]
    fn a_line_shown_by_three_moments_over_two_days_is_sent() {
        assert_eq!(
            gate().judge_moments(&pricing(), &pricing_moments()),
            Sending::Corroborated
        );
    }

    #[test]
    fn a_line_seen_on_one_day_is_not_sent_however_often_it_was_seen() {
        let moments: Vec<ObservedEvent> = (0..6)
            .map(|i| {
                moment(
                    i,
                    MONDAY + u64::try_from(i).unwrap() * 20 * MIN,
                    "Launch plan",
                    "Trailhead Bikes Team plan pricing",
                )
            })
            .collect();
        assert_eq!(
            gate().judge_moments(&pricing(), &moments),
            Sending::Held(Held::OneDay)
        );
    }

    #[test]
    fn two_moments_are_too_few() {
        let moments = &pricing_moments()[1..];
        assert_eq!(
            gate().judge_moments(&pricing(), moments),
            Sending::Held(Held::TooFewMoments)
        );
    }

    #[test]
    fn a_session_across_midnight_is_one_session_on_one_day() {
        // 23:50 to 00:10 in Los Angeles, every two minutes: one session.
        let late = MONDAY + 13 * 60 * MIN + 50 * MIN;
        let times: Vec<u64> = (0..11).map(|i| late + i * 2 * MIN).collect();
        assert_eq!(session_days(&times, PDT), 1);
        assert_eq!(session_days(&[late, late + DAY], PDT), 2);
    }

    #[test]
    fn a_line_below_the_confidence_floor_is_not_sent() {
        let mut unsure = pricing();
        unsure.confidence = 0.7;
        assert_eq!(
            gate().judge_moments(&unsure, &pricing_moments()),
            Sending::Held(Held::NotSure)
        );
        unsure.confidence = ABOUT_YOU_MIN_CONFIDENCE;
        assert_eq!(
            gate().judge_moments(&unsure, &pricing_moments()),
            Sending::Corroborated
        );
    }

    #[test]
    fn a_line_from_titles_and_labels_alone_is_not_sent() {
        // The words are in the title and the sidebar, never in what the
        // window said.
        let claim = line(
            9,
            "Sam is organizing the Quarterly Roadmap folder.",
            PropositionKind::Project,
            0.9,
        );
        let moments: Vec<ObservedEvent> = (0..4)
            .map(|i| {
                moment(
                    i,
                    MONDAY + u64::try_from(i).unwrap() * DAY,
                    "Quarterly Roadmap",
                    "[app=com.apple.Notes | title=Quarterly Roadmap | url=? | ts=2026-10-12T17:00:00.000Z]\n\
                     Lunch with the team on Friday\n\n\u{1e}\nFolders\nQuarterly Roadmap\nOrganizing",
                )
            })
            .collect();
        assert_eq!(
            gate().judge_moments(&claim, &moments),
            Sending::Held(Held::OnlyNamesAndLabels)
        );
    }

    #[test]
    fn a_confirmed_line_is_sent_whatever_its_scores() {
        let mut confirmed = line(
            11,
            "Sam is planning a trip through the Northwind Travel account.",
            PropositionKind::Goal,
            1.0,
        );
        confirmed.evidence.clear();
        let gate = Gate::new([11].into_iter().collect(), Vec::new(), PDT);
        assert_eq!(gate.judge_moments(&confirmed, &[]), Sending::Confirmed);
        assert!(Sending::Confirmed.allowed() && Sending::Confirmed.confirmed());
    }

    #[test]
    fn a_forgotten_line_never_comes_back_in_other_words() {
        let forgotten = keywords("Sam is planning a trip through the Northwind Travel account.");
        let gate = Gate::new(HashSet::new(), vec![forgotten.clone()], PDT);
        let reworded = line(
            12,
            "Sam manages bookings through the Northwind Travel account.",
            PropositionKind::Project,
            0.9,
        );
        assert_eq!(
            gate.judge_moments(&reworded, &pricing_moments()),
            Sending::Held(Held::Forgotten)
        );
        let mut rejected = pricing();
        rejected.status = PropositionStatus::Rejected;
        assert_eq!(
            gate.judge_moments(&rejected, &pricing_moments()),
            Sending::Held(Held::Forgotten)
        );
        // A different line that shares a name with it still goes.
        assert!(!restates(
            &keywords("Amy reads Northwind Travel each morning."),
            &forgotten
        ));
        assert_eq!(
            gate.judge_moments(&pricing(), &pricing_moments()),
            Sending::Corroborated
        );
    }

    #[test]
    fn sensitive_lines_wait_for_the_person() {
        for text in [
            "Sam is planning a trip through the Northwind Travel account.",
            "Sam is preparing for an interview with Stripe.",
            "Sam is looking for a new job in Seattle.",
            "Sam is tracking symptoms in a health journal.",
            "Sam is paying down a student loan.",
            "Sam is planning a wedding in June.",
            "Sam is renewing a visa for the conference.",
        ] {
            let claim = line(13, text, PropositionKind::Goal, 0.9);
            assert_eq!(
                gate().judge_moments(&claim, &pricing_moments()),
                Sending::Held(Held::Sensitive),
                "{text}"
            );
        }
        let mut reasoned = pricing();
        reasoned.reasoning = "Offer letter and salary emails in the inbox.".into();
        assert_eq!(
            gate().judge_moments(&reasoned, &pricing_moments()),
            Sending::Held(Held::Sensitive),
            "the reasoning counts too"
        );
        let colleague = line(
            14,
            "Amy works with Priya on the Trailhead Bikes pricing.",
            PropositionKind::Relationship,
            0.9,
        );
        assert_eq!(
            gate().judge_moments(&colleague, &pricing_moments()),
            Sending::Held(Held::Sensitive),
            "who someone works with is about relationships"
        );
    }

    #[test]
    fn sensitive_words_are_whole_words_in_any_case() {
        assert_eq!(
            sensitive_area("Sam updated their CV"),
            Some("looking for work")
        );
        assert_eq!(
            sensitive_area("APPLYING FOR the role"),
            Some("looking for work")
        );
        assert_eq!(
            sensitive_area("Sam is fixing the helper health check"),
            None
        );
        assert_eq!(sensitive_area("Amy writes the jobserver docs"), None);
        assert_eq!(sensitive_area("Sam is building the web application"), None);
        assert_eq!(
            sensitive_area("Amy fixed a race condition in the store"),
            None
        );
        assert_eq!(sensitive_area("Amy prices the Team plan per seat"), None);
    }

    #[test]
    fn a_line_too_plain_to_look_for_is_not_sent() {
        let plain = line(
            15,
            "Sam is working on several things daily.",
            PropositionKind::Habit,
            0.9,
        );
        assert!(keywords(&plain.text).len() < MIN_SHARED_WORDS);
        assert_eq!(
            gate().judge_moments(&plain, &pricing_moments()),
            Sending::Held(Held::TooPlain)
        );
    }

    #[test]
    fn a_lines_words_leave_out_the_name_and_plain_words() {
        assert_eq!(
            keywords("Sam is working on the pricing pages with Ravi often."),
            ["page", "pricing", "ravi"]
                .into_iter()
                .map(str::to_owned)
                .collect()
        );
        assert_eq!(fold("status".into()), "status");
        assert_eq!(fold("tests".into()), "test");
        assert_eq!(fold("process".into()), "process");
    }
}
