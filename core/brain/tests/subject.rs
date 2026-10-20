//! What a window is about (`mci_brain::subject`, SPEC 3.12): the rules
//! every Working On name comes from. Each app's fixtures are its exact title
//! strings (SPEC 3.12.6). When unsure there is no subject, a window with
//! nothing to read never has one, and no AI tool's own terminal title ever
//! names anything.

use mci_brain::subject::{
    folded, identity, is_never_a_name_at, subject_of, subject_of_at, terminal_folder_at, Subject,
    SubjectKind, MIN_NAME_CHARS,
};

const VS_CODE: &str = "com.microsoft.VSCode";
const CURSOR: &str = "com.todesktop.230313mzl4w4u92";
const ZED: &str = "dev.zed.Zed";
const XCODE: &str = "com.apple.dt.Xcode";
const TERMINAL: &str = "com.apple.Terminal";
const ITERM: &str = "com.googlecode.iterm2";
const GHOSTTY: &str = "com.mitchellh.ghostty";
const WARP: &str = "dev.warp.Warp-Stable";
const CHROME: &str = "com.google.Chrome";
const SAFARI: &str = "com.apple.Safari";

/// Every test's person keeps their home folder at /Users/dev, so a
/// terminal open there names nothing.
const HOME: Option<&str> = Some("dev");

fn subject(app: &str, title: &str) -> Option<Subject> {
    subject_of_at(Some(app), Some(title), None, None, HOME)
}

fn on(app: &str, title: &str, host: &str) -> Option<Subject> {
    subject_of_at(Some(app), Some(title), Some(host), None, HOME)
}

fn terminal_folder(title: &str) -> Option<mci_brain::subject::TerminalFolder> {
    terminal_folder_at(title, HOME)
}

fn is_never_a_name(name: &str) -> bool {
    is_never_a_name_at(name, HOME)
}

#[allow(clippy::unnecessary_wraps)] // compared with what `subject_of` gives, an Option
fn named(kind: SubjectKind, name: &str, part: Option<&str>) -> Option<Subject> {
    Some(Subject {
        kind,
        name: name.to_owned(),
        part: part.map(str::to_owned),
    })
}

fn code(name: &str, part: Option<&str>) -> Option<Subject> {
    named(SubjectKind::Code, name, part)
}

#[test]
fn a_window_with_nothing_to_read_has_no_subject() {
    assert_eq!(subject_of(None, None, None, None), None);
    assert_eq!(subject_of(Some("com.apple.Notes"), None, None, None), None);
    assert_eq!(subject_of(None, Some(""), None, Some("")), None);
    assert_eq!(
        subject_of(Some(""), Some("tax.rs — trailhead-shop"), None, None),
        None
    );
}

#[test]
fn vs_code_cursor_and_windsurf_name_the_folder_after_the_file() {
    for (app, title) in [
        (
            VS_CODE,
            "\u{25cf} tax.rs \u{2014} trailhead-shop \u{2014} Visual Studio Code",
        ),
        (
            VS_CODE,
            "tax.rs \u{2014} trailhead-shop \u{2014} Visual Studio Code",
        ),
        (
            VS_CODE,
            "tax.rs \u{2014} trailhead-shop [SSH: devbox] \u{2014} Visual Studio Code",
        ),
        (
            VS_CODE,
            "tax.rs \u{2014} trailhead-shop (Workspace) \u{2014} Visual Studio Code",
        ),
        (
            "com.microsoft.VSCodeInsiders",
            "tax.rs \u{2014} trailhead-shop \u{2014} Visual Studio Code - Insiders",
        ),
        (CURSOR, "tax.rs \u{2014} trailhead-shop \u{2014} Cursor"),
        (CURSOR, "\u{25cf} tax.rs \u{2014} trailhead-shop"),
        (
            "com.exafunction.windsurf",
            "tax.rs \u{2014} trailhead-shop \u{2014} Windsurf",
        ),
        (
            "com.vscodium",
            "tax.rs \u{2014} trailhead-shop \u{2014} VSCodium",
        ),
    ] {
        assert_eq!(
            subject(app, title),
            code("trailhead-shop", Some("tax.rs")),
            "{title}"
        );
    }
    assert_eq!(
        subject(VS_CODE, "trailhead-shop \u{2014} Visual Studio Code"),
        code("trailhead-shop", None)
    );
    assert_eq!(
        subject(
            VS_CODE,
            "Untitled-1 \u{2014} trailhead-shop \u{2014} Visual Studio Code"
        ),
        code("trailhead-shop", None),
        "an unsaved file is no part"
    );
    assert_eq!(
        subject(
            VS_CODE,
            "Extension: rust-analyzer \u{2014} trailhead-shop \u{2014} Visual Studio Code"
        ),
        code("trailhead-shop", None)
    );
    for title in [
        "tax.rs \u{2014} Visual Studio Code",
        "Welcome \u{2014} Visual Studio Code",
        "Get Started \u{2014} Visual Studio Code",
        "Visual Studio Code",
        "Settings \u{2014} Visual Studio Code",
    ] {
        assert_eq!(subject(VS_CODE, title), None, "{title}");
    }
}

#[test]
fn zed_names_the_project_first() {
    assert_eq!(
        subject(ZED, "trailhead-shop \u{2014} tax.rs"),
        code("trailhead-shop", Some("tax.rs"))
    );
    assert_eq!(
        subject(ZED, "trailhead-shop \u{2014} src/tax.rs"),
        code("trailhead-shop", Some("tax.rs"))
    );
    assert_eq!(subject(ZED, "trailhead-shop"), code("trailhead-shop", None));
    assert_eq!(
        subject(ZED, "tax.rs \u{2014} trailhead-shop"),
        code("trailhead-shop", Some("tax.rs"))
    );
    assert_eq!(subject(ZED, "Zed"), None);
    assert_eq!(subject(ZED, "empty project"), code("empty project", None));
}

#[test]
fn jetbrains_ides_prefer_the_bracketed_project() {
    for app in [
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.rustrover",
        "com.jetbrains.goland",
    ] {
        assert_eq!(
            subject(app, "trailhead-shop \u{2013} src/tax.rs [trailhead-shop]"),
            code("trailhead-shop", Some("tax.rs")),
            "{app}"
        );
        assert_eq!(
            subject(app, "trailhead-shop \u{2013} tax.rs"),
            code("trailhead-shop", Some("tax.rs"))
        );
        assert_eq!(
            subject(app, "tax.rs \u{2013} trailhead-shop"),
            code("trailhead-shop", Some("tax.rs"))
        );
        assert_eq!(subject(app, "Welcome to IntelliJ IDEA"), None);
    }
    assert_eq!(
        subject(
            "com.google.android.studio",
            "trailhead-app \u{2013} MainActivity.kt [trailhead-app.app.main]"
        ),
        code("trailhead-app", Some("MainActivity.kt"))
    );
}

#[test]
fn xcode_names_the_project_without_its_package() {
    assert_eq!(
        subject(XCODE, "trailhead-shop.xcodeproj \u{2014} tax.swift"),
        code("trailhead-shop", Some("tax.swift"))
    );
    assert_eq!(
        subject(XCODE, "trailhead-shop.xcworkspace \u{2014} Cart.swift"),
        code("trailhead-shop", Some("Cart.swift"))
    );
    assert_eq!(
        subject(XCODE, "trailhead-shop \u{2014} tax.swift"),
        code("trailhead-shop", Some("tax.swift"))
    );
    assert_eq!(subject(XCODE, "Welcome to Xcode"), None);
    assert_eq!(subject(XCODE, "Xcode"), None);
}

#[test]
fn terminals_name_a_project_only_through_a_folder() {
    for (app, title) in [
        (
            TERMINAL,
            "trailhead-shop \u{2014} -zsh \u{2014} 160\u{00d7}40",
        ),
        (
            TERMINAL,
            "trailhead-shop \u{2014} cargo \u{2014} 120\u{00d7}30",
        ),
        (TERMINAL, "trailhead-shop \u{2014} -zsh"),
        (ITERM, "dev@studio: ~/dev/trailhead-shop"),
        (ITERM, "~/dev/trailhead-shop (-zsh)"),
        (GHOSTTY, "~/dev/trailhead-shop"),
        (WARP, "~/dev/trailhead-shop"),
        ("net.kovidgoyal.kitty", "/Users/dev/trailhead-shop"),
    ] {
        assert_eq!(
            subject(app, title),
            code("trailhead-shop", None),
            "{app}: {title}"
        );
    }
    // A folder inside a project names its last part; the work read maps it
    // to the project when an editor uses that name.
    assert_eq!(
        subject(GHOSTTY, "~/dev/trailhead-shop/apps/web"),
        code("web", None)
    );
    let folder = terminal_folder("~/dev/trailhead-shop/apps/web").unwrap();
    assert_eq!(
        folder.path.as_deref(),
        Some("~/dev/trailhead-shop/apps/web")
    );
    assert!(folder.sure);
    // Commands, shells, the home folder and generic titles name nothing.
    for (app, title) in [
        (TERMINAL, "dev \u{2014} -zsh \u{2014} 80\u{00d7}24"),
        (TERMINAL, "Terminal"),
        (ITERM, "-zsh"),
        (ITERM, "zsh"),
        (ITERM, "dev@studio: ~"),
        (GHOSTTY, "cargo test tax"),
        (GHOSTTY, "~"),
        (GHOSTTY, "/"),
        (WARP, "bash"),
        (WARP, "fish"),
        (TERMINAL, "sh"),
        (GHOSTTY, "htop"),
        (WARP, "trailhead-shop"),
    ] {
        assert_eq!(subject(app, title), None, "{app}: {title}");
    }
    // A bare word is never sure: it counts only as a name an editor uses.
    let bare = terminal_folder("trailhead-shop").unwrap();
    assert!(!bare.sure);
    assert_eq!(bare.name, "trailhead-shop");
}

#[test]
fn an_ai_tools_own_terminal_title_names_nothing() {
    for title in [
        "\u{2733} Claude Code",
        "Claude Code",
        "claude",
        "codex",
        "\u{2733} Fix rounding in tax.rs \u{2014} claude \u{2014} 160\u{00d7}40",
        "\u{2810} Fix rounding in tax.rs \u{2014} claude \u{2014} 160\u{00d7}40",
        "trailhead-shop \u{2014} claude \u{2014} 160\u{00d7}40",
        "trailhead-shop \u{2014} codex \u{2014} 160\u{00d7}40",
        "~/dev/trailhead-shop (claude)",
    ] {
        for app in [TERMINAL, ITERM, GHOSTTY, WARP] {
            assert_eq!(subject(app, title), None, "{app}: {title}");
        }
        assert_eq!(
            terminal_folder(title).filter(|folder| folder.sure),
            None,
            "{title}"
        );
    }
}

#[test]
fn google_docs_sheets_and_slides_with_and_without_addresses() {
    for host in [None, Some("docs.google.com")] {
        let read = |title: &str| subject_of_at(Some(CHROME), Some(title), host, None, HOME);
        assert_eq!(
            read("Q4 planning - Google Docs"),
            named(SubjectKind::Document, "Q4 planning", None)
        );
        assert_eq!(
            read("Launch deck - Google Slides"),
            named(SubjectKind::Document, "Launch deck", None)
        );
        assert_eq!(
            read("October invoices - Google Sheets"),
            named(SubjectKind::Spreadsheet, "October invoices", None)
        );
        assert_eq!(read("Untitled document - Google Docs"), None);
        assert_eq!(read("Untitled spreadsheet - Google Sheets"), None);
    }
    assert_eq!(
        on(SAFARI, "Q4 planning", "docs.google.com"),
        named(SubjectKind::Document, "Q4 planning", None)
    );
    assert_eq!(on(SAFARI, "Google Docs", "docs.google.com"), None);
}

#[test]
fn figma_notion_and_canva_on_the_web_and_in_their_apps() {
    assert_eq!(
        subject("com.figma.Desktop", "Trailhead pricing v3 \u{2013} Figma"),
        named(SubjectKind::Design, "Trailhead pricing v3", None)
    );
    assert_eq!(
        subject("com.figma.Desktop", "Trailhead pricing v3"),
        named(SubjectKind::Design, "Trailhead pricing v3", None)
    );
    assert_eq!(
        on(CHROME, "Trailhead pricing v3 \u{2013} Figma", "figma.com"),
        named(SubjectKind::Design, "Trailhead pricing v3", None)
    );
    for title in ["Figma", "Drafts \u{2013} Figma", "Recents", "Home"] {
        assert_eq!(subject("com.figma.Desktop", title), None, "{title}");
    }
    assert_eq!(
        subject("notion.id", "Q4 planning"),
        named(SubjectKind::Document, "Q4 planning", None)
    );
    assert_eq!(
        on(CHROME, "Q4 planning", "notion.so"),
        named(SubjectKind::Document, "Q4 planning", None)
    );
    assert_eq!(
        on(CHROME, "Launch post - Canva", "canva.com"),
        named(SubjectKind::Design, "Launch post", None)
    );
    assert_eq!(
        subject("com.bohemiancoding.sketch3", "Pricing cards.sketch"),
        named(SubjectKind::Design, "Pricing cards", None)
    );
    assert_eq!(
        subject("com.adobe.Photoshop", "hero.psd @ 66.7% (RGB/8)"),
        named(SubjectKind::Design, "hero", None)
    );
}

#[test]
fn notes_takes_the_first_line_because_its_title_is_notes() {
    let notes = |first: &str| {
        subject_of_at(
            Some("com.apple.Notes"),
            Some("Notes"),
            None,
            Some(first),
            HOME,
        )
    };
    assert_eq!(
        notes("Launch checklist"),
        named(SubjectKind::Document, "Launch checklist", None)
    );
    assert_eq!(
        notes("Pricing page draft"),
        named(SubjectKind::Document, "Pricing page draft", None)
    );
    assert_eq!(
        notes("Three plans: Ride, Tour and Club."),
        None,
        "a sentence is no name"
    );
    assert_eq!(notes("New Note"), None);
    assert_eq!(notes(""), None);
    assert_eq!(
        subject_of(Some("com.apple.Notes"), Some("Notes"), None, None),
        None
    );
}

#[test]
fn pages_word_keynote_and_text_files_drop_their_extensions() {
    assert_eq!(
        subject("com.apple.iWork.Pages", "Q4 planning.pages"),
        named(SubjectKind::Document, "Q4 planning", None)
    );
    assert_eq!(
        subject("com.apple.iWork.Pages", "Q4 planning \u{2014} Edited"),
        named(SubjectKind::Document, "Q4 planning", None)
    );
    assert_eq!(
        subject("com.microsoft.Word", "Q4 planning.docx"),
        named(SubjectKind::Document, "Q4 planning", None)
    );
    assert_eq!(subject("com.microsoft.Word", "Document1"), None);
    assert_eq!(
        subject("com.apple.iWork.Keynote", "Launch deck.key"),
        named(SubjectKind::Document, "Launch deck", None)
    );
    assert_eq!(
        subject("com.microsoft.Powerpoint", "Launch deck.pptx"),
        named(SubjectKind::Document, "Launch deck", None)
    );
    assert_eq!(
        subject(
            "md.obsidian",
            "Launch checklist - Trailhead - Obsidian v1.6.7"
        ),
        named(SubjectKind::Document, "Launch checklist", None)
    );
    assert_eq!(subject("com.apple.TextEdit", "Untitled 2"), None);
    assert_eq!(
        subject("com.apple.TextEdit", "release-notes.txt"),
        named(SubjectKind::Document, "release-notes", None)
    );
}

#[test]
fn excel_and_numbers_are_spreadsheets() {
    assert_eq!(
        subject("com.microsoft.Excel", "October invoices.xlsx"),
        named(SubjectKind::Spreadsheet, "October invoices", None)
    );
    assert_eq!(
        subject("com.apple.iWork.Numbers", "October invoices"),
        named(SubjectKind::Spreadsheet, "October invoices", None)
    );
    assert_eq!(subject("com.microsoft.Excel", "Book1"), None);
}

#[test]
fn preview_and_pdf_readers_name_the_file() {
    for (app, title) in [
        ("com.apple.Preview", "contract.pdf \u{2014} Page 3 of 12"),
        ("com.apple.Preview", "contract.pdf (page 3 of 12)"),
        ("com.apple.Preview", "contract.pdf"),
        ("com.readdle.PDFExpert-Mac", "contract.pdf"),
        ("com.adobe.Acrobat.Pro", "contract.pdf - Adobe Acrobat Pro"),
    ] {
        assert_eq!(
            subject(app, title),
            named(SubjectKind::Document, "contract", None),
            "{app}: {title}"
        );
    }
}

#[test]
fn web_pages_are_pages_and_never_items() {
    let page = |title: &str, host: &str| on(CHROME, title, host);
    assert_eq!(
        page(
            "Rounding half to even \u{00b7} Dev Notes",
            "devnotes.example"
        ),
        named(SubjectKind::Page, "Rounding half to even", None)
    );
    assert_eq!(
        page(
            "Plans and pricing \u{00b7} Spoke & Chain",
            "spokeandchain.example"
        ),
        named(
            SubjectKind::Page,
            "Plans and pricing \u{00b7} Spoke & Chain",
            None
        ),
        "a short name keeps its site beside it"
    );
    assert_eq!(
        page("Pricing \u{00b7} Velo Cycles", "velocycles.example"),
        named(SubjectKind::Page, "Pricing \u{00b7} Velo Cycles", None)
    );
    assert_eq!(
        page(
            "Dev Notes \u{00b7} Rounding half to even",
            "devnotes.example"
        ),
        named(SubjectKind::Page, "Rounding half to even", None),
        "the site's own name first is left out"
    );
    assert_eq!(
        page("Rust lifetimes explained - YouTube", "youtube.com"),
        named(SubjectKind::Page, "Rust lifetimes explained", None)
    );
    // Without an address, a page is its title, and a web app's title
    // names nothing.
    assert_eq!(
        subject(SAFARI, "Per-seat or tiered? How to price a team plan"),
        named(
            SubjectKind::Page,
            "Per-seat or tiered? How to price a team plan",
            None
        )
    );
    for title in [
        "Inbox (3) - sam@trailhead.example - Gmail",
        "#launch - Northwind Studio - Slack",
        "Rounding modes for money - Claude",
        "Northwind - Calendar",
    ] {
        assert_eq!(subject(CHROME, title), None, "{title}");
    }
    assert!(!SubjectKind::Page.is_item());
    assert!(!SubjectKind::Search.is_item());
    assert!(SubjectKind::Code.is_item());
}

#[test]
fn mail_chat_calls_ai_chats_and_planning_tools_in_a_tab_are_not_pages() {
    for (title, host) in [
        (
            "Inbox (3) - sam@trailhead.example - Gmail",
            "mail.google.com",
        ),
        (
            "launch (Channel) - Northwind Studio - Slack",
            "app.slack.com",
        ),
        ("Rounding modes for money - Claude", "claude.ai"),
        ("ChatGPT", "chatgpt.com"),
        ("Meet - abc-defg-hij", "meet.google.com"),
        (
            "Northwind - Calendar - Week of October 12, 2026",
            "calendar.google.com",
        ),
        ("NW-412 Fix rounding", "linear.app"),
        ("localhost:3000", "localhost"),
        ("Trailhead dev", "localhost"),
    ] {
        assert_eq!(on(CHROME, title, host), None, "{title}");
    }
}

#[test]
fn search_result_pages_are_searches() {
    assert_eq!(
        on(
            CHROME,
            "per seat vs tiered pricing - Google Search",
            "google.com"
        ),
        named(SubjectKind::Search, "per seat vs tiered pricing", None)
    );
    assert_eq!(
        subject(SAFARI, "rust round half to even at DuckDuckGo"),
        named(SubjectKind::Search, "rust round half to even", None)
    );
    assert_eq!(on(CHROME, "Google", "google.com"), None);
    assert_eq!(on(CHROME, "New Tab", "google.com"), None);
}

#[test]
fn a_generic_title_names_nothing() {
    for title in [
        "Untitled",
        "Untitled document",
        "Untitled-1",
        "New Tab",
        "Start Page",
        "Welcome",
        "Get Started",
        "Inbox",
        "Home",
        "Dashboard",
        "Settings",
        "Preferences",
        "Downloads",
        "Desktop",
        "Documents",
        "zsh",
        "-zsh",
        "bash",
        "fish",
        "sh",
        "localhost",
        "Notes",
        "Q4",
        "ab",
        "~",
        "dev",
    ] {
        assert!(is_never_a_name(title), "{title}");
        for app in [
            SAFARI,
            "com.apple.iWork.Pages",
            "com.figma.Desktop",
            "com.microsoft.Excel",
            TERMINAL,
        ] {
            assert_eq!(subject(app, title), None, "{app}: {title}");
        }
        assert_eq!(
            subject(
                VS_CODE,
                &format!("tax.rs \u{2014} {title} \u{2014} Visual Studio Code")
            ),
            None
        );
    }
}

#[test]
fn hippocampus_and_system_surfaces_name_nothing() {
    for app in [
        "ai.hippocampus",
        "ai.hippocampus.recall",
        "recall-ui",
        "com.apple.loginwindow",
        "com.apple.dock",
    ] {
        assert_eq!(subject(app, "Launch checklist"), None, "{app}");
    }
    assert_eq!(
        subject("com.example.unknown", "Launch checklist"),
        None,
        "an unknown app is unsure"
    );
}

#[test]
fn a_secret_in_a_title_names_nothing() {
    assert_eq!(
        subject(
            "com.apple.iWork.Pages",
            "ghp_0123456789abcdefghijABCDEFGHIJ012345"
        ),
        None
    );
    assert_eq!(
        subject("com.apple.TextEdit", "token = 7c1f9e2d4b6a8c0e.txt"),
        None
    );
    assert_eq!(
        subject(
            VS_CODE,
            "tax.rs \u{2014} AKIAIOSFODNN7EXAMPLE \u{2014} Visual Studio Code"
        ),
        None
    );
}

#[test]
fn a_long_or_right_to_left_name_is_kept_as_written() {
    let long = "A very long document name that keeps going ".repeat(10);
    let found = subject("com.apple.iWork.Pages", &long).unwrap();
    assert_eq!(found.name.chars().count(), 200);
    let hebrew = subject(
        "com.apple.iWork.Pages",
        "\u{05EA}\u{05DB}\u{05E0}\u{05D5}\u{05DF} \u{05E8}\u{05D1}\u{05E2}\u{05D5}\u{05DF}",
    )
    .unwrap();
    assert_eq!(
        hebrew.name,
        "\u{05EA}\u{05DB}\u{05E0}\u{05D5}\u{05DF} \u{05E8}\u{05D1}\u{05E2}\u{05D5}\u{05DF}"
    );
}

#[test]
fn one_project_two_apps_one_identity() {
    let editor = subject(
        VS_CODE,
        "tax.rs \u{2014} trailhead-shop \u{2014} Visual Studio Code",
    )
    .unwrap();
    let terminal = subject(
        TERMINAL,
        "Trailhead-Shop \u{2014} -zsh \u{2014} 80\u{00d7}24",
    )
    .unwrap();
    assert_eq!(
        identity(editor.kind, &editor.name),
        identity(terminal.kind, &terminal.name)
    );
    assert_eq!(folded(" Q4   Planning "), "q4 planning");
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
        assert_eq!(serde_json::to_value(kind).unwrap(), kind.as_str());
    }
}

/// Every app the rules read, for the fuzz test.
const FUZZ_APPS: &[&str] = &[
    VS_CODE,
    CURSOR,
    ZED,
    XCODE,
    TERMINAL,
    ITERM,
    GHOSTTY,
    WARP,
    CHROME,
    SAFARI,
    "com.jetbrains.intellij",
    "com.apple.Notes",
    "com.apple.iWork.Pages",
    "com.microsoft.Word",
    "com.apple.Preview",
    "com.figma.Desktop",
    "com.microsoft.Excel",
    "com.apple.iWork.Numbers",
    "com.sublimetext.4",
    "md.obsidian",
];

/// Parts random titles are made of: real title parts, marks, shells, AI
/// tools, generic words and short scraps.
const FUZZ_WORDS: &[&str] = &[
    "tax.rs",
    "trailhead-shop",
    "\u{2014}",
    "-",
    "|",
    "\u{00b7}",
    "\u{2013}",
    "Untitled",
    "New",
    "Tab",
    "zsh",
    "-zsh",
    "160\u{00d7}40",
    "~",
    "/",
    "~/dev/x",
    "claude",
    "Codex",
    "\u{2733}",
    "Q4",
    "ab",
    "a",
    "Inbox",
    "Home",
    "Google",
    "Docs",
    "Figma",
    "Search",
    "[SSH:",
    "devbox]",
    "(",
    ")",
    "Visual",
    "Studio",
    "Code",
    "Notes",
    "x",
    "",
    " ",
    "\u{200b}",
    ".pdf",
    "Page 3 of 12",
    "@",
    "dev@studio:",
    "Document1",
    "Book1",
    "localhost",
    "planning",
    "\u{05EA}",
];

/// Random titles for every app the rules read: no name ever comes out
/// shorter than three letters or on the never list.
#[test]
fn no_random_title_gives_a_short_or_never_name() {
    // A small fixed generator, so a failure always reproduces.
    let mut state: u64 = 0x9e37_79b9_7f4a_7c15;
    let mut next = |bound: usize| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        usize::try_from(state % (bound as u64)).unwrap_or(0)
    };
    for _ in 0..20_000 {
        let count = 1 + next(7);
        let title = (0..count)
            .map(|_| FUZZ_WORDS[next(FUZZ_WORDS.len())])
            .collect::<Vec<_>>()
            .join(" ");
        let app = FUZZ_APPS[next(FUZZ_APPS.len())];
        let host = [
            "",
            "docs.google.com",
            "figma.com",
            "devnotes.example",
            "google.com",
        ][next(5)];
        let first = ["", "Launch checklist", "ab", "New Note"][next(4)];
        let found = subject_of_at(
            Some(app),
            Some(&title),
            (!host.is_empty()).then_some(host),
            (!first.is_empty()).then_some(first),
            HOME,
        );
        if let Some(found) = found {
            let letters = found.name.chars().filter(|ch| ch.is_alphanumeric()).count();
            assert!(
                letters >= MIN_NAME_CHARS,
                "{app}: {title:?} gave {:?}",
                found.name
            );
            assert!(
                !is_never_a_name(&found.name),
                "{app}: {title:?} gave {:?}",
                found.name
            );
            let lower = found.name.to_lowercase();
            assert!(
                !["claude", "codex", "claude code"].contains(&lower.trim()),
                "{app}: {title:?} gave an AI tool's own title"
            );
        }
    }
}

#[test]
fn conversations_are_named_and_nothing_more() {
    use mci_brain::subject::conversation_of;
    let name =
        |app: &str, title: &str, host: Option<&str>| conversation_of(Some(app), Some(title), host);
    let slack = "com.tinyspeck.slackmacgap";
    assert_eq!(
        name(slack, "launch (Channel) - Northwind Studio - Slack", None).as_deref(),
        Some("#launch")
    );
    assert_eq!(
        name(slack, "Jordan Lee (DM) - Northwind Studio - Slack", None).as_deref(),
        Some("Jordan Lee")
    );
    assert_eq!(
        name(slack, "qa (Channel) - Northwind Studio - Slack", None).as_deref(),
        Some("#qa")
    );
    assert_eq!(
        name(slack, "Threads - Northwind Studio - Slack", None),
        None
    );
    assert_eq!(
        name(
            CHROME,
            "launch (Channel) - Northwind Studio - Slack",
            Some("app.slack.com")
        )
        .as_deref(),
        Some("#launch")
    );
    assert_eq!(
        name("com.apple.MobileSMS", "Sam Lee", None).as_deref(),
        Some("Sam Lee")
    );
    assert_eq!(name("com.apple.MobileSMS", "Messages", None), None);
    assert_eq!(
        name(
            "com.apple.mail",
            "Re: Invoice 1042 from Northwind Supplies",
            None
        )
        .as_deref(),
        Some("Invoice 1042 from Northwind Supplies")
    );
    assert_eq!(name("com.apple.mail", "Inbox (12)", None), None);
    assert_eq!(
        name(
            CHROME,
            "Invoice 1042 - sam@trailhead.example - Gmail",
            Some("mail.google.com")
        )
        .as_deref(),
        Some("Invoice 1042")
    );
    assert_eq!(
        name(
            CHROME,
            "Inbox (3) - sam@trailhead.example - Gmail",
            Some("mail.google.com")
        ),
        None
    );
    assert_eq!(
        name(
            "com.microsoft.teams2",
            "Chat | Sam Lee | Microsoft Teams",
            None
        )
        .as_deref(),
        Some("Sam Lee")
    );
    assert_eq!(
        name(
            VS_CODE,
            "tax.rs \u{2014} trailhead-shop \u{2014} Visual Studio Code",
            None
        ),
        None
    );
}

/// The folder guess reads only the file paths moments showed (Tier 1's
/// `file_path` entities), counted by moment, most shown first.
#[test]
fn file_paths_seen_are_counted_by_moment() {
    use mci_brain::graph::{Entity, EntityMention};
    use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};
    use mci_core::crypto::DbKey;

    let dir = tempfile::tempdir().unwrap();
    let store =
        SqlCipherBrainStore::new(&dir.path().join("mci.sqlite"), &DbKey::from_bytes([7; 32]))
            .unwrap();
    let event = |ts_us: u64| Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some(TERMINAL.to_owned()),
        window_title: Some("trailhead-shop \u{2014} -zsh \u{2014} 80\u{00d7}24".to_owned()),
        url: None,
        text: "cargo test".into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    };
    let ids: Vec<EventId> = (1..=3)
        .map(|n| store.put_event(&event(1_760_000_000_000_000 + n)).unwrap())
        .collect();
    let entity = |kind: &str, name: &str| Entity {
        id: Entity::derive_id(kind, name),
        kind: kind.to_owned(),
        canonical_name: name.to_owned(),
        summary: None,
        summary_embedding: None,
        content_hash: Entity::derive_content_hash(kind, name),
        created_ts_us: 1,
        updated_ts_us: 1,
    };
    let src = entity("file_path", "/Users/dev/trailhead-shop/src/tax.rs");
    let cargo = entity("file_path", "/Users/dev/trailhead-shop/Cargo.toml");
    let site = entity("url", "https://devnotes.example/rounding");
    for item in [&src, &cargo, &site] {
        store.put_entity(item).unwrap();
    }
    let mention = |entity: &Entity, event: EventId| EntityMention {
        id: EntityMention::derive_id(&entity.id, event, "regex", None),
        entity_id: entity.id.clone(),
        event_id: event,
        mention_text: None,
        confidence: 1.0,
        extractor_kind: "regex".into(),
        ts_us: 1,
    };
    for (item, event) in [
        (&src, ids[0]),
        (&src, ids[1]),
        (&cargo, ids[2]),
        (&site, ids[0]),
    ] {
        store.put_entity_mention(&mention(item, event)).unwrap();
    }
    let raw: Vec<i64> = ids.iter().map(|id| i64::try_from(id.0).unwrap()).collect();
    let paths = store.file_paths_seen(&raw, 10).unwrap();
    assert_eq!(
        paths,
        vec![
            ("/Users/dev/trailhead-shop/src/tax.rs".to_owned(), 2),
            ("/Users/dev/trailhead-shop/Cargo.toml".to_owned(), 1),
        ],
        "only file paths, never a page's address"
    );
    assert_eq!(store.file_paths_seen(&raw[..1], 10).unwrap().len(), 1);
    assert!(store.file_paths_seen(&[], 10).unwrap().is_empty());
    assert_eq!(store.file_paths_seen(&raw, 1).unwrap().len(), 1);
}
