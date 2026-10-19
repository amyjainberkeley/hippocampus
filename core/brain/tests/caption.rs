//! Captions (`mci_brain::caption`): one short plain line per moment, grounded
//! in the moment's own title, address and text, never about the person.
//! Every moment here is made up.

use mci_brain::caption::{
    about_the_person, accept, fallback, in_a_call, is_grounded, is_sensitive, Moment, MAX_CHARS,
};

fn moment<'a>(app: &'a str, title: &'a str, url: Option<&'a str>, text: &'a str) -> Moment<'a> {
    Moment {
        app: Some(app),
        title: Some(title),
        url,
        text,
        beside: false,
    }
}

fn beside<'a>(app: &'a str, title: &'a str, url: Option<&'a str>) -> Moment<'a> {
    Moment {
        beside: true,
        ..moment(app, title, url, "")
    }
}

const CHROME: &str = "com.google.Chrome";
const SLACK: &str = "com.tinyspeck.slackmacgap";

// ---------------------------------------------------------------------------
// Without a model
// ---------------------------------------------------------------------------

#[test]
#[allow(clippy::too_many_lines)] // one table of windows and their captions
fn fallbacks_say_what_the_window_was_in_plain_words() {
    let cases: Vec<(Moment<'_>, &str)> = vec![
        (
            moment(
                CHROME,
                "how to type accents on mac - Google Search",
                Some("https://www.google.com/search?q=how+to+type+accents+on+mac&oq=how"),
                "",
            ),
            "Looking up how to type accents on mac",
        ),
        (
            moment(
                CHROME,
                "How to type accents on a Mac - Google Search",
                None,
                "",
            ),
            "Looking up how to type accents on a Mac",
        ),
        (
            moment(
                CHROME,
                "How to type accents on a Mac - Apple Support",
                Some("https://support.example/type-accents"),
                "Press and hold a letter key",
            ),
            "Reading how to type accents on a Mac",
        ),
        (
            moment(
                "com.microsoft.VSCode",
                "\u{25cf} tax.rs \u{2014} trailhead-shop",
                None,
                "fn main() {}",
            ),
            "Working on tax.rs in trailhead-shop",
        ),
        (
            moment(
                "com.tinyspeck.slackmacgap",
                "launch-plan (Channel) - Northwind Studio - Slack",
                None,
                "",
            ),
            "Chatting in #launch-plan",
        ),
        (
            moment(
                "com.tinyspeck.slackmacgap",
                "Maya Chen (DM) - Northwind Studio - Slack",
                None,
                "",
            ),
            "Chatting with Maya Chen",
        ),
        (
            moment("com.figma.Desktop", "Checkout redesign", None, ""),
            "Designing \u{201c}Checkout redesign\u{201d}",
        ),
        (
            moment(
                CHROME,
                "Google Calendar - Week of October 12, 2026",
                Some("https://calendar.google.com/calendar/u/0/r/week"),
                "",
            ),
            "Checking the calendar",
        ),
        (
            moment(
                "com.anthropic.claudefordesktop",
                "Checkout redesign ideas",
                None,
                "",
            ),
            "Asking Claude about \u{201c}Checkout redesign ideas\u{201d}",
        ),
        (
            moment(
                CHROME,
                "New chat - Claude",
                Some("https://claude.ai/new"),
                "",
            ),
            "Using Claude",
        ),
        (
            moment(
                CHROME,
                "General user models, explained - YouTube",
                Some("https://www.youtube.com/watch?v=x"),
                "",
            ),
            "Watching \u{201c}General user models, explained\u{201d}",
        ),
        (
            moment(
                "com.apple.Terminal",
                "sam@studio: ~/trailhead-shop \u{2014} zsh",
                None,
                "$ ls",
            ),
            "Working in Terminal",
        ),
        (
            moment("com.apple.mail", "Invoice 4471 for phase two", None, ""),
            "Reading the email \u{201c}Invoice 4471 for phase two\u{201d}",
        ),
        (
            moment(
                CHROME,
                "(3) Inbox - dana@example.com - Gmail",
                Some("https://mail.google.com/mail/u/0/"),
                "",
            ),
            "Going through email",
        ),
        (
            moment(
                CHROME,
                "Rounding half to even \u{00b7} Dev Notes",
                Some("https://devnotes.example/rounding"),
                "",
            ),
            "Reading \u{201c}Rounding half to even\u{201d}",
        ),
        (
            moment(
                CHROME,
                "Q4 planning - Google Docs",
                Some("https://docs.google.com/document/d/q4-planning/edit"),
                "",
            ),
            "Working on \u{201c}Q4 planning\u{201d}",
        ),
        (
            moment("com.apple.Notes", "Launch checklist", None, ""),
            "Working on \u{201c}Launch checklist\u{201d}",
        ),
        (
            moment("com.apple.MobileSMS", "Sam Lee", None, ""),
            "Messaging Sam Lee",
        ),
    ];
    for (moment, want) in cases {
        let got = fallback(&moment);
        assert_eq!(got.as_deref(), Some(want), "{moment:?}");
        assert!(
            is_grounded(want, &moment),
            "{want} is grounded in {moment:?}"
        );
    }
}

#[test]
fn an_app_known_only_by_its_bundle_id_gets_no_guess_at_its_name() {
    // The title is the row's headline already; "in Widgetmaker" would be a
    // name made up from the bundle id.
    assert_eq!(
        fallback(&moment("com.example.widgetmaker", "Q3 plan", None, "")),
        None
    );
}

#[test]
#[allow(clippy::too_many_lines)] // one table of windows and their captions
fn everyday_windows_get_plain_captions() {
    let cases: Vec<(Moment<'_>, &str)> = vec![
        // Status marks a coding assistant puts in a terminal's title.
        (
            moment(
                "com.apple.Terminal",
                "\u{2733} Fix rounding in tax.rs \u{2014} claude \u{2014} 160\u{d7}40",
                None,
                "",
            ),
            "Working in Terminal: Fix rounding in tax.rs",
        ),
        (
            moment(
                "com.apple.Terminal",
                "\u{2810} Fix rounding in tax.rs",
                None,
                "",
            ),
            "Working in Terminal: Fix rounding in tax.rs",
        ),
        // A title that only names the app.
        (
            moment("com.apple.MobileSMS", "Messages", None, ""),
            "Using Messages",
        ),
        (
            moment(
                "com.apple.Notes",
                "Notes",
                None,
                "Launch checklist\nBeta group told about 0.4",
            ),
            "Working on \u{201c}Launch checklist\u{201d}",
        ),
        (moment("com.apple.Notes", "Notes", None, ""), "Using Notes"),
        (
            moment("com.apple.calculator", "Calculator", None, ""),
            "Using Calculator",
        ),
        (
            moment("com.figma.Desktop", "Figma", None, ""),
            "Using Figma",
        ),
        (
            moment("com.apple.reminders", "Reminders", None, ""),
            "Using Reminders",
        ),
        (
            moment("net.whatsapp.WhatsApp", "WhatsApp", None, ""),
            "Using WhatsApp",
        ),
        (
            moment("com.apple.AppStore", "App Store", None, ""),
            "Using App Store",
        ),
        (
            moment(
                "com.apple.ActivityMonitor",
                "Activity Monitor (All Processes)",
                None,
                "",
            ),
            "Using Activity Monitor",
        ),
        // Blank pages.
        (
            moment("com.google.Chrome", "New Tab", None, ""),
            "Browsing in Chrome",
        ),
        (
            moment("com.apple.Safari", "Start Page", None, ""),
            "Browsing in Safari",
        ),
        (
            moment(
                "com.google.Chrome",
                "YouTube",
                Some("https://www.youtube.com/"),
                "",
            ),
            "Browsing in Chrome",
        ),
        // The app's own name, never one made from its bundle id.
        (
            moment("com.apple.systempreferences", "Wi-Fi", None, ""),
            "Wi-Fi in System Settings",
        ),
    ];
    for (moment, want) in cases {
        assert_eq!(fallback(&moment).as_deref(), Some(want), "{moment:?}");
    }
}

#[test]
#[allow(clippy::too_many_lines)] // one table of windows and their captions
fn captions_do_not_guess() {
    let zoom = "us.zoom.xos";
    let cases: Vec<(Moment<'_>, &str)> = vec![
        (moment(zoom, "Zoom Workplace", None, ""), "Using Zoom"),
        (moment(zoom, "Zoom Meeting", None, ""), "On a call in Zoom"),
        (
            moment("com.microsoft.teams2", "Chat | Sam Lee | Microsoft Teams", None, ""),
            "Chatting with Sam Lee",
        ),
        (moment("com.apple.FaceTime", "FaceTime", None, ""), "Using FaceTime"),
        (
            moment(
                CHROME,
                "Google Meet",
                Some("https://meet.google.com/landing"),
                "",
            ),
            "Using Google Meet",
        ),
        (
            moment(
                CHROME,
                "Meet - abc-defg-hij",
                Some("https://meet.google.com/abc-defg-hij"),
                "",
            ),
            "On a call in Google Meet",
        ),
        (
            moment("com.linear", "NW-412 Fix rounding in checkout", None, ""),
            "Working on \u{201c}Fix rounding in checkout\u{201d}",
        ),
        // A title in title case is a name, not a question.
        (
            moment(CHROME, "How We Built Our Pricing Page - Northwind Blog", None, ""),
            "Reading \u{201c}How We Built Our Pricing Page\u{201d}",
        ),
        (
            moment(CHROME, "Do Not Disturb settings explained", None, ""),
            "Reading \u{201c}Do Not Disturb settings explained\u{201d}",
        ),
        (
            moment(CHROME, "Who We Are - Northwind", None, ""),
            "Reading \u{201c}Who We Are\u{201d}",
        ),
        // Mail: no reply marks, the subject quoted, no mailbox read as one.
        (
            moment("com.apple.mail", "Fwd: Re: Launch plan", None, ""),
            "Reading the email \u{201c}Launch plan\u{201d}",
        ),
        (moment("com.apple.mail", "All Inboxes", None, ""), "Going through email"),
        (moment("com.apple.mail", "Sent", None, ""), "Going through email"),
        // GitHub's pull requests.
        (
            moment(
                CHROME,
                "Round half to even in order_total by sam-lee \u{b7} Pull Request #42 \u{b7} northwind/trailhead-shop",
                Some("https://github.com/northwind/trailhead-shop/pull/42"),
                "",
            ),
            "Reviewing \u{201c}Round half to even in order_total\u{201d} in trailhead-shop",
        ),
        // Slack's views that are not one channel or person.
        (
            moment(SLACK, "Threads - Northwind Studio - Slack", None, ""),
            "Using Slack",
        ),
        (
            moment(SLACK, "Inbox (3) - Northwind Studio - Slack", None, ""),
            "Using Slack",
        ),
        (
            moment(SLACK, "Huddle in launch - Northwind Studio - Slack", None, ""),
            "On a call in Slack",
        ),
    ];
    for (moment, want) in cases {
        assert_eq!(fallback(&moment).as_deref(), Some(want), "{moment:?}");
    }
}

#[test]
fn a_window_beside_the_one_in_use_is_named_where_it_was_open() {
    let cases: Vec<(Moment<'_>, &str)> = vec![
        (
            beside(SLACK, "launch (Channel) - Northwind Studio - Slack", None),
            "#launch, open in Slack",
        ),
        (
            beside(SLACK, "Sam Lee (DM) - Northwind Studio - Slack", None),
            "Sam Lee, open in Slack",
        ),
        (
            beside("com.figma.Desktop", "Pricing page", None),
            "\u{201c}Pricing page\u{201d}, open in Figma",
        ),
        (
            beside(
                CHROME,
                "per seat vs tiered pricing - Google Search",
                Some("https://www.google.com/search?q=per+seat+vs+tiered+pricing"),
            ),
            "\u{201c}per seat vs tiered pricing\u{201d}, open in Chrome",
        ),
    ];
    for (moment, want) in cases {
        let got = fallback(&moment);
        assert_eq!(got.as_deref(), Some(want), "{moment:?}");
        for verb in [
            "Chatting",
            "Designing",
            "Looking up",
            "Working on",
            "Reading",
            "Watching",
            "On a call",
            "Messaging",
        ] {
            assert!(!want.contains(verb), "{want}");
        }
    }
    // Nothing to name: no caption, and the row shows the window's name.
    assert_eq!(fallback(&beside("com.figma.Desktop", "Figma", None)), None);
    assert_eq!(
        fallback(&beside("com.example.widgetmaker", "Q3 plan", None)),
        None
    );
    // A model's line about such a window is never used.
    let mut page = beside("com.figma.Desktop", "Pricing page", None);
    page.text = "Hero section with three columns";
    assert_eq!(accept("Designing the hero section", &page), None);
}

#[test]
fn surfaces_that_are_not_work_get_no_caption() {
    for app in [
        "com.apple.loginwindow",
        "com.apple.screensaver",
        "ai.hippocampus",
        "",
    ] {
        assert_eq!(
            fallback(&moment(app, "Anything", None, "")),
            None,
            "{app:?}"
        );
    }
}

#[test]
fn a_long_title_is_cut_between_words() {
    let title = "A very long page title that keeps going well past the length any list row could ever show in full";
    let caption = fallback(&moment(CHROME, title, None, "")).unwrap();
    assert!(caption.chars().count() <= MAX_CHARS, "{caption}");
    assert!(
        caption.ends_with("\u{2026}\u{201d}"),
        "the name is cut short inside its quotes: {caption}"
    );
    assert!(
        caption.starts_with("Reading \u{201c}A very long page title"),
        "{caption}"
    );
    // A row shows a caption on one line: the name is cut short inside its
    // quotes, well before the caption's own limit.
    assert!(caption.chars().count() <= 52, "{caption}");
}

#[test]
fn a_fallback_never_shows_a_secret() {
    let caption = fallback(&moment(
        CHROME,
        "api_key=sk-test-123456 - Settings",
        None,
        "",
    ));
    assert_eq!(caption, None);
}

// ---------------------------------------------------------------------------
// A model's line
// ---------------------------------------------------------------------------

const TAB_STRIP_PAGE: &str =
    "Checkout redesign notes\nHero section with three columns\nPricing table below the fold";

#[test]
fn a_grounded_line_is_shown() {
    let page = moment(CHROME, "Checkout redesign", None, TAB_STRIP_PAGE);
    assert_eq!(
        accept("Planning the hero section and pricing table", &page).as_deref(),
        Some("Planning the hero section and pricing table")
    );
    let accents = moment(
        CHROME,
        "How to type accents on a Mac",
        None,
        "Choose an accent from the menu.",
    );
    assert_eq!(
        accept("Choosing an accent from the menu", &accents).as_deref(),
        Some("Choosing an accent from the menu")
    );
    assert_eq!(
        accept("  \"reviewing the hero section.\"  ", &page).as_deref(),
        Some("Reviewing the hero section"),
        "quotes, the final period and spaces go; it starts with a capital"
    );
    assert_eq!(
        accept("\nComparing pricing table columns\nSecond line", &page).as_deref(),
        Some("Comparing pricing table columns"),
        "only the first line"
    );
}

#[test]
fn a_line_with_a_word_the_moment_never_showed_is_not_used() {
    let page = moment(CHROME, "Checkout redesign", None, TAB_STRIP_PAGE);
    for invented in [
        "Planning a birthday party",
        "Designing a logo for Northwind",
        "Reading about Berlin",
        "Reviewing Q4 numbers",
    ] {
        assert_eq!(accept(invented, &page), None, "{invented}");
    }
    let q3 = moment("com.apple.Numbers", "Q3 numbers", None, "Revenue by month");
    assert_eq!(
        accept("Reviewing Q3 revenue by month", &q3).as_deref(),
        Some("Reviewing Q3 revenue by month")
    );
}

#[test]
fn a_line_that_names_nothing_the_title_does_not_leaves_the_title_caption() {
    let doc = moment(
        CHROME,
        "Q4 planning - Google Docs",
        Some("https://docs.google.com/document/d/q4-planning/edit"),
        "Goals\nShip the rounding fix before the holiday sale\nSome notes on the plan",
    );
    for vague in [
        "Reading a document",
        "Working on a doc",
        "Checking some notes",
        "Looking at a page",
        "Editing the document",
        "Reviewing Q4 planning",
    ] {
        assert_eq!(accept(vague, &doc), None, "{vague}");
    }
    assert_eq!(
        accept("Planning Q4 goals for the holiday sale", &doc).as_deref(),
        Some("Planning Q4 goals for the holiday sale")
    );
    // The title says it as well: "Reading how to type accents on a Mac".
    let accents = moment(
        CHROME,
        "How to type accents on a Mac",
        None,
        "Choose an accent from the menu.",
    );
    assert_eq!(accept("Looking up how to type accents", &accents), None);
}

#[test]
fn a_call_is_named_only_in_a_calls_own_window() {
    let home = moment(
        "us.zoom.xos",
        "Zoom Workplace",
        None,
        "Join\nNew meeting\nSchedule",
    );
    assert!(!in_a_call(&home));
    for line in [
        "Joining a call",
        "Running a meeting",
        "Starting a new meeting",
    ] {
        assert_eq!(accept(line, &home), None, "{line}");
    }
    let call = moment(
        "us.zoom.xos",
        "Zoom Meeting",
        None,
        "Pricing review\nMaya Chen is sharing the pricing sheet",
    );
    assert!(in_a_call(&call));
    assert_eq!(
        accept("Reviewing the pricing sheet in a call", &call).as_deref(),
        Some("Reviewing the pricing sheet in a call")
    );
}

/// Lines that guess about the person's work, health, money, relationships
/// or who they are, each on a moment that shows every word of it.
const GUESSES_ABOUT_THE_PERSON: [(&str, &str); 10] = [
    (
        "Preparing for the Acme onsite interview",
        "Acme onsite interview\nPreparing for the onsite: four rounds",
    ),
    (
        "Applying for the Senior Engineer role at Acme",
        "Senior Engineer role at Acme\nApplying for this role takes ten minutes",
    ),
    (
        "Reviewing HIV test results in MyChart",
        "MyChart\nHIV test results\nReviewing your results",
    ),
    (
        "Refilling the sertraline prescription",
        "Pharmacy\nRefilling the sertraline prescription",
    ),
    (
        "Checking the overdraft fee and past due payment",
        "Checking account\nOverdraft fee\nPast due payment",
    ),
    (
        "Planning anniversary dinner with Sam Lee",
        "Anniversary dinner\nPlanning with Sam Lee",
    ),
    (
        "Reading the bisexual coming out guide",
        "The bisexual coming out guide\nReading time 8 minutes",
    ),
    (
        "Checking the green card case status",
        "Green card case status\nChecking your case",
    ),
    // Near misses: one word each.
    (
        "Booking the anniversary trip",
        "Anniversary trip\nBooking for two",
    ),
    (
        "Reading about overdraft rules",
        "Overdraft rules explained\nReading list",
    ),
];

#[test]
fn a_line_that_guesses_about_the_persons_life_is_never_used() {
    for (line, text) in GUESSES_ABOUT_THE_PERSON {
        let title = text.lines().next().unwrap();
        let page = moment(CHROME, title, None, text);
        assert!(is_grounded(line, &page), "every word is on screen: {line}");
        assert!(about_the_person(line), "{line}");
        assert_eq!(accept(line, &page), None, "{line}");
        // Nor is any line about such a moment: the model is not asked.
        assert!(is_sensitive(&page), "{text}");
        assert_eq!(accept("Reading the page", &page), None, "{line}");
    }
}

#[test]
fn a_line_about_the_person_is_never_used() {
    let jobs = moment(
        CHROME,
        "Jobs at Northwind",
        None,
        "Open jobs: designer, engineer. Apply now.",
    );
    let health = moment(
        CHROME,
        "Anxiety - Health guide",
        None,
        "Anxiety symptoms and stress",
    );
    let money = moment(CHROME, "Loan calculator", None, "Mortgage and loan rates");
    let people = moment(
        "com.apple.MobileSMS",
        "Sam Lee",
        None,
        "dating app profile tips for your boyfriend",
    );
    for (line, moment) in [
        ("Looking for a new job", &jobs),
        ("Browsing open jobs at Northwind", &jobs),
        ("Reading about anxiety symptoms", &health),
        ("Feeling stressed", &health),
        ("Comparing loan rates", &money),
        ("Your mortgage options", &money),
        ("Reading dating profile tips", &people),
        ("You are reading about accents", &people),
        ("She is checking messages", &people),
    ] {
        assert_eq!(accept(line, moment), None, "{line}");
    }
    assert!(about_the_person("Your plan"));
    assert!(
        !about_the_person("Sketching an illustration"),
        "ill only as a word"
    );
    assert!(
        !about_the_person("Tuning visual layout"),
        "visa only as a word"
    );
    assert!(
        !about_the_person("Fixing the broken build"),
        "broke only as a word"
    );
}

#[test]
fn a_line_too_short_or_too_long_is_not_used() {
    let page = moment(CHROME, "Checkout redesign", None, TAB_STRIP_PAGE);
    assert_eq!(accept("Planning", &page), None);
    assert_eq!(
        accept("Planning the checkout redesign with the hero section and the pricing table below the fold", &page),
        None
    );
    assert_eq!(accept("", &page), None);
}

#[test]
fn a_line_that_holds_a_secret_is_not_used() {
    let page = moment(
        CHROME,
        "Settings",
        None,
        "Copy the token: abc123 from settings",
    );
    assert_eq!(accept("Copying token: abc123", &page), None);
}
