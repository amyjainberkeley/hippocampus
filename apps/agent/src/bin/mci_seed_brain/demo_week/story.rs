//! Who, what and when: the week's windows and days.
//!
//! Every name here is made up: Pebblewick and its studios, Ren Alder and the
//! team, Harbor Lane Ventures and Tallgrass Capital and their partners, and
//! the sites ending in `.example`. Stripe, Google Docs and Sheets, Slack,
//! Zoom, Figma, Notion, Claude, VS Code and Terminal appear only as the apps
//! and sites in use.

use serde_json::{json, Value};

use mci_brain::understanding::PropositionKind;

use super::{
    day_start, CalendarEvent, Claim, DayStory, Hold, Local, Note, Screen, Session, Win, World, MIN,
};

const CHROME: &str = "com.google.Chrome";
const SLACK: &str = "com.tinyspeck.slackmacgap";
const CODE: &str = "com.microsoft.VSCode";
const TERMINAL: &str = "com.apple.Terminal";
const ZOOM: &str = "us.zoom.xos";
const NOTION: &str = "notion.id";
const FIGMA: &str = "com.figma.Desktop";
const CALENDAR: &str = "com.apple.iCal";

/// The person whose Mac this is.
pub const FOUNDER: &str = "Ren Alder";
const IRIS: &str = "Iris Lindgren";
const THEO: &str = "Theo Brandt";
const NADIA: &str = "Nadia Rahim";
const MALIK: &str = "Malik Osei";
const JOY: &str = "Joy Tran";
const MIRA: &str = "Mira Castell";
const OWEN: &str = "Owen Pryce";

/// Every person's name in the week, for tests: none is a real person's.
#[cfg(test)]
pub const PEOPLE: [&str; 8] = [FOUNDER, IRIS, THEO, NADIA, MALIK, JOY, MIRA, OWEN];

const PROJECT: &str = "pebblewick-app";
/// The project's folder, as Terminal's title shows it (Terminal set to show
/// the path): an empty folder Demo Memory makes inside its own folder
/// ([`super::make_project_folder`]), so Resume finds a folder to reopen,
/// and it goes when the week does. `~` is whoever's Mac this is.
pub const PROJECT_FOLDER: &str =
    "~/Library/Application Support/Hippocampus/Demo Memory/pebblewick-app";
/// The same folder as the made-up founder's tools print it.
pub const PROJECT_PATH: &str =
    "/Users/ren/Library/Application Support/Hippocampus/Demo Memory/pebblewick-app";
const PROMPT: &str = "ren@studio pebblewick-app % ";
const Q4_DOC: &str = "https://docs.google.com/document/d/1pW4q-investor-update-oct/edit";
const BUDGET_SHEET: &str = "https://docs.google.com/spreadsheets/d/1pW27-budget-plan/edit";

/// A paragraph-level piece of a page: `h1`, `h2`, `p`, `li` or `code`.
type Block = (&'static str, String);

fn blocks_text(blocks: &[Block]) -> String {
    blocks
        .iter()
        .map(|(kind, text)| match *kind {
            "li" => format!("\u{2022} {text}"),
            _ => text.clone(),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn blocks_json(blocks: &[Block]) -> Value {
    Value::Array(
        blocks
            .iter()
            .map(|(kind, text)| json!([kind, text]))
            .collect(),
    )
}

fn p(text: &str) -> Block {
    ("p", text.to_owned())
}

fn h1(text: &str) -> Block {
    ("h1", text.to_owned())
}

fn h2(text: &str) -> Block {
    ("h2", text.to_owned())
}

fn li(text: &str) -> Block {
    ("li", text.to_owned())
}

fn code(text: &str) -> Block {
    ("code", text.to_owned())
}

/// Builds one session, hold by hold, each window made knowing when it was
/// first shown.
struct Builder {
    start_us: u64,
    at: u64,
    holds: Vec<Hold>,
}

impl Builder {
    fn hold(mut self, minutes: u64, make: impl FnOnce(u64) -> Win) -> Self {
        let win = make(self.at);
        self.holds.push(Hold { win, minutes });
        self.at += minutes * MIN;
        self
    }

    fn note(self, title: &str, surface: &str, beneath: &str) -> Session {
        Session {
            start_us: self.start_us,
            holds: self.holds,
            note: Some(Note {
                title: title.into(),
                surface: surface.into(),
                beneath: beneath.into(),
            }),
        }
    }
}

/// The week's clock, and every window it shows.
pub struct Story {
    now_us: u64,
    tz: i32,
}

impl Story {
    fn local(&self, ts_us: u64) -> Local {
        Local::of(ts_us, self.tz)
    }

    /// `hh:mm` on the day `back` days before today.
    fn at(&self, back: u64, hour: u64, minute: u64) -> u64 {
        day_start(self.now_us, self.tz, back) + (hour * 60 + minute) * MIN
    }

    fn session(&self, back: u64, hour: u64, minute: u64) -> Builder {
        let start_us = self.at(back, hour, minute);
        Builder {
            start_us,
            at: start_us,
            holds: Vec::new(),
        }
    }

    // -- Chrome ------------------------------------------------------------

    fn chrome_tabs(active: &str) -> Vec<String> {
        let others = [
            "Q4 investor update - Google Docs",
            "2027 budget - Google Sheets",
            "Product catalog \u{2013} Stripe",
            "Prorations | Stripe Documentation",
        ];
        std::iter::once(active.to_owned())
            .chain(
                others
                    .iter()
                    .filter(|t| **t != active)
                    .map(|t| (*t).to_owned()),
            )
            .take(4)
            .collect()
    }

    fn page(
        title: &str,
        url: &str,
        main: String,
        caption: &str,
        screen_id: &str,
        meta: Value,
    ) -> Win {
        let tabs = Self::chrome_tabs(title);
        let address = url
            .trim_start_matches("https://")
            .trim_start_matches("www.")
            .to_owned();
        let mut meta = meta;
        if let Some(object) = meta.as_object_mut() {
            object.insert("tabs".into(), json!(tabs));
            object.insert("active_tab".into(), json!(0));
            object.insert("address".into(), json!(address));
        }
        Win {
            app: CHROME,
            title: title.to_owned(),
            url: Some(url.to_owned()),
            main,
            rest: format!("{}\n{address}", tabs.join("\n")),
            caption: caption.to_owned(),
            screen: Some(Screen {
                id: screen_id.to_owned(),
                template: "browser",
                meta,
            }),
        }
    }

    fn stripe_nav() -> Value {
        json!([
            "Home",
            "Balances",
            "Transactions",
            "Customers",
            "Product catalog",
            "Billing",
            "Reporting",
            "Connect",
            "Developers"
        ])
    }

    fn stripe_payments(&self, at: u64) -> Win {
        let yesterday = self.local(at.saturating_sub(super::DAY));
        let day = yesterday.short_date();
        let shown = self.local(at).date_string();
        let rows = [
            ["$49.00", "Succeeded", "Juniper Yoga", "Studio plan"],
            ["$19.00", "Succeeded", "Kiln & Co. Pottery", "Starter plan"],
            ["$99.00", "Succeeded", "Fernhill Pilates", "Pro plan"],
            ["$60.00", "Succeeded", "Harbor Barre", "Class pack"],
            ["$49.00", "Refunded", "Northline Climbing", "Studio plan"],
            ["$19.00", "Succeeded", "Willow Room Yoga", "Starter plan"],
        ];
        let mut lines = vec!["Payments".to_owned(), format!("{day}  All payments")];
        lines.extend(rows.iter().map(|row| row.join("  ")));
        Self::page(
            "Payments \u{2013} Stripe",
            "https://dashboard.stripe.com/payments",
            lines.join("\n"),
            "Checking yesterday's payments in Stripe",
            &format!("stripe-payments-{shown}"),
            json!({
                "page": "stripe",
                "row_icon": "card",
                "account": "Pebblewick",
                "nav": Self::stripe_nav(),
                "selected_nav": "Transactions",
                "heading": "Payments",
                "subheading": format!("{day} \u{00B7} All payments"),
                "columns": ["Amount", "Status", "Customer", "Description"],
                "rows": rows,
                "highlight_row": 0,
            }),
        )
    }

    fn stripe_catalog() -> Win {
        let rows = [
            ["Starter", "$19.00 USD / month", "Active"],
            [
                "Studio",
                "$49.00 USD / month \u{00B7} $490.00 USD / year",
                "Active",
            ],
            ["Pro", "$99.00 USD / month", "Active"],
            ["Class packs", "From $60.00 USD", "Active"],
            ["Gift cards", "Customer chooses", "Archived"],
        ];
        let mut lines = vec![
            "Product catalog".to_owned(),
            "Products  Coupons  Shipping rates  Tax rates".to_owned(),
        ];
        lines.extend(rows.iter().map(|row| row.join("  ")));
        Self::page(
            "Product catalog \u{2013} Stripe",
            "https://dashboard.stripe.com/products",
            lines.join("\n"),
            "Adding the Studio plan's prices in Stripe",
            "stripe-catalog",
            json!({
                "page": "stripe",
                "account": "Pebblewick",
                "nav": Self::stripe_nav(),
                "selected_nav": "Product catalog",
                "heading": "Product catalog",
                "subheading": "Products \u{00B7} Coupons \u{00B7} Shipping rates \u{00B7} Tax rates",
                "columns": ["Name", "Pricing", "Status"],
                "rows": rows,
                "highlight_row": 1,
                "button": "Add product",
                "row_icon": "product",
                "footer": "5 results",
            }),
        )
    }

    fn stripe_studio() -> Win {
        let rows = [
            ["$49.00 USD", "Per month", "Default"],
            ["$490.00 USD", "Per year", "New"],
        ];
        let lines = [
            "Studio".to_owned(),
            "Waitlists, reminders and class packs for growing studios".to_owned(),
            "Pricing".to_owned(),
            rows[0].join("  "),
            rows[1].join("  "),
            "Add another price".to_owned(),
            "Details".to_owned(),
            "Tax category  Software as a service".to_owned(),
        ];
        Self::page(
            "Studio \u{2013} Product catalog \u{2013} Stripe",
            "https://dashboard.stripe.com/products/prod_studio_plan",
            lines.join("\n"),
            "Setting a yearly price for the Studio plan",
            "stripe-studio",
            json!({
                "page": "stripe",
                "account": "Pebblewick",
                "nav": Self::stripe_nav(),
                "selected_nav": "Product catalog",
                "heading": "Studio",
                "subheading": "Waitlists, reminders and class packs for growing studios",
                "columns": ["Price", "Interval", ""],
                "rows": rows,
                "highlight_row": 1,
                "button": "Add another price",
                "row_icon": "none",
                "details": [["Product ID", "prod_studio_plan"], ["Tax category", "Software as a service"], ["Statement descriptor", "PEBBLEWICK STUDIO"]],
            }),
        )
    }

    fn stripe_pricing() -> Win {
        let cards = [
            [
                "Payments",
                "2.9% + 30\u{00A2}",
                "per successful card charge",
            ],
            [
                "Billing",
                "0.7%",
                "of billing volume, for subscriptions and invoices",
            ],
            [
                "Custom",
                "Talk to sales",
                "for large volumes and unique models",
            ],
        ];
        let mut lines = vec![
            "Pricing built for businesses of all sizes".to_owned(),
            "Pay as you go, with no setup fees or monthly fees.".to_owned(),
        ];
        lines.extend(cards.iter().map(|card| card.join("  ")));
        Self::page(
            "Pricing & Fees | Stripe",
            "https://stripe.com/pricing",
            lines.join("\n"),
            "Reading \u{201C}Pricing & Fees\u{201D} on Stripe",
            "stripe-pricing",
            json!({
                "page": "stripe-pricing",
                "headline": "Pricing built for businesses of all sizes",
                "subheadline": "Pay as you go, with no setup fees or monthly fees.",
                "cards": cards,
            }),
        )
    }

    fn stripe_docs() -> Win {
        let blocks = vec![
            h1("Prorations"),
            p("When a customer changes plans partway through a billing period, you can credit the unused time on the old price and charge for the time left on the new one."),
            h2("How prorations work"),
            p("A proration is an adjustment for the part of a period a customer spent on each price. By default, a change creates prorations that appear on the next invoice."),
            h2("Switch to yearly billing"),
            p("To start the yearly period right away, set the billing cycle anchor to now and invoice the difference immediately."),
            code("billing_cycle_anchor: \"now\",\nproration_behavior: \"always_invoice\""),
            h2("Preview the invoice"),
            p("Before you make the change, retrieve the upcoming invoice to show the customer what they'll pay today and what they'll pay next year."),
        ];
        Self::page(
            "Prorations | Stripe Documentation",
            "https://docs.stripe.com/billing/subscriptions/prorations",
            blocks_text(&blocks),
            "Reading \u{201C}Prorations\u{201D}",
            "stripe-docs",
            json!({
                "page": "docs",
                "site": "Stripe Docs",
                "breadcrumb": "Billing \u{203A} Subscriptions \u{203A} Prorations",
                "sidebar": ["Subscriptions", "How subscriptions work", "Change prices", "Prorations", "Billing cycle", "Trials", "Cancellations"],
                "selected": "Prorations",
                "blocks": blocks_json(&blocks),
            }),
        )
    }

    fn search(query: &str, results: &[(&str, &str, &str)], screen_id: &str) -> Win {
        let url = format!(
            "https://www.google.com/search?q={}",
            query.replace(' ', "+")
        );
        let mut lines = vec![query.to_owned()];
        for (title, site, snippet) in results {
            lines.push((*title).to_owned());
            lines.push((*site).to_owned());
            lines.push((*snippet).to_owned());
        }
        Self::page(
            &format!("{query} - Google Search"),
            &url,
            lines.join("\n"),
            &format!("Looking up {query}"),
            screen_id,
            json!({
                "page": "search",
                "stats": format!("About {} results", 180_000 + query.len() * 23_117),
                "query": query,
                "results": results.iter().map(|(t, s, x)| json!([t, s, x])).collect::<Vec<_>>(),
            }),
        )
    }

    fn search_proration() -> Win {
        Self::search(
            "stripe prorate monthly to yearly",
            &[
                ("Prorations | Stripe Documentation", "docs.stripe.com \u{203A} billing \u{203A} subscriptions \u{203A} prorations", "Credit the unused time on the old price and charge for the time left on the new one when a customer changes plans."),
                ("Change a subscription's price", "docs.stripe.com \u{203A} billing \u{203A} subscriptions \u{203A} change-price", "Upgrade or downgrade a subscription, and choose whether to invoice the difference now or on the next invoice."),
                ("Moving customers to yearly plans without double charging", "billingnotes.example \u{203A} yearly-upgrades", "Credit what they already paid this month, then start the year today. Customers see one clear invoice."),
            ],
            "search-proration",
        )
    }

    fn search_retention() -> Win {
        Self::search(
            "net revenue retention by cohort",
            &[
                ("Net revenue retention, explained", "foundernotes.example \u{203A} metrics \u{203A} nrr", "Start with the revenue a group of customers paid a year ago. Add expansion, subtract churn and downgrades, then divide."),
                ("Cohort tables for subscription businesses", "metricsweekly.example \u{203A} cohorts", "Group customers by the month they started and follow each group's revenue over time."),
            ],
            "search-retention",
        )
    }

    fn search_discount() -> Win {
        Self::search(
            "saas yearly plan discount",
            &[
                ("How much to discount yearly plans", "pricingnotes.example \u{203A} yearly", "Most subscription businesses give one or two months free. Two months is the simplest to explain."),
                ("Yearly billing: what customers expect", "saasnotes.example \u{203A} billing", "Show the monthly price on the yearly plan, and say how much it saves in a year."),
            ],
            "search-discount",
        )
    }

    fn search_booking() -> Win {
        Self::search(
            "class booking software pricing",
            &[
                (
                    "Pricing \u{00B7} Classbook",
                    "classbook.example \u{203A} pricing",
                    "Simple pricing for every studio. Solo $25 a month, Team $59 a month.",
                ),
                (
                    "The best booking tools for small studios",
                    "studioweekly.example \u{203A} booking-tools",
                    "We compared eight booking tools on waitlists, reminders and payments.",
                ),
            ],
            "search-booking",
        )
    }

    fn claude_proration() -> Win {
        let messages = [
            ("user", "When a studio moves from monthly to yearly in the middle of a month, how should I prorate it in Stripe?"),
            ("assistant", "Credit the unused part of the month, then start the yearly period right away. Update the subscription with the yearly price, set billing_cycle_anchor to \"now\" and proration_behavior to \"always_invoice\". The studio pays the yearly price minus the credit today."),
            ("user", "Should the credit show on the invoice?"),
            ("assistant", "Yes. Stripe adds it as its own line, so the studio sees exactly what was credited and what they paid."),
        ];
        let main = std::iter::once("Prorating yearly upgrades".to_owned())
            .chain(messages.iter().map(|(_, text)| (*text).to_owned()))
            .collect::<Vec<_>>()
            .join("\n");
        Self::page(
            "Prorating yearly upgrades - Claude",
            "https://claude.ai/chat/7c1e0b52-4d2f-4f0e-9b6a-3e8d5c1a2f90",
            main,
            "Asking Claude about prorating yearly upgrades",
            "claude-proration",
            json!({
                "page": "claude",
                "chat_title": "Prorating yearly upgrades",
                "messages": messages.iter().map(|(who, text)| json!([who, text])).collect::<Vec<_>>(),
            }),
        )
    }

    fn article_update() -> Win {
        let blocks = vec![
            h1("How to write a monthly investor update"),
            p("Lead with the numbers that changed, then say what you learned and what you need. Keep it short enough to read on a phone."),
            h2("Start with three numbers"),
            p("Revenue, cash and runway. Show last month beside this month, so nobody has to look it up."),
            h2("End with your asks"),
            p("Be specific: an intro to one company, a candidate for one role. Investors help when they know exactly how."),
        ];
        Self::page(
            "How to write a monthly investor update \u{00B7} Founder Notes",
            "https://foundernotes.example/investor-updates",
            blocks_text(&blocks),
            "Reading \u{201C}How to write a monthly investor update\u{201D}",
            "article-update",
            json!({
                "page": "article",
                "site": "Founder Notes",
                "nav": ["Essays", "Metrics", "Fundraising", "Subscribe"],
                "byline": "Founder Notes \u{00B7} 5 min read",
                "blocks": blocks_json(&blocks),
            }),
        )
    }

    fn competitor_pricing() -> Win {
        let cards = [
            [
                "Solo",
                "$25",
                "a month",
                "One instructor, unlimited classes",
            ],
            [
                "Team",
                "$59",
                "a month",
                "Up to 8 instructors and waitlists",
            ],
            [
                "Studio+",
                "$119",
                "a month",
                "Several locations and payroll exports",
            ],
        ];
        let mut lines = vec![
            "Simple pricing for every studio".to_owned(),
            "Yearly plans save 15%".to_owned(),
        ];
        lines.extend(cards.iter().map(|card| card.join(" ")));
        Self::page(
            "Pricing \u{00B7} Classbook",
            "https://classbook.example/pricing",
            lines.join("\n"),
            "Reading \u{201C}Pricing \u{00B7} Classbook\u{201D}",
            "classbook-pricing",
            json!({
                "page": "pricing",
                "site": "Classbook",
                "headline": "Simple pricing for every studio",
                "subheadline": "Yearly plans save 15%",
                "cards": cards,
            }),
        )
    }

    // -- Google Docs and Sheets ------------------------------------------------

    fn q4_update(&self, stage: u8) -> Win {
        let month = self.local(self.now_us).month_name();
        let mut blocks = vec![
            h1("Q4 investor update"),
            p(&format!(
                "Pebblewick \u{00B7} {month} {}",
                self.local(self.now_us).year
            )),
            h2("Highlights"),
            li("Monthly revenue reached $84,200, up 11% from last month."),
            li("412 studios pay for Pebblewick, 38 more than last month."),
            li("The Studio plan launches Thursday, with yearly billing."),
        ];
        if stage >= 1 {
            blocks.extend([
                h2("Metrics"),
                p("Net revenue retention: 108%"),
                p("Logo churn: 1.9% a month"),
                p("Cash: $2.4M, about 21 months of runway"),
            ]);
        }
        if stage >= 2 {
            blocks.extend([
                p("Net revenue retention by cohort: 2024 studios 112%, 2025 studios 104%"),
                h2("What we learned"),
                p("Studios that turn on waitlists book 14% more classes. Waitlists are now on for everyone."),
                h2("Asks"),
                li("Intros to studio chains with three or more locations."),
                li("A finance lead who has scaled subscription billing."),
            ]);
        }
        let caption = match stage {
            0 => "Drafting the Q4 investor update",
            1 => "Filling in metrics for the Q4 investor update",
            _ => "Writing the asks in the Q4 investor update",
        };
        Self::page(
            "Q4 investor update - Google Docs",
            Q4_DOC,
            blocks_text(&blocks),
            caption,
            &format!("docs-q4-{stage}"),
            json!({
                "page": "gdocs",
                "doc_title": "Q4 investor update",
                "blocks": blocks_json(&blocks),
            }),
        )
    }

    fn budget(stage: u8) -> Win {
        let columns = ["", "Q1", "Q2", "Q3", "Q4", "2027"];
        let mut rows: Vec<[&str; 6]> = vec![
            ["Revenue", "$1.12M", "$1.31M", "$1.52M", "$1.74M", "$5.69M"],
            ["Studios paying", "470", "540", "615", "700", ""],
            ["Headcount", "9", "11", "12", "14", ""],
            ["Payroll", "$486K", "$590K", "$642K", "$748K", "$2.47M"],
            ["Hosting and tools", "$38K", "$41K", "$45K", "$49K", "$173K"],
            ["Office and travel", "$22K", "$24K", "$24K", "$30K", "$100K"],
        ];
        if stage >= 1 {
            rows.extend([
                ["Payment fees", "$36K", "$42K", "$48K", "$55K", "$181K"],
                ["Marketing", "$60K", "$75K", "$75K", "$90K", "$300K"],
                ["Events", "$8K", "$18K", "$8K", "$24K", "$58K"],
            ]);
        }
        if stage >= 2 {
            rows.extend([
                ["Total costs", "$650K", "$790K", "$842K", "$996K", "$3.28M"],
                ["Net", "$470K", "$520K", "$678K", "$744K", "$2.41M"],
            ]);
        }
        let mut lines = vec!["2027 budget".to_owned(), columns[1..].join("  ")];
        lines.extend(rows.iter().map(|row| row.join("  ").trim_end().to_owned()));
        let caption = match stage {
            0 => "Working through hiring costs in the 2027 budget",
            1 => "Adding marketing and fees to the 2027 budget",
            _ => "Totaling the 2027 budget",
        };
        let bold: Vec<usize> = rows
            .iter()
            .enumerate()
            .filter(|(_, row)| matches!(row[0], "Revenue" | "Total costs" | "Net"))
            .map(|(index, _)| index)
            .collect();
        Self::page(
            "2027 budget - Google Sheets",
            BUDGET_SHEET,
            lines.join("\n"),
            caption,
            &format!("sheets-budget-{stage}"),
            json!({
                "page": "gsheets",
                "doc_title": "2027 budget",
                "columns": columns,
                "rows": rows,
                "bold_rows": bold,
                "sheets": ["Plan", "Hiring", "Marketing", "Notes"],
                "active_sheet": 0,
                "selected_row": if stage >= 1 { 7 } else { 3 },
            }),
        )
    }

    // -- Slack -----------------------------------------------------------------

    /// A channel's messages: days before today, hour, minute, who and what.
    fn channel_messages(channel: &str) -> Vec<(u64, u64, u64, &'static str, &'static str)> {
        if channel == "team" {
            return vec![
                (1, 9, 20, NADIA, "September waitlist numbers are in the dashboard. Juniper Yoga filled 31 spots from its waitlist."),
                (1, 14, 22, THEO, "Pricing page v2 is in Figma. The Studio card is the one we highlight."),
                (1, 14, 26, NADIA, "Can the yearly toggle say \u{201C}2 months free\u{201D}? It tested better than a percentage."),
                (1, 14, 34, FOUNDER, "Yes, let's use that."),
                (1, 16, 40, MALIK, "Receipts now show the class and the instructor."),
                (1, 17, 5, JOY, "Two more studios asked about yearly billing."),
                (0, 9, 2, IRIS, "Staging has the Studio plan behind a flag. Yearly billing is next."),
                (0, 9, 6, MALIK, "Webhook retries are fixed. No more double receipts."),
                (0, 9, 11, JOY, "Juniper Yoga asked if they can switch to yearly. I told them this week."),
                (0, 9, 14, FOUNDER, "Yes. Let's aim for Thursday. I'll take the proration part today."),
                (0, 10, 21, FOUNDER, "Team sync notes\n\u{2022} Studio plan: prices go live Thursday. Ren owns proration, Iris reviews.\n\u{2022} Pricing page v2: Theo shares the final layout tomorrow.\n\u{2022} Changelog: Nadia drafts the October post. Waitlists lead.\n\u{2022} Support: Joy lists the studios that asked about yearly billing."),
                (0, 10, 22, IRIS, "I'll review the proration change after lunch."),
                (0, 10, 22, THEO, "Layout is close. One question on the yearly toggle."),
                (0, 16, 58, NADIA, "October changelog draft is in Notion. Waitlists first, then yearly billing."),
                (0, 17, 15, FOUNDER, "Yearly billing is up for review. Iris, it's the annual-billing branch."),
                (0, 17, 16, IRIS, "On it."),
            ];
        }
        vec![
            (
                1,
                8,
                41,
                OWEN,
                "Saw the waitlist numbers in the dashboard. Nice.",
            ),
            (1, 9, 8, FOUNDER, "Thanks. More in the Q4 update this week."),
            (
                1,
                18,
                48,
                OWEN,
                "Looking forward to the update call tomorrow at 4.",
            ),
            (
                1,
                19,
                2,
                FOUNDER,
                "Same. I'll share the draft before lunch.",
            ),
            (
                0,
                9,
                4,
                MIRA,
                "Morning. Is the Studio plan still on for this week?",
            ),
            (
                0,
                9,
                12,
                FOUNDER,
                "Yes, Thursday. Draft update coming before lunch.",
            ),
            (
                0,
                14,
                58,
                MIRA,
                "Thanks for the early look at the Q4 update. Strong month.",
            ),
            (
                0,
                14,
                59,
                MIRA,
                "Could you add net revenue retention by cohort? The board will ask.",
            ),
            (
                0,
                15,
                0,
                FOUNDER,
                "Yes. Adding it now, with the 2024 and 2025 studios split out.",
            ),
            (
                0,
                15,
                1,
                OWEN,
                "+1. Also curious how many studios want yearly billing.",
            ),
            (
                0,
                15,
                2,
                FOUNDER,
                "About 40 so far. The Studio plan ships Thursday with a yearly price.",
            ),
        ]
    }

    /// A Slack channel as it looked at `at`, on the day `back` days before
    /// today: the messages of that day and the one before, up to then.
    fn slack(&self, channel: &'static str, back: u64, at: u64) -> Win {
        let mut shown: Vec<(String, &str, String, &str, u64)> = Vec::new();
        for (days, hour, minute, who, what) in Self::channel_messages(channel) {
            let when = self.at(days, hour, minute);
            if when > at || days > back + 1 || days < back {
                continue;
            }
            let day = if days == back { "Today" } else { "Yesterday" };
            shown.push((
                day.to_owned(),
                who,
                self.local(when).clock(),
                what,
                hour * 60 + minute,
            ));
        }
        let keep = shown.len().saturating_sub(9);
        let shown = &shown[keep..];
        let mut main = vec![format!("# {channel}")];
        let mut last_day = "";
        for (day, who, when, what, _) in shown {
            if day.as_str() != last_day {
                main.push(day.clone());
                last_day = day.as_str();
            }
            main.push(format!("{who}  {when}"));
            main.push((*what).to_owned());
        }
        let channels = ["general", "team", "launches", "harbor-lane", "support"];
        let dms = [IRIS, THEO, NADIA, MIRA];
        let mut rest = vec![
            "Pebblewick".to_owned(),
            "Home".to_owned(),
            "DMs".to_owned(),
            "Activity".to_owned(),
            "Threads".to_owned(),
            "Channels".to_owned(),
        ];
        rest.extend(channels.iter().map(|c| format!("# {c}")));
        rest.push("Direct messages".to_owned());
        rest.extend(dms.iter().map(|d| (*d).to_owned()));
        rest.push(format!("Message #{channel}"));
        let local = self.local(at);
        Win {
            app: SLACK,
            title: format!("{channel} (Channel) - Pebblewick - Slack"),
            url: None,
            main: main.join("\n"),
            rest: rest.join("\n"),
            caption: format!("Chatting in #{channel}"),
            screen: Some(Screen {
                id: format!(
                    "slack-{channel}-{}-{:02}{:02}",
                    local.date_string(),
                    local.hour,
                    local.minute
                ),
                template: "slack",
                meta: json!({
                    "workspace": "Pebblewick",
                    "channel": channel,
                    "channels": channels,
                    "dms": dms,
                    "messages": shown.iter().map(|(day, who, when, what, minute)| json!([who, when, what, day, minute])).collect::<Vec<_>>(),
                    "topic": if channel == "harbor-lane" { "Shared with Harbor Lane Ventures and Tallgrass Capital" } else { "Daily notes and launches" },
                }),
            }),
        }
    }

    // -- Zoom ------------------------------------------------------------------

    fn zoom(meeting: &str, people: &[&str], screen_id: &str) -> Win {
        let mut main = vec![meeting.to_owned()];
        main.extend(people.iter().map(|p| (*p).to_owned()));
        Win {
            app: ZOOM,
            title: "Zoom Meeting".to_owned(),
            url: None,
            main: main.join("\n"),
            rest: [
                "Mute",
                "Stop Video",
                "Participants",
                "Chat",
                "Share Screen",
                "Record",
                "Reactions",
                "Leave",
            ]
            .join("\n"),
            caption: "On a call in Zoom".to_owned(),
            screen: Some(Screen {
                id: screen_id.to_owned(),
                template: "zoom",
                meta: json!({ "meeting": meeting, "participants": people, "speaker": 0 }),
            }),
        }
    }

    fn zoom_team() -> Win {
        Self::zoom(
            "Team sync",
            &[IRIS, THEO, NADIA, MALIK, JOY, FOUNDER],
            "zoom-team-sync",
        )
    }

    fn zoom_investors() -> Win {
        Self::zoom(
            "Investor update",
            &[MIRA, OWEN, FOUNDER],
            "zoom-investor-update",
        )
    }

    fn zoom_pricing_review() -> Win {
        Self::zoom(
            "Pricing review",
            &[THEO, NADIA, IRIS, FOUNDER],
            "zoom-pricing-review",
        )
    }

    fn zoom_one_on_one() -> Win {
        Self::zoom("1:1 with Iris", &[IRIS, FOUNDER], "zoom-one-on-one")
    }

    // -- Code ------------------------------------------------------------------

    fn editor(file: &str, lines: &[&str], cursor: usize, caption: Option<&str>) -> Win {
        let tree = [
            "\u{25BE} src",
            "billing.ts",
            "billing.test.ts",
            "plans.ts",
            "subscriptions.ts",
            "webhooks.ts",
            "\u{25B8} test",
            "package.json",
            "README.md",
        ];
        let tabs: Vec<&str> = ["plans.ts", "billing.ts", "billing.test.ts"]
            .into_iter()
            .chain(std::iter::once(file))
            .fold(Vec::new(), |mut tabs, tab| {
                if !tabs.contains(&tab) {
                    tabs.push(tab);
                }
                tabs
            });
        let active = tabs.iter().position(|t| *t == file).unwrap_or(0);
        let rest = format!(
            "{}\nEXPLORER\nPEBBLEWICK-APP\n{}\nannual-billing  0 errors, 0 warnings  Ln {cursor}, Col 1  TypeScript",
            tabs.join("\n"),
            tree.join("\n")
        );
        Win {
            app: CODE,
            title: format!("{file} \u{2014} {PROJECT}"),
            url: None,
            main: lines.join("\n"),
            rest,
            caption: caption
                .map_or_else(|| format!("Working on {file} in {PROJECT}"), str::to_owned),
            screen: Some(Screen {
                id: format!("code-{}", file.replace('.', "-")),
                template: "editor",
                meta: json!({
                    "project": PROJECT,
                    "file": file,
                    "tabs": tabs,
                    "active_tab": active,
                    "tree": tree,
                    "language": "TypeScript",
                    "cursor_line": cursor,
                    "branch": "annual-billing",
                }),
            }),
        }
    }

    fn billing_ts() -> Win {
        Self::editor(
            "billing.ts",
            &[
                "import Stripe from \"stripe\";",
                "import { plans, type PlanId } from \"./plans\";",
                "import { findSubscription, type Studio } from \"./subscriptions\";",
                "",
                "const stripe = new Stripe(process.env.STRIPE_KEY ?? \"\");",
                "",
                "// Moves a studio to yearly billing and credits the unused part of the month.",
                "export async function switchToYearly(studioId: string, plan: PlanId) {",
                "  const subscription = await findSubscription(studioId);",
                "  const item = subscription.items.data[0];",
                "  return stripe.subscriptions.update(subscription.id, {",
                "    items: [{ id: item.id, price: plans[plan].yearlyPrice }],",
                "    billing_cycle_anchor: \"now\",",
                "    proration_behavior: \"always_invoice\",",
                "  });",
                "}",
                "",
                "// What the studio pays today: the yearly price, less the days left this month.",
                "export async function previewYearly(studio: Studio, plan: PlanId) {",
                "  const upcoming = await stripe.invoices.retrieveUpcoming({",
                "    customer: studio.customerId,",
                "    subscription: studio.subscriptionId,",
                "    subscription_items: [{ price: plans[plan].yearlyPrice }],",
                "    subscription_billing_cycle_anchor: \"now\",",
                "  });",
                "  return {",
                "    credit: upcoming.lines.data.filter((line) => line.amount < 0),",
                "    total: upcoming.amount_due,",
                "  };",
                "}",
            ],
            14,
            None,
        )
    }

    fn billing_test_ts() -> Win {
        Self::editor(
            "billing.test.ts",
            &[
                "import { describe, expect, it } from \"vitest\";",
                "import { previewYearly, switchToYearly } from \"./billing\";",
                "import { fakeStripe, studio } from \"../test/fake-stripe\";",
                "",
                "describe(\"switchToYearly\", () => {",
                "  it(\"credits the unused part of the month\", async () => {",
                "    fakeStripe({ plan: \"studio\", daysLeft: 12 });",
                "    const invoice = await switchToYearly(\"juniper-yoga\", \"studio\");",
                "    expect(invoice.credit).toBe(1960); // 12 of 30 days at $49",
                "  });",
                "",
                "  it(\"starts the yearly period today\", async () => {",
                "    const invoice = await switchToYearly(\"juniper-yoga\", \"studio\");",
                "    expect(invoice.periodStart).toBe(today());",
                "  });",
                "",
                "  it(\"keeps the studio's coupon\", async () => {",
                "    fakeStripe({ plan: \"studio\", coupon: \"FRIENDS10\" });",
                "    const invoice = await switchToYearly(\"kiln-and-co\", \"studio\");",
                "    expect(invoice.discounts).toHaveLength(1);",
                "  });",
                "});",
                "",
                "describe(\"previewYearly\", () => {",
                "  it(\"shows the credit before anything changes\", async () => {",
                "    const preview = await previewYearly(studio(\"juniper-yoga\"), \"studio\");",
                "    expect(preview.total).toBe(49000 - 1960);",
                "  });",
                "});",
            ],
            9,
            None,
        )
    }

    fn plans_ts() -> Win {
        Self::editor(
            "plans.ts",
            &[
                "export type PlanId = \"starter\" | \"studio\" | \"pro\";",
                "",
                "type Plan = {",
                "  name: string;",
                "  monthlyPrice: string;",
                "  yearlyPrice?: string;",
                "  instructors: number | \"unlimited\";",
                "};",
                "",
                "export const plans: Record<PlanId, Plan> = {",
                "  starter: {",
                "    name: \"Starter\",",
                "    monthlyPrice: \"price_starter_monthly\",",
                "    instructors: 2,",
                "  },",
                "  studio: {",
                "    name: \"Studio\",",
                "    monthlyPrice: \"price_studio_monthly\",",
                "    yearlyPrice: \"price_studio_yearly\",",
                "    instructors: 8,",
                "  },",
                "  pro: {",
                "    name: \"Pro\",",
                "    monthlyPrice: \"price_pro_monthly\",",
                "    instructors: \"unlimited\",",
                "  },",
                "};",
            ],
            19,
            None,
        )
    }

    fn webhooks_ts() -> Win {
        Self::editor(
            "webhooks.ts",
            &[
                "import type Stripe from \"stripe\";",
                "import { sendReceipt } from \"./receipts\";",
                "import { markPaid } from \"./subscriptions\";",
                "",
                "const seen = new Set<string>();",
                "",
                "// Stripe retries a webhook until it gets a 200, so an event can arrive twice.",
                "export async function onInvoicePaid(event: Stripe.Event) {",
                "  if (seen.has(event.id)) return;",
                "  seen.add(event.id);",
                "  const invoice = event.data.object as Stripe.Invoice;",
                "  await markPaid(invoice.subscription as string);",
                "  await sendReceipt(invoice);",
                "}",
                "",
                "export async function onInvoiceFailed(event: Stripe.Event) {",
                "  const invoice = event.data.object as Stripe.Invoice;",
                "  // The studio keeps its classes for seven days while the card is retried.",
                "  await markPaid(invoice.subscription as string, { graceDays: 7 });",
                "}",
            ],
            9,
            None,
        )
    }

    fn terminal(lines: &[String], screen_id: &str) -> Win {
        Win {
            app: TERMINAL,
            title: format!("{PROJECT_FOLDER} \u{2014} -zsh \u{2014} 160\u{00D7}40"),
            url: None,
            main: lines.join("\n"),
            rest: String::new(),
            caption: format!("Working in Terminal: {PROJECT}"),
            screen: Some(Screen {
                id: screen_id.to_owned(),
                template: "terminal",
                meta: json!({ "prompt": PROMPT }),
            }),
        }
    }

    /// A test run in the terminal, as vitest prints it.
    fn test_run(failing: bool) -> Vec<String> {
        let mut lines = vec![
            format!("{PROMPT}pnpm test billing"),
            String::new(),
            format!("> pebblewick-app@2.3.0 test {PROJECT_PATH}"),
            "> vitest run billing".to_owned(),
            String::new(),
            format!(" RUN  v2.1.4 {PROJECT_PATH}"),
            String::new(),
        ];
        if failing {
            lines.extend([
                " \u{276F} src/billing.test.ts (4 tests | 1 failed) 38ms".to_owned(),
                "   \u{00D7} switchToYearly > credits the unused part of the month".to_owned(),
                "     \u{2192} expected 1633 to be 1960 // Object.is equality".to_owned(),
                "   \u{2713} switchToYearly > starts the yearly period today".to_owned(),
                "   \u{2713} switchToYearly > keeps the studio's coupon".to_owned(),
                "   \u{2713} previewYearly > shows the credit before anything changes".to_owned(),
                String::new(),
                " FAIL  src/billing.test.ts > switchToYearly > credits the unused part of the month".to_owned(),
                "AssertionError: expected 1633 to be 1960".to_owned(),
                " \u{276F} src/billing.test.ts:9:32".to_owned(),
                String::new(),
                " Test Files  1 failed (1)".to_owned(),
                "      Tests  1 failed | 3 passed (4)".to_owned(),
            ]);
        } else {
            lines.extend([
                " \u{2713} src/billing.test.ts (4 tests) 41ms".to_owned(),
                "   \u{2713} switchToYearly > credits the unused part of the month".to_owned(),
                "   \u{2713} switchToYearly > starts the yearly period today".to_owned(),
                "   \u{2713} switchToYearly > keeps the studio's coupon".to_owned(),
                "   \u{2713} previewYearly > shows the credit before anything changes".to_owned(),
                String::new(),
                " Test Files  1 passed (1)".to_owned(),
                "      Tests  4 passed (4)".to_owned(),
            ]);
        }
        lines.extend([
            "   Duration  412ms".to_owned(),
            String::new(),
            format!("{PROMPT}git status --short"),
            " M src/billing.ts".to_owned(),
            " M src/plans.ts".to_owned(),
            "?? src/billing.test.ts".to_owned(),
            PROMPT.trim_end().to_owned(),
        ]);
        lines
    }

    fn tests_first_run() -> Win {
        Self::terminal(&Self::test_run(true), "terminal-tests-first")
    }

    fn tests_passing() -> Win {
        Self::terminal(&Self::test_run(false), "terminal-tests-passing")
    }

    fn tests_pushed() -> Win {
        let mut lines = Vec::new();
        lines.extend([
            format!("{PROMPT}pnpm test"),
            String::new(),
            " Test Files  9 passed (9)".to_owned(),
            "      Tests  61 passed (61)".to_owned(),
            "   Duration  2.84s".to_owned(),
            String::new(),
            format!("{PROMPT}git commit -am \"Switch studios to yearly billing\""),
            "[annual-billing 4e7a91c] Switch studios to yearly billing".to_owned(),
            " 3 files changed, 84 insertions(+), 6 deletions(-)".to_owned(),
            format!("{PROMPT}git push -u origin annual-billing"),
            "To github.example:pebblewick/pebblewick-app.git".to_owned(),
            " * [new branch]      annual-billing -> annual-billing".to_owned(),
            "branch 'annual-billing' set up to track 'origin/annual-billing'.".to_owned(),
            PROMPT.trim_end().to_owned(),
        ]);
        Self::terminal(&lines, "terminal-pushed")
    }

    fn tests_webhooks() -> Win {
        let lines = [
            format!("{PROMPT}git log --oneline -3"),
            "9c2d0e1 Show the class and instructor on receipts".to_owned(),
            "51b7f3a Follow the studio's time zone in reminders".to_owned(),
            "e80a6c4 Add waitlists".to_owned(),
            format!("{PROMPT}pnpm test webhooks"),
            String::new(),
            format!(" RUN  v2.1.4 {PROJECT_PATH}"),
            String::new(),
            " \u{2713} src/webhooks.test.ts (3 tests) 22ms".to_owned(),
            "   \u{2713} onInvoicePaid > sends one receipt when Stripe retries".to_owned(),
            "   \u{2713} onInvoicePaid > marks the subscription paid".to_owned(),
            "   \u{2713} onInvoiceFailed > keeps classes for seven days".to_owned(),
            String::new(),
            " Test Files  1 passed (1)".to_owned(),
            "      Tests  3 passed (3)".to_owned(),
            String::new(),
            PROMPT.trim_end().to_owned(),
        ];
        Self::terminal(&lines, "terminal-webhooks")
    }

    // -- Notion, Figma, Calendar ----------------------------------------------

    fn notion(title: &str, blocks: &[Block], caption: &str, screen_id: &str) -> Win {
        let sidebar = [
            "Product",
            "October changelog",
            "Hiring plan",
            "Roadmap",
            "Support playbook",
        ];
        Win {
            app: NOTION,
            title: title.to_owned(),
            url: None,
            main: blocks_text(blocks),
            rest: format!("Pebblewick\nSearch\nHome\n{}\nShare", sidebar.join("\n")),
            caption: caption.to_owned(),
            screen: Some(Screen {
                id: screen_id.to_owned(),
                template: "notion",
                meta: json!({
                    "workspace": "Pebblewick",
                    "sidebar": sidebar,
                    "selected": title,
                    "breadcrumb": format!("Product / {title}"),
                    "blocks": blocks_json(blocks),
                }),
            }),
        }
    }

    fn changelog(stage: u8) -> Win {
        let mut blocks = vec![
            h1("October changelog"),
            h2("Waitlists are here"),
            p("When a class is full, people can join its waitlist. If a spot opens, the next person gets a text and has an hour to take it."),
            li("Turn waitlists on for each class, or for the whole studio."),
            li("Spots are offered in the order people joined."),
            li("Instructors see the waitlist on the class roster."),
        ];
        if stage >= 1 {
            blocks.extend([
                h2("Yearly billing for the Studio plan"),
                p("Studios on the Studio plan can switch to yearly billing and get two months free. We credit the unused part of the month when they switch."),
                h2("Smaller fixes"),
                li("Reminders follow the studio's time zone."),
                li("Receipts show the class and the instructor."),
            ]);
        }
        Self::notion(
            "October changelog",
            &blocks,
            "Writing \u{201C}October changelog\u{201D}",
            &format!("notion-changelog-{stage}"),
        )
    }

    fn hiring_plan() -> Win {
        let blocks = vec![
            h1("Hiring plan"),
            h2("Finance lead"),
            p("Owns billing, revenue reporting and the board pack. Starts in Q1."),
            h2("Senior engineer"),
            p("Payments and integrations. Works with Iris on billing."),
            h2("Customer success"),
            p("Second hire on Joy's team, for studios with several locations."),
        ];
        Self::notion(
            "Hiring plan",
            &blocks,
            "Writing \u{201C}Hiring plan\u{201D}",
            "notion-hiring",
        )
    }

    fn figma(stage: u8) -> Win {
        let plans = [
            ["Starter", "$19", "a month", "Up to 2 instructors"],
            [
                "Studio",
                "$49",
                "a month",
                "Waitlists, reminders and class packs",
            ],
            [
                "Pro",
                "$99",
                "a month",
                "Several locations and payroll exports",
            ],
        ];
        let toggle = if stage >= 1 {
            "Yearly \u{00B7} 2 months free"
        } else {
            "Yearly"
        };
        let mut lines = vec![
            "Pricing page v2".to_owned(),
            "Pricing that grows with your studio".to_owned(),
            format!("Monthly  {toggle}"),
        ];
        lines.extend(plans.iter().map(|plan| plan.join(" ")));
        lines.push("Start free for 14 days".to_owned());
        Win {
            app: FIGMA,
            title: "Pricing page v2".to_owned(),
            url: None,
            main: lines.join("\n"),
            rest: "Design\nPrototype\nInspect\nPages\nPricing\nCheckout\nLayers\nHero\nPlans\nFAQ"
                .to_owned(),
            caption: "Designing \u{201C}Pricing page v2\u{201D}".to_owned(),
            screen: Some(Screen {
                id: format!("figma-pricing-{stage}"),
                template: "figma",
                meta: json!({
                    "file": "Pricing page v2",
                    "pages": ["Pricing", "Checkout"],
                    "layers": ["Hero", "Toggle", "Plans", "Starter", "Studio", "Pro", "FAQ", "Footer"],
                    "headline": "Pricing that grows with your studio",
                    "toggle": ["Monthly", toggle],
                    "plans": plans,
                    "features": [
                        ["Online booking", "Email reminders", "Up to 2 instructors"],
                        ["Everything in Starter", "Waitlists", "Text reminders", "Class packs"],
                        ["Everything in Studio", "Several locations", "Payroll exports", "Priority support"],
                    ],
                    "highlight": 1,
                }),
            }),
        }
    }

    /// The Calendar app's week view, as it was at `at`.
    fn calendar_week(&self, at: u64, events: &[CalendarEvent]) -> Win {
        let now = self.local(at);
        // The week shown: Monday to Sunday around `at`.
        let monday_back = u64::from((now.weekday + 6) % 7);
        let today_start = day_start(at, self.tz, 0);
        let monday = today_start.saturating_sub(monday_back * super::DAY);
        let days: Vec<Value> = (0..7u64)
            .map(|index| {
                let day = self.local(monday + index * super::DAY + 12 * 60 * MIN);
                json!([
                    format!("{} {}", &day.weekday_name()[..3], day.day),
                    index == monday_back
                ])
            })
            .collect();
        let shown: Vec<&CalendarEvent> = events
            .iter()
            .filter(|e| e.start_us >= monday && e.start_us < monday + 7 * super::DAY)
            .collect();
        let rows: Vec<Value> = shown
            .iter()
            .map(|event| {
                let start = self.local(event.start_us);
                let end = self.local(event.end_us);
                let index = (event.start_us - monday) / super::DAY;
                json!([
                    index,
                    start.hour * 60 + start.minute,
                    end.hour * 60 + end.minute,
                    event.title,
                    event.location,
                ])
            })
            .collect();
        let mut lines = vec![format!("{} {}", now.month_name(), now.year)];
        lines.extend(
            shown
                .iter()
                .map(|event| format!("{} {}", event.title, self.local(event.start_us).clock())),
        );
        Win {
            app: CALENDAR,
            title: "Calendar".to_owned(),
            url: None,
            main: lines.join("\n"),
            rest: "Day\nWeek\nMonth\nYear\nToday\nWork\nHome".to_owned(),
            caption: "Checking the calendar".to_owned(),
            screen: Some(Screen {
                id: format!("calendar-week-{}", now.date_string()),
                template: "calendar",
                meta: json!({
                    "month_label": format!("{} {}", now.month_name(), now.year),
                    "days": days,
                    "events": rows,
                    "now_minutes": now.hour * 60 + now.minute,
                    "today_label": now.long_date(),
                }),
            }),
        }
    }

    // -- The days ---------------------------------------------------------------

    fn calendar(&self) -> Vec<CalendarEvent> {
        let mut events = Vec::new();
        let mut add = |id: &str, title: &str, start: u64, minutes: u64, location: &str| {
            events.push(CalendarEvent {
                id: format!("demo-{id}"),
                title: title.to_owned(),
                start_us: start,
                end_us: start + minutes * MIN,
                calendar: "Work".to_owned(),
                location: Some(location.to_owned()),
            });
        };
        for back in 0..=6u64 {
            let day = self.local(self.at(back, 12, 0));
            if back <= 1 || !day.is_weekend() {
                add(
                    &format!("sync-{back}"),
                    "Team sync",
                    self.at(back, 10, 0),
                    20,
                    "Zoom",
                );
            }
        }
        for ahead in 1..=4u64 {
            let start = self.at(0, 10, 0) + ahead * super::DAY;
            if !self.local(start).is_weekend() {
                add(
                    &format!("sync-ahead-{ahead}"),
                    "Team sync",
                    start,
                    20,
                    "Zoom",
                );
            }
        }
        add(
            "interview",
            "Finance lead interview",
            self.at(0, 11, 0) + 2 * super::DAY,
            45,
            "Zoom",
        );
        add(
            "review",
            "Week in review",
            self.at(0, 16, 0) + 4 * super::DAY,
            30,
            "Office",
        );
        add(
            "investors",
            "Investor update",
            self.at(0, 16, 0),
            30,
            "Zoom",
        );
        add(
            "lunch",
            "Lunch with Joy",
            self.at(0, 12, 15),
            45,
            "Juniper Cafe",
        );
        add(
            "pricing-review",
            "Pricing review",
            self.at(1, 14, 0),
            30,
            "Zoom",
        );
        add(
            "one-on-one",
            "1:1 with Iris",
            self.at(2, 11, 30),
            30,
            "Zoom",
        );
        add("board-prep", "Board prep", self.at(3, 16, 0), 60, "Office");
        add(
            "launch",
            "Studio plan launch",
            self.at(0, 9, 0) + 3 * super::DAY,
            30,
            "Office",
        );
        add(
            "coffee",
            "Coffee with Mira",
            self.at(0, 9, 30) + super::DAY,
            45,
            "Harbor Lane",
        );
        events.sort_by(|a, b| a.start_us.cmp(&b.start_us).then(a.id.cmp(&b.id)));
        events
    }

    #[allow(clippy::too_many_lines)] // the day, session by session
    fn today(&self, calendar: &[CalendarEvent]) -> Vec<Session> {
        vec![
            self.session(0, 9, 5)
                .hold(3, |at| self.calendar_week(at, calendar))
                .hold(9, |at| self.slack("team", 0, at))
                .hold(5, |at| self.slack("harbor-lane", 0, at))
                .hold(6, |at| self.stripe_payments(at))
                .note("Morning check-in", "You read the team channel and the investors' messages, then looked over yesterday's payments in Stripe.", "Nothing notable."),
            self.session(0, 9, 33)
                .hold(22, |_| Self::budget(0))
                .note("2027 budget: hiring", "You worked out when each hire starts and what payroll costs each quarter.", "You moved the finance lead from Q2 to Q1."),
            self.session(0, 10, 0)
                .hold(20, |_| Self::zoom_team())
                .note("Team sync", "You met with the team about the Studio plan launch, the pricing page and the October changelog.", "Nothing notable."),
            self.session(0, 10, 22)
                .hold(10, |at| self.slack("team", 0, at))
                .hold(8, |_| Self::changelog(0))
                .note("Team sync notes", "You posted the notes from the team sync and started the October changelog.", "Nothing notable."),
            self.session(0, 10, 42)
                .hold(16, |_| Self::billing_ts())
                .hold(9, |_| Self::billing_test_ts())
                .note("Yearly billing in billing.ts", "You started the switch to yearly billing and wrote its first tests.", "Nothing notable."),
            self.session(0, 11, 13)
                .hold(1, |_| Self::search_proration())
                .hold(9, |_| Self::stripe_docs())
                .hold(8, |_| Self::claude_proration())
                .hold(8, |_| Self::billing_ts())
                .note("Prorating yearly upgrades", "You read how Stripe prorates a change partway through a month and asked Claude how to credit the unused days.", "You settled on crediting the unused part of the month and invoicing right away."),
            self.session(0, 11, 44)
                .hold(24, |_| self.q4_update(1))
                .note("Q4 investor update: metrics", "You filled in revenue, churn and net revenue retention in the Q4 update.", "Nothing notable."),
            self.session(0, 13, 10)
                .hold(16, |_| Self::figma(1))
                .hold(4, |_| Self::stripe_pricing())
                .hold(6, |_| Self::figma(1))
                .note("Pricing page: the Studio plan", "You laid out the three plans on the pricing page and checked Stripe's fees for yearly billing.", "Nothing notable."),
            self.session(0, 13, 38)
                .hold(11, |_| Self::stripe_catalog())
                .hold(9, |_| Self::stripe_studio())
                .note("Studio plan prices in Stripe", "You added the Studio plan's monthly and yearly prices in Stripe.", "Nothing notable."),
            self.session(0, 14, 0)
                .hold(6, |_| Self::plans_ts())
                .hold(14, |_| Self::billing_ts())
                .hold(8, |_| Self::tests_first_run())
                .note("Wiring up the Studio plan", "You connected the new yearly price to billing.ts and ran the billing tests. One failed on the credit for unused days.", "Nothing notable."),
            self.session(0, 14, 29)
                .hold(10, |_| Self::billing_test_ts())
                .hold(10, |_| Self::billing_ts())
                .hold(9, |_| Self::tests_passing())
                .note("Fixing the credit for unused days", "You fixed the credit for the unused part of the month and got the billing tests passing.", "You counted the days left instead of the days used."),
            self.session(0, 15, 2)
                .hold(13, |at| self.slack("harbor-lane", 0, at))
                .hold(1, |_| Self::search_retention())
                .hold(14, |_| self.q4_update(2))
                .note("Investors on the Q4 update", "Mira asked for net revenue retention by cohort. You added it to the update, with what Pebblewick learned and its asks.", "Nothing notable."),
            self.session(0, 15, 33)
                .hold(24, |_| Self::budget(1))
                .note("2027 budget: marketing", "You added marketing and payment fees to the 2027 budget.", "Nothing notable."),
            self.session(0, 16, 0)
                .hold(30, |_| Self::zoom_investors())
                .note("Investor update", "You walked Harbor Lane and Tallgrass through the quarter and the Studio plan launch.", "Nothing notable."),
            self.session(0, 16, 35)
                .hold(22, |_| Self::changelog(1))
                .note("October changelog", "You wrote the yearly billing part of the October changelog.", "Nothing notable."),
            self.session(0, 17, 0)
                .hold(10, |_| Self::billing_ts())
                .hold(6, |_| Self::tests_pushed())
                .hold(4, |at| self.slack("team", 0, at))
                .note("Shipping yearly billing", "You pushed the yearly billing change and asked Iris to review it.", "Nothing notable."),
        ]
    }

    #[allow(clippy::too_many_lines)] // the day, session by session
    fn yesterday(&self) -> Vec<Session> {
        vec![
            self.session(1, 9, 10)
                .hold(8, |at| self.slack("harbor-lane", 1, at))
                .hold(6, |at| self.stripe_payments(at))
                .note("Morning check-in", "You caught up on Slack and checked the morning's payments.", "Nothing notable."),
            self.session(1, 9, 30)
                .hold(26, |_| self.q4_update(0))
                .note("Q4 investor update: first draft", "You drafted the highlights of the Q4 investor update.", "Nothing notable."),
            self.session(1, 10, 0)
                .hold(20, |_| Self::zoom_team())
                .note("Team sync", "You met with the team about the pricing review and the webhook fix.", "Nothing notable."),
            self.session(1, 10, 25)
                .hold(20, |_| Self::figma(0))
                .note("Pricing page v2", "You started the second version of the pricing page in Figma.", "Nothing notable."),
            self.session(1, 10, 55)
                .hold(1, |_| Self::search_discount())
                .hold(6, |_| Self::competitor_pricing())
                .hold(10, |_| Self::figma(0))
                .note("Pricing page: yearly toggle", "You looked at how other booking tools price yearly plans and added a yearly toggle to the design.", "You compared a percentage off with months free."),
            self.session(1, 11, 25)
                .hold(18, |_| Self::webhooks_ts())
                .hold(8, |_| Self::tests_webhooks())
                .note("Webhook retries", "You stopped Stripe's webhook retries from sending a second receipt.", "Nothing notable."),
            self.session(1, 13, 5)
                .hold(28, |_| Self::budget(0))
                .note("2027 budget: first pass", "You set up the 2027 budget with revenue, headcount and hosting.", "Nothing notable."),
            self.session(1, 13, 35)
                .hold(15, |_| Self::hiring_plan())
                .note("Hiring plan", "You wrote what the finance lead and the senior engineer would own.", "Nothing notable."),
            self.session(1, 14, 0)
                .hold(30, |_| Self::zoom_pricing_review())
                .note("Pricing review", "You reviewed the new pricing with Theo, Nadia and Iris.", "Nothing notable."),
            self.session(1, 14, 35)
                .hold(8, |at| self.slack("team", 1, at))
                .hold(12, |_| Self::figma(1))
                .note("Pricing page: two months free", "You changed the yearly toggle to say two months free.", "Nothing notable."),
            self.session(1, 15, 5)
                .hold(22, |_| Self::billing_ts())
                .hold(6, |_| Self::tests_webhooks())
                .note("Billing: a first look at yearly plans", "You read through billing.ts to plan the switch to yearly billing.", "Nothing notable."),
            self.session(1, 15, 40)
                .hold(20, |_| self.q4_update(0))
                .note("Q4 investor update", "You reworked the highlights of the investor update.", "Nothing notable."),
            self.session(1, 16, 5)
                .hold(22, |_| Self::budget(0))
                .note("2027 budget: payroll", "You added payroll for each quarter of 2027.", "Nothing notable."),
            self.session(1, 16, 30)
                .hold(24, |_| Self::changelog(0))
                .note("October changelog: waitlists", "You wrote the waitlists part of the October changelog.", "Nothing notable."),
        ]
    }

    /// The days before yesterday: lighter, and lightest at the weekend.
    #[allow(clippy::too_many_lines)] // the days, session by session
    fn earlier(&self, back: u64) -> Vec<Session> {
        let day = self.local(self.at(back, 12, 0));
        if day.is_weekend() {
            return vec![self
                .session(back, 11, 0)
                .hold(25, |_| self.q4_update(0))
                .note(
                    "Q4 investor update: outline",
                    "You outlined the Q4 investor update.",
                    "Nothing notable.",
                )];
        }
        let sync = |back| {
            self.session(back, 10, 0)
                .hold(20, |_| Self::zoom_team())
                .note("Team sync", "You met with the team.", "Nothing notable.")
        };
        let billing = |back, hour, minute, minutes| {
            self.session(back, hour, minute)
                .hold(minutes, |_| Self::billing_ts())
                .note(
                    "Billing code",
                    "You worked on billing.ts in pebblewick-app.",
                    "Nothing notable.",
                )
        };
        let q4 = |back, hour, minutes| {
            self.session(back, hour, 0)
                .hold(minutes, |_| self.q4_update(0))
                .note(
                    "Q4 investor update: outline",
                    "You outlined the Q4 investor update.",
                    "Nothing notable.",
                )
        };
        let mut sessions = match back {
            2 => vec![
                self.session(back, 9, 25)
                    .hold(25, |_| Self::webhooks_ts())
                    .note("Webhooks", "You read through the Stripe webhook handler.", "Nothing notable."),
                sync(back),
                self.session(back, 11, 30)
                    .hold(30, |_| Self::zoom_one_on_one())
                    .note("1:1 with Iris", "You met with Iris about billing and hiring.", "Nothing notable."),
                self.session(back, 13, 0)
                    .hold(1, |_| Self::search_booking())
                    .hold(8, |_| Self::competitor_pricing())
                    .hold(10, |_| Self::hiring_plan())
                    .note("Booking tools and hiring", "You looked at what other booking tools charge, then worked on the hiring plan.", "Nothing notable."),
                billing(back, 15, 0, 28),
            ],
            3 => vec![
                self.session(back, 9, 20)
                    .hold(20, |_| Self::article_update())
                    .note("Investor updates", "You read about writing a monthly investor update.", "Nothing notable."),
                sync(back),
                q4(back, 11, 30),
                self.session(back, 15, 0)
                    .hold(26, |_| Self::webhooks_ts())
                    .hold(4, |_| Self::tests_webhooks())
                    .note("Webhook tests", "You wrote tests for the webhook handler.", "Nothing notable."),
            ],
            4 => vec![
                billing(back, 9, 30, 24),
                sync(back),
                billing(back, 11, 0, 28),
                self.session(back, 13, 30)
                    .hold(15, |_| Self::stripe_docs())
                    .note("Stripe prorations", "You read how Stripe handles a change of plan partway through a month.", "Nothing notable."),
            ],
            5 => vec![
                self.session(back, 9, 25)
                    .hold(25, |_| Self::webhooks_ts())
                    .note("Webhooks", "You worked on the Stripe webhook handler.", "Nothing notable."),
                sync(back),
                billing(back, 11, 0, 28),
                q4(back, 14, 20),
            ],
            _ => vec![
                billing(back, 9, 30, 26),
                sync(back),
                q4(back, 11, 25),
            ],
        };
        sessions.sort_by_key(|s| s.start_us);
        sessions
    }

    /// Today's sessions as far as now: the one under way has no note, and a
    /// pause between sessions belongs to the one before it, still going.
    fn cut_at_now(&self, sessions: Vec<Session>) -> Vec<Session> {
        let newest = self.now_us.saturating_sub(super::NEWEST_AGE_US);
        let total = sessions.len();
        let mut kept: Vec<Session> = sessions
            .into_iter()
            .filter(|s| s.start_us <= newest)
            .collect();
        let more_after = kept.len() < total;
        if let Some(last) = kept.last_mut() {
            if newest < last.end_us() {
                last.note = None;
            } else if more_after {
                // Still at it between sessions: the last window stays open.
                let extra = (newest - last.end_us()) / MIN + 1;
                if let Some(hold) = last.holds.last_mut() {
                    hold.minutes += extra;
                }
                last.note = None;
            }
        }
        kept
    }

    fn summaries(back: u64) -> Option<(String, String)> {
        let (headline, narrative) = match back {
            0 => (
                "Yearly billing, the Q4 update and a call with investors.",
                "You started with the team channel and the 2027 budget, then met the team. Late morning went to yearly billing for the Studio plan and how Stripe prorates it. After lunch you set the Studio plan's prices in Stripe, got the billing tests passing and finished the investors' asks in the Q4 update.",
            ),
            1 => (
                "The pricing page, a pricing review and the first budget pass.",
                "You drafted the Q4 update, then worked on the second pricing page in Figma. After the pricing review you changed the yearly toggle to two months free and set up the 2027 budget.",
            ),
            _ => return None,
        };
        Some((headline.to_owned(), narrative.to_owned()))
    }

    #[allow(clippy::too_many_lines)] // one line about Ren after another
    fn claims() -> Vec<Claim> {
        let item = |text: &str,
                    kind: PropositionKind,
                    confidence: f64,
                    confirmed: bool,
                    evidence: &[&'static str],
                    days: &[u64],
                    minutes_ago: u64| Claim {
            text: text.to_owned(),
            kind,
            confidence,
            decay: 0.3,
            confirmed,
            evidence: evidence.to_vec(),
            days: days.to_vec(),
            minutes_ago,
        };
        vec![
            item(
                "Ren is launching a Studio plan with yearly billing for Pebblewick.",
                PropositionKind::Project,
                0.9,
                true,
                &["Product catalog", "billing.ts", "Pricing page v2"],
                &[],
                90,
            ),
            item(
                "Ren is writing the Q4 investor update for Harbor Lane and Tallgrass.",
                PropositionKind::Project,
                0.85,
                false,
                &["Q4 investor update"],
                &[],
                60,
            ),
            item(
                "Ren is planning Pebblewick's 2027 budget, starting with hiring.",
                PropositionKind::Project,
                0.8,
                false,
                &["2027 budget"],
                &[],
                120,
            ),
            item(
                "Ren writes TypeScript and runs tests from the terminal.",
                PropositionKind::Skill,
                0.8,
                false,
                &["pebblewick-app"],
                &[],
                200,
            ),
            item(
                "Ren drafts plans in a doc before building them.",
                PropositionKind::Habit,
                0.7,
                false,
                &["Q4 investor update", "Hiring plan"],
                &[1],
                300,
            ),
            item(
                "Ren wants yearly billing live by Thursday.",
                PropositionKind::Goal,
                0.7,
                false,
                &["team (Channel)"],
                &[0],
                400,
            ),
            item(
                "Ren checks the team channel first thing in the morning.",
                PropositionKind::Habit,
                0.6,
                false,
                &["team (Channel)"],
                &[0],
                420,
            ),
            item(
                "Ren works closely with Iris on billing changes.",
                PropositionKind::Relationship,
                0.75,
                false,
                &["billing.ts"],
                &[0, 1],
                240,
            ),
            item(
                "Ren took a few tries to get the credit for unused days right.",
                PropositionKind::Struggle,
                0.7,
                false,
                &["billing.test.ts", "-zsh"],
                &[0],
                180,
            ),
            item(
                "Ren prefers crediting customers over charging them twice.",
                PropositionKind::Preference,
                0.6,
                false,
                &["Prorating yearly upgrades", "webhooks.ts"],
                &[],
                260,
            ),
            item(
                "Ren is busy with the Studio plan launch this week.",
                PropositionKind::State,
                0.8,
                false,
                &["billing.ts"],
                &[0],
                30,
            ),
            item(
                "Ren is hiring a finance lead.",
                PropositionKind::Project,
                0.8,
                true,
                &["Hiring plan"],
                &[],
                2 * 24 * 60,
            ),
        ]
    }
}

/// Make the week that ends at `now_us`.
pub fn week(now_us: u64, tz: i32) -> World {
    let story = Story { now_us, tz };
    let calendar = story.calendar();
    let mut days = Vec::new();
    for back in (0..=6u64).rev() {
        let sessions = match back {
            0 => story.cut_at_now(story.today(&calendar)),
            1 => story.yesterday(),
            _ => story.earlier(back),
        };
        days.push(DayStory {
            back,
            start_us: day_start(now_us, tz, back),
            sessions,
            summary: Story::summaries(back),
        });
    }
    World {
        now_us,
        tz,
        days,
        calendar,
        claims: Story::claims(),
    }
}
