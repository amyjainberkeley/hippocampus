//! What a window is about: the code project, document, design,
//! spreadsheet, page or search its title names (SPEC 3.12.1).
//!
//! [`subject_of`] reads only what a caption reads: the app, the window's
//! title, the page's host and the first line of what was on screen. It is to
//! share the caption rules' title cleaning (`caption.rs`), so a Working On
//! name and a History caption can never disagree. No model is asked
//! anything, and when unsure there is no subject.
//!
//! A seam for now: until the rules and their fixtures
//! (`core/brain/tests/subject.rs`) land with Working On, no window has a
//! subject, so Working On lists nothing.

use serde::{Deserialize, Serialize};

/// What kind of thing a window is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SubjectKind {
    /// A folder of code an editor or a terminal is open in.
    Code,
    /// Docs, notes, slides and PDFs.
    Document,
    /// A design.
    Design,
    /// A spreadsheet.
    Spreadsheet,
    /// A web page. Web Pages lists it; it is never a Working On item.
    Page,
    /// A search. Looked Up lists it.
    Search,
}

/// What a window is about: its kind, its name, and for code, the file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Subject {
    /// What kind of thing it is.
    pub kind: SubjectKind,
    /// Its name as the title writes it: "trailhead-shop", "Q4 planning".
    pub name: String,
    /// The part of it the window shows: for code, the file ("tax.rs").
    pub part: Option<String>,
}

/// What the window titled `title` in `app` (a bundle id) is about, with the
/// page's `host` and the `first_line` of its text when they are known.
/// `None` when unsure.
#[must_use]
pub fn subject_of(
    app: Option<&str>,
    title: Option<&str>,
    host: Option<&str>,
    first_line: Option<&str>,
) -> Option<Subject> {
    let _ = (app, title, host, first_line);
    None
}
