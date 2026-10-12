//! The understanding layer: what the brain derives from captured events.
//!
//! - **Interaction counts**: how much typing, clicking and scrolling happened
//!   in each sampling interval (counts only).
//! - **Search queries** read from the URLs of captured pages and windows.
//! - **Propositions**: a general user model (GUM, Shaikh et al. 2025). Each is
//!   a natural-language statement about the user with the model's reasoning,
//!   a confidence, a decay rate and the events it rests on.
//! - **Session notes** and **day reports**: titles, summaries and written
//!   accounts of stretches of work.
//!
//! Everything here is derived from events and goes with them:
//! [`delete_for_events`] runs inside every deletion transaction before the
//! events themselves are removed.

use rusqlite::{params, OptionalExtension, Row, Transaction};
use serde::{Deserialize, Serialize};

use crate::{SqlCipherBrainStore, StoreError};

fn backend(context: &str, error: impl std::fmt::Display) -> StoreError {
    StoreError::Backend(format!("{context}: {error}"))
}

fn sql_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

// ---------------------------------------------------------------------------
// Search queries
// ---------------------------------------------------------------------------

/// A search read from a URL.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchQuery {
    /// Short engine name, e.g. `google`, `youtube`, `github`.
    pub engine: String,
    /// The query as typed, decoded.
    pub query: String,
}

/// Engines recognised by host suffix and path prefix, with the parameter that
/// carries the query. A `None` parameter means the query is the path segment
/// after the prefix.
const ENGINES: &[(&str, &str, &str, Option<&str>)] = &[
    // (engine, host suffix, path prefix, query parameter)
    ("google", "google.", "/search", Some("q")),
    ("google_maps", "google.", "/maps/search/", None),
    ("google_scholar", "scholar.google.", "/scholar", Some("q")),
    ("bing", "bing.com", "/search", Some("q")),
    ("duckduckgo", "duckduckgo.com", "/", Some("q")),
    ("brave", "search.brave.com", "/search", Some("q")),
    ("kagi", "kagi.com", "/search", Some("q")),
    ("ecosia", "ecosia.org", "/search", Some("q")),
    ("yahoo", "search.yahoo.com", "/search", Some("p")),
    ("perplexity", "perplexity.ai", "/search", Some("q")),
    ("chatgpt", "chatgpt.com", "/", Some("q")),
    ("claude", "claude.ai", "/new", Some("q")),
    ("youtube", "youtube.com", "/results", Some("search_query")),
    ("github", "github.com", "/search", Some("q")),
    ("stackoverflow", "stackoverflow.com", "/search", Some("q")),
    ("wikipedia", "wikipedia.org", "/w/index.php", Some("search")),
    ("wikipedia", "wikipedia.org", "/wiki/Special:Search", Some("search")),
    ("amazon", "amazon.", "/s", Some("k")),
    ("reddit", "reddit.com", "/search", Some("q")),
    ("x", "x.com", "/search", Some("q")),
    ("x", "twitter.com", "/search", Some("q")),
    ("linkedin", "linkedin.com", "/search/results/", Some("keywords")),
    ("arxiv", "arxiv.org", "/search", Some("query")),
    ("npm", "npmjs.com", "/search", Some("q")),
    ("crates", "crates.io", "/search", Some("q")),
    ("apple_developer", "developer.apple.com", "/search", Some("q")),
    ("mdn", "developer.mozilla.org", "/", Some("q")),
];

const MAX_QUERY_CHARS: usize = 300;

/// Read the search a URL represents, if any.
///
/// Matching is by host suffix (so `www.google.co.uk` and `en.wikipedia.org`
/// match) and path prefix. The query is percent-decoded, `+` becomes a
/// space, whitespace is collapsed and the result is capped at 300 characters.
#[must_use]
pub fn search_query_from_url(url: &str) -> Option<SearchQuery> {
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))?;
    let (host_and_path, query_string) = match rest.split_once('?') {
        Some((before, after)) => (before, Some(after.split('#').next().unwrap_or(after))),
        None => (rest.split('#').next().unwrap_or(rest), None),
    };
    let (host, path) = match host_and_path.split_once('/') {
        Some((host, path)) => (host, format!("/{path}")),
        None => (host_and_path, "/".to_owned()),
    };
    let host = host.to_ascii_lowercase();
    let host = host.split(':').next().unwrap_or(&host);
    for (engine, suffix, prefix, param) in ENGINES {
        let host_matches = if suffix.ends_with('.') {
            // "google." matches google.com, www.google.co.uk, …
            host.starts_with(suffix) || host.contains(&format!(".{suffix}"))
        } else {
            host == *suffix || host.ends_with(&format!(".{suffix}"))
        };
        if !host_matches || !path.starts_with(prefix) {
            continue;
        }
        let raw = match param {
            Some(name) => query_param(query_string?, name)?,
            None => path[prefix.len()..].split('/').next()?.to_owned(),
        };
        let query = normalise_query(&raw)?;
        return Some(SearchQuery {
            engine: (*engine).to_owned(),
            query,
        });
    }
    None
}

fn query_param(query_string: &str, name: &str) -> Option<String> {
    query_string.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key == name).then(|| value.to_owned())
    })
}

fn normalise_query(raw: &str) -> Option<String> {
    let spaced = raw.replace('+', " ");
    let decoded = percent_decode(&spaced);
    let collapsed = decoded.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.is_empty() {
        return None;
    }
    Some(collapsed.chars().take(MAX_QUERY_CHARS).collect())
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(high), Some(low)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push(high * 16 + low);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

/// A stored search with the app it was seen in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchRecord {
    /// The event whose URL carried the search.
    pub event_id: i64,
    /// When it was seen, microseconds since the Unix epoch.
    pub ts_us: u64,
    /// Short engine name.
    pub engine: String,
    /// The query as typed.
    pub query: String,
    /// The app (browser) it was seen in.
    pub app_bundle_id: Option<String>,
    /// The full URL.
    pub url: Option<String>,
}

// ---------------------------------------------------------------------------
// Interaction counts
// ---------------------------------------------------------------------------

/// Input counts for one sampling interval.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct InteractionCounts {
    /// Interval start, microseconds since the Unix epoch.
    pub start_us: u64,
    /// Interval end (exclusive), at most 60 s after the start.
    pub end_us: u64,
    /// Key presses (counts only).
    pub keys: u32,
    /// Mouse and trackpad clicks.
    pub clicks: u32,
    /// Scroll-wheel and trackpad scroll events.
    pub scrolls: u32,
    /// Pointer moves.
    pub moves: u32,
}

impl InteractionCounts {
    fn validate(&self) -> Result<(), StoreError> {
        if self.start_us == 0
            || self.end_us <= self.start_us
            || self.end_us - self.start_us > 60_000_000
            || self.end_us > i64::MAX as u64
        {
            return Err(StoreError::InvalidInput(
                "invalid interaction interval".into(),
            ));
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Propositions
// ---------------------------------------------------------------------------

/// What a proposition is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PropositionKind {
    /// Something the user is working on.
    Project,
    /// Something the user is trying to achieve.
    Goal,
    /// What is true of the user right now.
    State,
    /// A recurring way the user works.
    Habit,
    /// What the user likes or chooses.
    Preference,
    /// What the user knows or is learning.
    Skill,
    /// Who the user works with.
    Relationship,
    /// Where the user gets stuck.
    Struggle,
}

impl PropositionKind {
    #[must_use]
    /// The stored name.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Project => "project",
            Self::Goal => "goal",
            Self::State => "state",
            Self::Habit => "habit",
            Self::Preference => "preference",
            Self::Skill => "skill",
            Self::Relationship => "relationship",
            Self::Struggle => "struggle",
        }
    }

    #[must_use]
    /// Parse a stored name.
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "project" => Self::Project,
            "goal" => Self::Goal,
            "state" => Self::State,
            "habit" => Self::Habit,
            "preference" => Self::Preference,
            "skill" => Self::Skill,
            "relationship" => Self::Relationship,
            "struggle" => Self::Struggle,
            _ => return None,
        })
    }
}

/// Whether a proposition is in use.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PropositionStatus {
    /// In use.
    Active,
    /// Superseded by a revision.
    Retired,
    /// The user said it is wrong. Kept so it is not proposed again.
    Rejected,
}

impl PropositionStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Retired => "retired",
            Self::Rejected => "rejected",
        }
    }

    fn parse(value: &str) -> Self {
        match value {
            "retired" => Self::Retired,
            "rejected" => Self::Rejected,
            _ => Self::Active,
        }
    }
}

/// A proposition to store.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewProposition {
    /// The statement about the user.
    pub text: String,
    /// How the observations support it.
    pub reasoning: String,
    /// What it is about.
    pub kind: PropositionKind,
    /// 0..=1
    pub confidence: f64,
    /// 0..=1; higher goes stale faster.
    pub decay: f64,
    /// The model that wrote it.
    pub model: String,
}

/// A stored proposition.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Proposition {
    /// Row id.
    pub id: i64,
    /// The statement about the user.
    pub text: String,
    /// How the observations support it.
    pub reasoning: String,
    /// What it is about.
    pub kind: PropositionKind,
    /// 0..=1
    pub confidence: f64,
    /// 0..=1; higher goes stale faster.
    pub decay: f64,
    /// Whether it is in use.
    pub status: PropositionStatus,
    /// When it was first written.
    pub created_us: u64,
    /// When it last changed.
    pub updated_us: u64,
    /// The proposition this one revised.
    pub revised_from: Option<i64>,
    /// The model that wrote it.
    pub model: String,
    /// Event ids it rests on.
    pub evidence: Vec<i64>,
}

impl NewProposition {
    fn validate(&self) -> Result<(), StoreError> {
        let text = self.text.trim();
        if text.is_empty() || text.chars().count() > 1000 {
            return Err(StoreError::InvalidInput("proposition text length".into()));
        }
        if self.reasoning.chars().count() > 4000 {
            return Err(StoreError::InvalidInput("proposition reasoning length".into()));
        }
        if !(0.0..=1.0).contains(&self.confidence) || !(0.0..=1.0).contains(&self.decay) {
            return Err(StoreError::InvalidInput("proposition score range".into()));
        }
        if self.model.is_empty() || self.model.len() > 128 {
            return Err(StoreError::InvalidInput("proposition model".into()));
        }
        Ok(())
    }
}

const PROPOSITION_COLUMNS: &str =
    "id, text, reasoning, kind, confidence, decay, status, created_us, updated_us, revised_from, model";

fn row_to_session_note(row: &Row<'_>) -> rusqlite::Result<SessionNote> {
    Ok(SessionNote {
        start_us: u64::try_from(row.get::<_, i64>(0)?).unwrap_or(0),
        end_us: u64::try_from(row.get::<_, i64>(1)?).unwrap_or(0),
        title: row.get(2)?,
        surface: row.get(3)?,
        beneath: row.get(4)?,
        signals: row.get(5)?,
        event_count: row.get(6)?,
        generated_us: u64::try_from(row.get::<_, i64>(7)?).unwrap_or(0),
        model: row.get(8)?,
    })
}

fn row_to_proposition(row: &Row<'_>) -> rusqlite::Result<Proposition> {
    let kind: String = row.get(3)?;
    let status: String = row.get(6)?;
    Ok(Proposition {
        id: row.get(0)?,
        text: row.get(1)?,
        reasoning: row.get(2)?,
        kind: PropositionKind::parse(&kind).unwrap_or(PropositionKind::State),
        confidence: row.get(4)?,
        decay: row.get(5)?,
        status: PropositionStatus::parse(&status),
        created_us: u64::try_from(row.get::<_, i64>(7)?).unwrap_or(0),
        updated_us: u64::try_from(row.get::<_, i64>(8)?).unwrap_or(0),
        revised_from: row.get(9)?,
        model: row.get(10)?,
        evidence: Vec::new(),
    })
}

// ---------------------------------------------------------------------------
// Episode notes and day reports
// ---------------------------------------------------------------------------

/// A work session: a stretch of activity across apps.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionNote {
    /// First event in the session.
    pub start_us: u64,
    /// Last event in the session.
    pub end_us: u64,
    /// A short title.
    pub title: String,
    /// What was on screen and what the user did.
    pub surface: String,
    /// What lay beneath: intent, attention, hesitation.
    pub beneath: String,
    /// JSON describing the measured signals.
    pub signals: String,
    /// Events the note covers.
    pub event_count: u32,
    /// When it was written.
    pub generated_us: u64,
    /// The model that wrote it.
    pub model: String,
}

/// A written account of one local day.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DayReport {
    /// `YYYY-MM-DD` in the user's time zone.
    pub date_local: String,
    /// Start of the local day.
    pub start_us: u64,
    /// End of the local day (exclusive).
    pub end_us: u64,
    /// When it was written.
    pub generated_us: u64,
    /// The model that wrote it.
    pub model: String,
    /// JSON.
    pub body: String,
}

/// An event with where it came from, for building observations.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ObservedEvent {
    /// Event id.
    pub id: i64,
    /// Capture time.
    pub ts_us: u64,
    /// App it was seen in.
    pub app_bundle_id: Option<String>,
    /// Window or page title.
    pub window_title: Option<String>,
    /// Page URL, if any.
    pub url: Option<String>,
    /// Stored text.
    pub text: String,
    /// `screen_ocr`, `screen_context`, `browser_page`, … (see `EventSource`).
    pub source: String,
}

// ---------------------------------------------------------------------------
// Store methods
// ---------------------------------------------------------------------------

impl SqlCipherBrainStore {
    /// Events in `[start_us, end_us)`, oldest first, with their source, at
    /// most `limit`.
    ///
    /// # Errors
    /// Database failures.
    pub fn observed_events_in_range(
        &self,
        start_us: u64,
        end_us: u64,
        limit: usize,
    ) -> Result<Vec<ObservedEvent>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let has_sources = table_exists(guard.conn(), "event_sources")?;
        let sql = if has_sources {
            "SELECT e.id, e.ts_us, e.app_bundle_id, e.window_title, e.url, e.text,
                    COALESCE(s.source_kind, 'unknown')
             FROM events e LEFT JOIN event_sources s ON s.event_id = e.id
             WHERE e.ts_us >= ?1 AND e.ts_us < ?2 ORDER BY e.ts_us, e.id LIMIT ?3"
        } else {
            "SELECT id, ts_us, app_bundle_id, window_title, url, text, 'unknown'
             FROM events WHERE ts_us >= ?1 AND ts_us < ?2 ORDER BY ts_us, id LIMIT ?3"
        };
        let mut statement = guard
            .conn()
            .prepare(sql)
            .map_err(|e| backend("prepare observed events", e))?;
        let rows = statement
            .query_map(
                params![sql_i64(start_us), sql_i64(end_us), i64::try_from(limit).unwrap_or(i64::MAX)],
                |row| {
                    Ok(ObservedEvent {
                        id: row.get(0)?,
                        ts_us: u64::try_from(row.get::<_, i64>(1)?).unwrap_or(0),
                        app_bundle_id: row.get(2)?,
                        window_title: row.get(3)?,
                        url: row.get(4)?,
                        text: row.get(5)?,
                        source: row.get(6)?,
                    })
                },
            )
            .map_err(|e| backend("query observed events", e))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| backend("read observed events", e))
    }

    /// Record one interval's input counts. Returns false when an interval
    /// starting at the same time is already stored.
    ///
    /// # Errors
    /// Invalid intervals and database failures.
    pub fn append_interaction_counts(&self, counts: &InteractionCounts) -> Result<bool, StoreError> {
        counts.validate()?;
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let changed = guard
            .conn()
            .execute(
                "INSERT OR IGNORE INTO interaction_counts (start_us, end_us, keys, clicks, scrolls, moves)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    sql_i64(counts.start_us),
                    sql_i64(counts.end_us),
                    counts.keys,
                    counts.clicks,
                    counts.scrolls,
                    counts.moves
                ],
            )
            .map_err(|e| backend("insert interaction counts", e))?;
        Ok(changed == 1)
    }

    /// Interaction counts whose interval starts in `[start_us, end_us)`.
    ///
    /// # Errors
    /// Database failures.
    pub fn interaction_counts_in_range(
        &self,
        start_us: u64,
        end_us: u64,
    ) -> Result<Vec<InteractionCounts>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        if !table_exists(guard.conn(), "interaction_counts")? {
            return Ok(Vec::new());
        }
        let mut statement = guard
            .conn()
            .prepare(
                "SELECT start_us, end_us, keys, clicks, scrolls, moves FROM interaction_counts
                 WHERE start_us >= ?1 AND start_us < ?2 ORDER BY start_us",
            )
            .map_err(|e| backend("prepare interaction counts", e))?;
        let rows = statement
            .query_map(params![sql_i64(start_us), sql_i64(end_us)], |row| {
                Ok(InteractionCounts {
                    start_us: u64::try_from(row.get::<_, i64>(0)?).unwrap_or(0),
                    end_us: u64::try_from(row.get::<_, i64>(1)?).unwrap_or(0),
                    keys: row.get(2)?,
                    clicks: row.get(3)?,
                    scrolls: row.get(4)?,
                    moves: row.get(5)?,
                })
            })
            .map_err(|e| backend("query interaction counts", e))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| backend("read interaction counts", e))
    }

    /// Store the search an event's URL represents. Returns whether one was found.
    ///
    /// # Errors
    /// Database failures.
    pub fn record_search_query(&self, event_id: i64, ts_us: u64, url: &str) -> Result<bool, StoreError> {
        let Some(search) = search_query_from_url(url) else {
            return Ok(false);
        };
        let guard = self.db.lock().expect("brain store mutex poisoned");
        guard
            .conn()
            .execute(
                "INSERT OR REPLACE INTO search_queries (event_id, ts_us, engine, query)
                 SELECT ?1, ?2, ?3, ?4 WHERE EXISTS (SELECT 1 FROM events WHERE id = ?1)",
                params![event_id, sql_i64(ts_us), search.engine, search.query],
            )
            .map_err(|e| backend("insert search query", e))?;
        Ok(true)
    }

    /// Extract searches from up to `limit` events after `after_id` (by id).
    /// Returns how many searches were added and the last id examined, which
    /// the caller passes back next time.
    ///
    /// # Errors
    /// Database failures.
    pub fn backfill_search_queries(&self, after_id: i64, limit: usize) -> Result<(usize, i64), StoreError> {
        let candidates: Vec<(i64, i64, Option<String>)> = {
            let guard = self.db.lock().expect("brain store mutex poisoned");
            let mut statement = guard
                .conn()
                .prepare("SELECT id, ts_us, url FROM events WHERE id > ?1 ORDER BY id LIMIT ?2")
                .map_err(|e| backend("prepare search backfill", e))?;
            let rows = statement
                .query_map(params![after_id, i64::try_from(limit).unwrap_or(i64::MAX)], |row| {
                    Ok((row.get(0)?, row.get(1)?, row.get(2)?))
                })
                .map_err(|e| backend("query search backfill", e))?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| backend("read search backfill", e))?
        };
        let mut added = 0;
        let mut last = after_id;
        for (id, ts, url) in candidates {
            last = id;
            if let Some(url) = url.filter(|u| u.starts_with("http")) {
                if self.record_search_query(id, u64::try_from(ts).unwrap_or(0), &url)? {
                    added += 1;
                }
            }
        }
        Ok((added, last))
    }

    /// Searches in `[start_us, end_us)`, newest first. Repeats of the same
    /// query on the same engine within a minute collapse to the first.
    ///
    /// # Errors
    /// Database failures.
    pub fn search_queries_in_range(
        &self,
        start_us: u64,
        end_us: u64,
        limit: usize,
    ) -> Result<Vec<SearchRecord>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        if !table_exists(guard.conn(), "search_queries")? {
            return Ok(Vec::new());
        }
        let mut statement = guard
            .conn()
            .prepare(
                "SELECT s.event_id, s.ts_us, s.engine, s.query, e.app_bundle_id, e.url
                 FROM search_queries s JOIN events e ON e.id = s.event_id
                 WHERE s.ts_us >= ?1 AND s.ts_us < ?2
                 ORDER BY s.ts_us ASC",
            )
            .map_err(|e| backend("prepare search queries", e))?;
        let rows = statement
            .query_map(params![sql_i64(start_us), sql_i64(end_us)], |row| {
                Ok(SearchRecord {
                    event_id: row.get(0)?,
                    ts_us: u64::try_from(row.get::<_, i64>(1)?).unwrap_or(0),
                    engine: row.get(2)?,
                    query: row.get(3)?,
                    app_bundle_id: row.get(4)?,
                    url: row.get(5)?,
                })
            })
            .map_err(|e| backend("query search queries", e))?;
        let all = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| backend("read search queries", e))?;
        let mut collapsed: Vec<SearchRecord> = Vec::new();
        for record in all {
            let repeat = collapsed.iter().rev().take(8).any(|seen| {
                seen.engine == record.engine
                    && seen.query.eq_ignore_ascii_case(&record.query)
                    && record.ts_us.saturating_sub(seen.ts_us) < 60_000_000
            });
            if !repeat {
                collapsed.push(record);
            }
        }
        collapsed.reverse();
        collapsed.truncate(limit);
        Ok(collapsed)
    }

    /// Store a proposition resting on `evidence` (event ids). Evidence that no
    /// longer exists is skipped. Returns the new id.
    ///
    /// # Errors
    /// Invalid propositions and database failures.
    pub fn insert_proposition(
        &self,
        proposition: &NewProposition,
        evidence: &[i64],
        now_us: u64,
    ) -> Result<i64, StoreError> {
        self.write_proposition(proposition, evidence, now_us, None)
    }

    /// Replace `previous` with a revision: the old row is retired, the new one
    /// carries the union of both evidence sets.
    ///
    /// # Errors
    /// Invalid propositions, an unknown `previous`, and database failures.
    pub fn revise_proposition(
        &self,
        previous: i64,
        proposition: &NewProposition,
        evidence: &[i64],
        now_us: u64,
    ) -> Result<i64, StoreError> {
        self.write_proposition(proposition, evidence, now_us, Some(previous))
    }

    fn write_proposition(
        &self,
        proposition: &NewProposition,
        evidence: &[i64],
        now_us: u64,
        previous: Option<i64>,
    ) -> Result<i64, StoreError> {
        proposition.validate()?;
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| backend("begin proposition write", e))?;
        let mut all_evidence: Vec<i64> = evidence.to_vec();
        if let Some(previous) = previous {
            let exists: bool = tx
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM propositions WHERE id = ?1)",
                    params![previous],
                    |row| row.get(0),
                )
                .map_err(|e| backend("probe revised proposition", e))?;
            if !exists {
                return Err(StoreError::InvalidInput("unknown proposition".into()));
            }
            let mut statement = tx
                .prepare("SELECT event_id FROM proposition_evidence WHERE proposition_id = ?1")
                .map_err(|e| backend("prepare previous evidence", e))?;
            let rows = statement
                .query_map(params![previous], |row| row.get::<_, i64>(0))
                .map_err(|e| backend("query previous evidence", e))?;
            for row in rows {
                all_evidence.push(row.map_err(|e| backend("read previous evidence", e))?);
            }
            drop(statement);
            tx.execute(
                "UPDATE propositions SET status = 'retired', updated_us = ?2 WHERE id = ?1",
                params![previous, sql_i64(now_us)],
            )
            .map_err(|e| backend("retire revised proposition", e))?;
        }
        tx.execute(
            "INSERT INTO propositions (text, reasoning, kind, confidence, decay, status, created_us, updated_us, revised_from, model)
             VALUES (?1, ?2, ?3, ?4, ?5, 'active', ?6, ?6, ?7, ?8)",
            params![
                proposition.text.trim(),
                proposition.reasoning.trim(),
                proposition.kind.as_str(),
                proposition.confidence,
                proposition.decay,
                sql_i64(now_us),
                previous,
                proposition.model
            ],
        )
        .map_err(|e| backend("insert proposition", e))?;
        let id = tx.last_insert_rowid();
        all_evidence.sort_unstable();
        all_evidence.dedup();
        for event_id in all_evidence {
            tx.execute(
                "INSERT OR IGNORE INTO proposition_evidence (proposition_id, event_id)
                 SELECT ?1, ?2 WHERE EXISTS (SELECT 1 FROM events WHERE id = ?2)",
                params![id, event_id],
            )
            .map_err(|e| backend("link proposition evidence", e))?;
        }
        tx.commit().map_err(|e| backend("commit proposition write", e))?;
        Ok(id)
    }

    /// Mark a proposition active, retired or rejected.
    ///
    /// # Errors
    /// Database failures.
    pub fn set_proposition_status(
        &self,
        id: i64,
        status: PropositionStatus,
        now_us: u64,
    ) -> Result<bool, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let changed = guard
            .conn()
            .execute(
                "UPDATE propositions SET status = ?2, updated_us = ?3 WHERE id = ?1",
                params![id, status.as_str(), sql_i64(now_us)],
            )
            .map_err(|e| backend("update proposition status", e))?;
        Ok(changed == 1)
    }

    /// The user said a proposition is right: it becomes certain and slow to
    /// go stale. Returns whether it existed.
    ///
    /// # Errors
    /// Database failures.
    pub fn confirm_proposition(&self, id: i64, now_us: u64) -> Result<bool, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let changed = guard
            .conn()
            .execute(
                "UPDATE propositions SET confidence = 1.0, decay = MIN(decay, 0.3), status = 'active', updated_us = ?2
                 WHERE id = ?1",
                params![id, sql_i64(now_us)],
            )
            .map_err(|e| backend("confirm proposition", e))?;
        Ok(changed == 1)
    }

    /// Permanently delete a proposition (the user asked to forget it).
    ///
    /// # Errors
    /// Database failures.
    pub fn delete_proposition(&self, id: i64) -> Result<bool, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let changed = guard
            .conn()
            .execute("DELETE FROM propositions WHERE id = ?1", params![id])
            .map_err(|e| backend("delete proposition", e))?;
        Ok(changed == 1)
    }

    /// Propositions with `status`, most recently updated first.
    ///
    /// # Errors
    /// Database failures.
    pub fn propositions_with_status(
        &self,
        status: PropositionStatus,
        limit: usize,
    ) -> Result<Vec<Proposition>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        if !table_exists(guard.conn(), "propositions")? {
            return Ok(Vec::new());
        }
        let sql = format!(
            "SELECT {PROPOSITION_COLUMNS} FROM propositions WHERE status = ?1
             ORDER BY updated_us DESC LIMIT ?2"
        );
        let mut statement = guard
            .conn()
            .prepare(&sql)
            .map_err(|e| backend("prepare propositions", e))?;
        let rows = statement
            .query_map(
                params![status.as_str(), i64::try_from(limit).unwrap_or(i64::MAX)],
                row_to_proposition,
            )
            .map_err(|e| backend("query propositions", e))?;
        let mut out = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| backend("read propositions", e))?;
        attach_evidence(guard.conn(), &mut out)?;
        Ok(out)
    }

    /// Full-text candidates for a proposition (BM25 over text and
    /// reasoning), any status, best first, with the BM25 score (lower is
    /// better, per `SQLite`).
    ///
    /// # Errors
    /// Database failures.
    pub fn search_propositions(
        &self,
        query: &str,
        limit: usize,
    ) -> Result<Vec<(Proposition, f64)>, StoreError> {
        let match_expr = or_query(query);
        if match_expr.is_empty() {
            return Ok(Vec::new());
        }
        let guard = self.db.lock().expect("brain store mutex poisoned");
        if !table_exists(guard.conn(), "propositions")? {
            return Ok(Vec::new());
        }
        let sql = format!(
            "SELECT {}, bm25(propositions_fts) AS rank FROM propositions_fts
             JOIN propositions p ON p.id = propositions_fts.rowid
             WHERE propositions_fts MATCH ?1 ORDER BY rank LIMIT ?2",
            PROPOSITION_COLUMNS
                .split(", ")
                .map(|c| format!("p.{c}"))
                .collect::<Vec<_>>()
                .join(", ")
        );
        let mut statement = guard
            .conn()
            .prepare(&sql)
            .map_err(|e| backend("prepare proposition search", e))?;
        let rows = statement
            .query_map(
                params![match_expr, i64::try_from(limit).unwrap_or(i64::MAX)],
                |row| Ok((row_to_proposition(row)?, row.get::<_, f64>(11)?)),
            )
            .map_err(|e| backend("query proposition search", e))?;
        let found = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| backend("read proposition search", e))?;
        let (mut props, scores): (Vec<_>, Vec<_>) = found.into_iter().unzip();
        attach_evidence(guard.conn(), &mut props)?;
        Ok(props.into_iter().zip(scores).collect())
    }

    /// Store or replace a session's note (keyed by its start).
    ///
    /// # Errors
    /// Database failures.
    pub fn put_session_note(&self, note: &SessionNote) -> Result<(), StoreError> {
        if note.end_us < note.start_us || note.start_us == 0 {
            return Err(StoreError::InvalidInput("invalid session bounds".into()));
        }
        let guard = self.db.lock().expect("brain store mutex poisoned");
        guard
            .conn()
            .execute(
                "INSERT OR REPLACE INTO session_notes
                     (start_us, end_us, title, surface, beneath, signals, event_count, generated_us, model)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    sql_i64(note.start_us),
                    sql_i64(note.end_us),
                    note.title.chars().take(200).collect::<String>(),
                    note.surface.chars().take(4000).collect::<String>(),
                    note.beneath.chars().take(4000).collect::<String>(),
                    note.signals,
                    note.event_count,
                    sql_i64(note.generated_us),
                    note.model
                ],
            )
            .map_err(|e| backend("write session note", e))?;
        Ok(())
    }

    /// Notes for sessions overlapping `[start_us, end_us)`, oldest first.
    ///
    /// # Errors
    /// Database failures.
    pub fn session_notes_in_range(&self, start_us: u64, end_us: u64) -> Result<Vec<SessionNote>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        if !table_exists(guard.conn(), "session_notes")? {
            return Ok(Vec::new());
        }
        let mut statement = guard
            .conn()
            .prepare(
                "SELECT start_us, end_us, title, surface, beneath, signals, event_count, generated_us, model
                 FROM session_notes WHERE end_us >= ?1 AND start_us < ?2 ORDER BY start_us",
            )
            .map_err(|e| backend("prepare session notes", e))?;
        let rows = statement
            .query_map(params![sql_i64(start_us), sql_i64(end_us)], row_to_session_note)
            .map_err(|e| backend("query session notes", e))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| backend("read session notes", e))
    }

    /// Delete session notes overlapping `[start_us, end_us)` (to rewrite them).
    ///
    /// # Errors
    /// Database failures.
    pub fn delete_session_notes_in_range(&self, start_us: u64, end_us: u64) -> Result<usize, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        guard
            .conn()
            .execute(
                "DELETE FROM session_notes WHERE end_us >= ?1 AND start_us < ?2",
                params![sql_i64(start_us), sql_i64(end_us)],
            )
            .map_err(|e| backend("delete session notes", e))
    }

    /// Store or replace a day's report.
    ///
    /// # Errors
    /// Database failures.
    pub fn put_day_report(&self, report: &DayReport) -> Result<(), StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        guard
            .conn()
            .execute(
                "INSERT OR REPLACE INTO day_reports (date_local, start_us, end_us, generated_us, model, body)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    report.date_local,
                    sql_i64(report.start_us),
                    sql_i64(report.end_us),
                    sql_i64(report.generated_us),
                    report.model,
                    report.body
                ],
            )
            .map_err(|e| backend("write day report", e))?;
        Ok(())
    }

    /// The report for a local date, if written.
    ///
    /// # Errors
    /// Database failures.
    pub fn day_report(&self, date_local: &str) -> Result<Option<DayReport>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        if !table_exists(guard.conn(), "day_reports")? {
            return Ok(None);
        }
        guard
            .conn()
            .query_row(
                "SELECT date_local, start_us, end_us, generated_us, model, body
                 FROM day_reports WHERE date_local = ?1",
                params![date_local],
                |row| {
                    Ok(DayReport {
                        date_local: row.get(0)?,
                        start_us: u64::try_from(row.get::<_, i64>(1)?).unwrap_or(0),
                        end_us: u64::try_from(row.get::<_, i64>(2)?).unwrap_or(0),
                        generated_us: u64::try_from(row.get::<_, i64>(3)?).unwrap_or(0),
                        model: row.get(4)?,
                        body: row.get(5)?,
                    })
                },
            )
            .optional()
            .map_err(|e| backend("read day report", e))
    }

    /// Clear every inference (propositions, session notes, day reports and
    /// progress markers) so they are made again. Measurements (searches and
    /// interaction counts) are kept.
    ///
    /// # Errors
    /// Database failures.
    pub fn reset_understanding(&self) -> Result<(), StoreError> {
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| backend("begin understanding reset", e))?;
        tx.execute_batch(
            "DELETE FROM proposition_evidence;
             DELETE FROM propositions;
             DELETE FROM session_notes;
             DELETE FROM day_reports;
             DELETE FROM understanding_state WHERE key <> 'searches_through_event_id';",
        )
        .map_err(|e| backend("reset understanding", e))?;
        tx.commit().map_err(|e| backend("commit understanding reset", e))
    }

    /// Read a progress marker.
    ///
    /// # Errors
    /// Database failures.
    pub fn understanding_state(&self, key: &str) -> Result<Option<String>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        if !table_exists(guard.conn(), "understanding_state")? {
            return Ok(None);
        }
        guard
            .conn()
            .query_row(
                "SELECT value FROM understanding_state WHERE key = ?1",
                params![key],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| backend("read understanding state", e))
    }

    /// Write a progress marker.
    ///
    /// # Errors
    /// Database failures.
    pub fn set_understanding_state(&self, key: &str, value: &str) -> Result<(), StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        guard
            .conn()
            .execute(
                "INSERT OR REPLACE INTO understanding_state (key, value) VALUES (?1, ?2)",
                params![key, value],
            )
            .map_err(|e| backend("write understanding state", e))?;
        Ok(())
    }
}

/// An FTS5 expression that matches any of the query's words, so a candidate
/// proposition needs to share only some vocabulary with the new one.
fn or_query(query: &str) -> String {
    let mut words: Vec<String> = query
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| w.chars().count() >= 3)
        .map(|w| format!("\"{}\"", w.to_lowercase()))
        .collect();
    words.sort();
    words.dedup();
    words.truncate(24);
    words.join(" OR ")
}

fn table_exists(conn: &rusqlite::Connection, name: &str) -> Result<bool, StoreError> {
    conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = ?1)",
        params![name],
        |row| row.get(0),
    )
    .map_err(|e| backend("probe understanding schema", e))
}

fn attach_evidence(conn: &rusqlite::Connection, props: &mut [Proposition]) -> Result<(), StoreError> {
    let mut statement = conn
        .prepare("SELECT event_id FROM proposition_evidence WHERE proposition_id = ?1 ORDER BY event_id")
        .map_err(|e| backend("prepare proposition evidence", e))?;
    for prop in props {
        let rows = statement
            .query_map(params![prop.id], |row| row.get::<_, i64>(0))
            .map_err(|e| backend("query proposition evidence", e))?;
        prop.evidence = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| backend("read proposition evidence", e))?;
    }
    Ok(())
}

/// Delete everything derived from `event_ids`, inside the caller's deletion
/// transaction and before the events go: every proposition that cites one of
/// them (not only the link), the notes of sessions containing them, and the
/// reports of days they fall on. Searches cascade from their event.
pub(crate) fn delete_for_events(tx: &Transaction<'_>, event_ids: &[i64]) -> Result<(), StoreError> {
    if event_ids.is_empty() || !table_exists(tx, "propositions")? {
        return Ok(());
    }
    tx.execute_batch(
        "CREATE TEMP TABLE IF NOT EXISTS understanding_events_pending_delete (
             id INTEGER PRIMARY KEY
         ) WITHOUT ROWID;
         DELETE FROM understanding_events_pending_delete;",
    )
    .map_err(|e| backend("stage understanding deletion", e))?;
    {
        let mut insert = tx
            .prepare("INSERT OR IGNORE INTO understanding_events_pending_delete (id) VALUES (?1)")
            .map_err(|e| backend("prepare understanding deletion", e))?;
        for id in event_ids {
            insert
                .execute(params![id])
                .map_err(|e| backend("stage understanding event", e))?;
        }
    }
    tx.execute_batch(
        "DELETE FROM propositions WHERE id IN (
             SELECT proposition_id FROM proposition_evidence
             WHERE event_id IN (SELECT id FROM understanding_events_pending_delete));
         DELETE FROM session_notes WHERE EXISTS (
             SELECT 1 FROM events e
             WHERE e.id IN (SELECT id FROM understanding_events_pending_delete)
               AND e.ts_us >= session_notes.start_us AND e.ts_us <= session_notes.end_us);
         DELETE FROM day_reports WHERE EXISTS (
             SELECT 1 FROM events e
             WHERE e.id IN (SELECT id FROM understanding_events_pending_delete)
               AND e.ts_us >= day_reports.start_us AND e.ts_us < day_reports.end_us);
         DELETE FROM search_queries WHERE event_id IN (SELECT id FROM understanding_events_pending_delete);
         DELETE FROM understanding_events_pending_delete;",
    )
    .map_err(|e| backend("delete understanding for events", e))?;
    Ok(())
}

/// Remove interaction counts in a half-open range (alongside measured activity).
pub(crate) fn delete_interactions_in_range(
    tx: &Transaction<'_>,
    start_us: i64,
    end_us: i64,
) -> Result<(), StoreError> {
    if start_us >= end_us || !table_exists(tx, "interaction_counts")? {
        return Ok(());
    }
    tx.execute(
        "DELETE FROM interaction_counts WHERE start_us < ?2 AND end_us > ?1",
        params![start_us, end_us],
    )
    .map_err(|e| backend("delete interaction counts", e))?;
    Ok(())
}

/// Remove every derived row (for a full wipe).
pub(crate) fn wipe(tx: &Transaction<'_>) -> Result<(), StoreError> {
    if !table_exists(tx, "propositions")? {
        return Ok(());
    }
    tx.execute_batch(
        "DELETE FROM proposition_evidence;
         DELETE FROM propositions;
         DELETE FROM session_notes;
         DELETE FROM day_reports;
         DELETE FROM search_queries;
         DELETE FROM interaction_counts;
         DELETE FROM understanding_state;",
    )
    .map_err(|e| backend("wipe understanding", e))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn q(url: &str) -> Option<(String, String)> {
        search_query_from_url(url).map(|s| (s.engine, s.query))
    }

    #[test]
    fn reads_searches_from_common_engines() {
        assert_eq!(
            q("https://www.google.com/search?q=team+plan+pricing&oq=team"),
            Some(("google".into(), "team plan pricing".into()))
        );
        assert_eq!(
            q("https://www.google.co.uk/search?client=safari&q=caf%C3%A9+near+me"),
            Some(("google".into(), "café near me".into()))
        );
        assert_eq!(
            q("https://duckduckgo.com/?q=rust+borrow+checker&ia=web"),
            Some(("duckduckgo".into(), "rust borrow checker".into()))
        );
        assert_eq!(
            q("https://www.youtube.com/results?search_query=swiftui+lists"),
            Some(("youtube".into(), "swiftui lists".into()))
        );
        assert_eq!(
            q("https://github.com/search?q=sqlcipher%20fts5&type=code"),
            Some(("github".into(), "sqlcipher fts5".into()))
        );
        assert_eq!(
            q("https://en.wikipedia.org/w/index.php?search=hippocampus&title=Special%3ASearch"),
            Some(("wikipedia".into(), "hippocampus".into()))
        );
        assert_eq!(
            q("https://www.google.com/maps/search/bike+repair/@47.6,-122.3,14z"),
            Some(("google_maps".into(), "bike repair".into()))
        );
        assert_eq!(
            q("https://www.amazon.com/s?k=usb-c+hub"),
            Some(("amazon".into(), "usb-c hub".into()))
        );
        assert_eq!(
            q("https://www.perplexity.ai/search?q=what+is+gum"),
            Some(("perplexity".into(), "what is gum".into()))
        );
    }

    #[test]
    fn ignores_pages_that_are_not_searches() {
        assert_eq!(q("https://www.google.com/"), None);
        assert_eq!(q("https://docs.google.com/document/d/abc/edit"), None);
        assert_eq!(q("https://github.com/amyjainberkeley/hippocampus"), None);
        assert_eq!(q("https://www.google.com/search?q=+++"), None);
        assert_eq!(q("file:///Users/me/notes.txt"), None);
        assert_eq!(q("https://notgoogle.example/search?q=x"), None);
        assert_eq!(q("https://evilbing.com/search?q=x"), None);
    }

    #[test]
    fn caps_long_queries() {
        let long = format!("https://www.google.com/search?q={}", "a".repeat(1000));
        assert_eq!(q(&long).map(|(_, query)| query.len()), Some(300));
    }

    #[test]
    fn or_query_quotes_words() {
        assert_eq!(or_query("The user prices a team plan!"), "\"plan\" OR \"prices\" OR \"team\" OR \"the\" OR \"user\"");
        assert_eq!(or_query("a b"), "");
    }
}
