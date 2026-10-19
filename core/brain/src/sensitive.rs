//! Sensitive areas: words and phrases that place a line in a part of a
//! person's life no line Hippocampus writes may guess about: looking for
//! work, health, money, relationships, and beliefs, identity or the law.
//!
//! One list, used wherever a line about the person could be shown or sent:
//! the agent holds back an inferred line about one of these areas until the
//! person confirms it, and a caption the on-device model wrote is never used
//! when it, or the moment it is about, touches one ([`crate::caption`]).
//! Matching is by whole word or phrase, in any case, so "bisexual" is found
//! and "illustration" is not "ill".

use std::collections::HashSet;

/// The areas, each with the words and phrases that place a line in it. A word
/// that is also everyday technical language ("application", "position",
/// "budget", "partner", "race") is left out; one that is mostly personal
/// ("interview", "health") is in, and a line that uses it in a technical
/// sense waits for the person's Right.
pub const SENSITIVE: &[(&str, &[&str])] = &[
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
            "onsite interview",
            "recruiter screen",
            "job posting",
            "job postings",
            "job application",
            "job applications",
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
            "sertraline",
            "prozac",
            "zoloft",
            "lexapro",
            "adderall",
            "xanax",
            "antidepressant",
            "antidepressants",
            "mychart",
            "lab results",
            "hepatitis",
            "chemo",
            "chemotherapy",
            "biopsy",
            "tumor",
            "diagnoses",
            "symptomatic",
            "psychotherapy",
            "psychology",
            "psychiatry",
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
            "overdraft",
            "overdrafts",
            "past due",
            "overdue payment",
            "late fee",
            "late fees",
            "collections agency",
            "debt collector",
            "payday loan",
            "minimum payment",
            "credit limit",
            "bankrupt",
            "foreclosure",
            "eviction",
            "paystub",
            "payslip",
            "w-2",
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
            "anniversary",
            "anniversaries",
            "date night",
            "valentine",
            "valentines",
            "boyfriends",
            "girlfriends",
            "ex-boyfriend",
            "ex-girlfriend",
            "grindr",
            "engagement ring",
            "honeymoon",
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
            "coming out",
            "pronouns",
            "gender identity",
            "nonbinary",
            "non-binary",
            "green cards",
            "uscis",
            "h-1b",
            "h1b",
            "work permit",
            "daca",
            "refugee",
            "naturalization",
            "court date",
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

/// The longest phrase in [`SENSITIVE`] and [`NOT_SENSITIVE`], in words.
const LONGEST_PHRASE: usize = 3;

/// Lower-cased words of `text`: runs of letters and digits, with a hyphen
/// between two of them kept ("w-2", "self-harm"). An apostrophe ends a word
/// ("doctor's" is "doctor" and "s").
fn tokens(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut word = String::new();
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch.is_alphanumeric() {
            word.extend(ch.to_lowercase());
        } else if ch == '-'
            && !word.is_empty()
            && chars.peek().is_some_and(|next| next.is_alphanumeric())
        {
            word.push('-');
        } else if !word.is_empty() {
            out.push(std::mem::take(&mut word));
        }
    }
    if !word.is_empty() {
        out.push(word);
    }
    out
}

/// The sensitive area `text` is about, if any ([`SENSITIVE`]): a whole word
/// or phrase, in any case. A hyphenated word counts as itself and as its
/// parts ("self-harm" is "self harm").
#[must_use]
pub fn sensitive_area(text: &str) -> Option<&'static str> {
    let mut words: Vec<String> = Vec::new();
    for token in tokens(text) {
        if token.contains('-') {
            words.extend(
                token
                    .split('-')
                    .filter(|part| !part.is_empty())
                    .map(str::to_owned),
            );
            // The whole hyphenated word too, as its own run ("w-2", "h-1b").
            words.push(String::new());
            words.push(token);
            words.push(String::new());
        } else {
            words.push(token);
        }
    }
    // Phrases that use a sensitive word in a technical sense leave no word.
    for phrase in NOT_SENSITIVE {
        let parts: Vec<&str> = phrase.split(' ').collect();
        let mut at = 0;
        while at + parts.len() <= words.len() {
            if parts
                .iter()
                .zip(&words[at..])
                .all(|(part, word)| part == word)
            {
                for word in &mut words[at..at + parts.len()] {
                    word.clear();
                }
                at += parts.len();
            } else {
                at += 1;
            }
        }
    }
    let mut runs: HashSet<String> = HashSet::new();
    for start in 0..words.len() {
        let mut run = String::new();
        for word in words.iter().skip(start).take(LONGEST_PHRASE) {
            if word.is_empty() {
                break;
            }
            if !run.is_empty() {
                run.push(' ');
            }
            run.push_str(word);
            runs.insert(run.clone());
        }
    }
    SENSITIVE
        .iter()
        .find(|(_, terms)| terms.iter().any(|term| runs.contains(*term)))
        .map(|(area, _)| *area)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_and_phrases_are_whole_in_any_case() {
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
        assert_eq!(sensitive_area("Sam writes the jobserver docs"), None);
        assert_eq!(sensitive_area("Sam is building the web application"), None);
        assert_eq!(
            sensitive_area("Sam fixed a race condition in the store"),
            None
        );
        assert_eq!(sensitive_area("Sam prices the Team plan per seat"), None);
        assert_eq!(sensitive_area("Sketching an illustration"), None);
        assert_eq!(
            sensitive_area("Reading the bisexual coming out guide"),
            Some("beliefs, identity or the law")
        );
        assert_eq!(sensitive_area("Notes on self-harm support"), Some("health"));
        assert_eq!(sensitive_area("Filing the W-2"), Some("money"));
        assert_eq!(
            sensitive_area("Booking the doctor's appointment"),
            Some("health")
        );
        assert_eq!(sensitive_area("use std::collections::HashMap;"), None);
        assert_eq!(sensitive_area("A mental model of the store"), None);
    }

    #[test]
    fn every_term_is_found_as_written() {
        for (area, terms) in SENSITIVE {
            for term in *terms {
                assert_eq!(
                    sensitive_area(&format!("About {term} today")),
                    Some(*area),
                    "{term}"
                );
            }
        }
    }
}
