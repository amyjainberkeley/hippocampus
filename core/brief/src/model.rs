//! Brief model types — `Brief`, `BriefId`, `BriefState`.

use std::fmt;

use mci_brain::EventId;
/// Stable identifier for one [`Brief`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct BriefId(pub u64);

impl fmt::Display for BriefId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "brief:{}", self.0)
    }
}

/// 5-state lifecycle per ADR-0018 §2.
///
/// Transitions are explicit + tested in [`crate::lifecycle::advance`].
/// Every `(BriefState, LifecycleAction)` pair is handled — no implicit
/// states, no wildcard arms.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BriefState {
    /// LLM (or stub) produced a draft. Not yet reviewed.
    Draft,
    /// User opened the draft for review + edit. Tripwire runs here.
    Reviewing,
    /// User explicitly approved. Requires `human_approver_id`.
    Approved,
    /// Brief synced to workspace server (ADR-0019 territory).
    Synced,
    /// Terminal state. Brief retained for audit trail.
    Archived,
}

impl fmt::Display for BriefState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Draft => write!(f, "Draft"),
            Self::Reviewing => write!(f, "Reviewing"),
            Self::Approved => write!(f, "Approved"),
            Self::Synced => write!(f, "Synced"),
            Self::Archived => write!(f, "Archived"),
        }
    }
}

/// One authored brief — the Tier-2 sync unit per ADR-0018/ADR-0019.
#[derive(Debug, Clone, PartialEq)]
pub struct Brief {
    /// Store-assigned id. Zero until persisted.
    pub id: BriefId,
    /// Brief title (from topic or user edit).
    pub title: String,
    /// Markdown body — the content the user reviews + redacts.
    pub body: String,
    /// Source event IDs this brief claims as backing evidence.
    /// Every citation must resolve to a real event in the brain;
    /// the tripwire enforces this structurally.
    pub citations: Vec<EventId>,
    /// Current lifecycle state.
    pub state: BriefState,
    /// Creation timestamp in microseconds since UNIX epoch.
    pub created_ts_us: u64,
    /// Last-modified timestamp in microseconds since UNIX epoch.
    pub updated_ts_us: u64,
    /// Set on approval. `None` until the user explicitly approves.
    /// ADR-0018 §4.1: no brief reaches Approved without this field.
    pub human_approver_id: Option<String>,
}
