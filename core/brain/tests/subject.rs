//! What a window is about (`mci_brain::subject`, SPEC 3.12): the rules
//! every Working On name comes from. When unsure there is no subject, and a
//! window with nothing to read never has one.

use mci_brain::subject::{subject_of, SubjectKind};

#[test]
fn a_window_with_nothing_to_read_has_no_subject() {
    assert_eq!(subject_of(None, None, None, None), None);
    assert_eq!(subject_of(Some("com.apple.Notes"), None, None, None), None);
    assert_eq!(subject_of(None, Some(""), None, Some("")), None);
}

#[test]
fn a_generic_title_names_nothing() {
    for title in [
        "Untitled",
        "New Tab",
        "Inbox",
        "Settings",
        "Downloads",
        "zsh",
    ] {
        assert_eq!(
            subject_of(Some("com.apple.Safari"), Some(title), None, None),
            None,
            "{title}"
        );
    }
}

#[test]
fn an_ai_tools_own_terminal_title_names_nothing() {
    for title in ["\u{2733} Claude Code", "claude", "codex"] {
        assert_eq!(
            subject_of(Some("com.apple.Terminal"), Some(title), None, None),
            None,
            "{title}"
        );
    }
}

#[test]
fn kinds_are_the_six_the_window_knows() {
    let kinds = [
        SubjectKind::Code,
        SubjectKind::Document,
        SubjectKind::Design,
        SubjectKind::Spreadsheet,
        SubjectKind::Page,
        SubjectKind::Search,
    ];
    let mut seen = std::collections::HashSet::new();
    for kind in kinds {
        assert!(seen.insert(kind), "{kind:?} is listed once");
    }
}
