import Foundation

/// Sam's week, made up, for the synthetic preview, the off-screen renders
/// and tests (persona Sam, Trailhead Bikes, Northwind Studio; Monday,
/// October 12, 2026): Working On's items and the moments behind them, the
/// pages and searches, the Resume plans and a calendar. Every name is
/// invented and nothing here is anyone's screen. It matches the approved
/// prototype's data.
public enum WorkFixtures {
    /// One moment, and the drawn screen its screenshot shows, if any.
    public struct Moment: Sendable {
        public let hit: Hit
        /// `editor`, `terminal`, `article`, `document`, `chat`, `figma`,
        /// `checklist`, `draft`, `invoices`, `pricing`: what a renderer
        /// draws and seals for it.
        public let screen: String?
    }

    // MARK: Ids

    public static let trailheadShop = "w_5c1e8a0d2f9b47e3a6d1"
    public static let pricingV3 = "w_93b7f04c11a8e2d6c5f0"
    public static let q4Planning = "w_0e6d2a9f8c3b7154de22"
    public static let launchChecklist = "w_4a8c1f6e9d2b0735ab91"
    public static let pricingDraft = "w_b2d9e4071f6a3c85e7d4"
    public static let octoberInvoices = "w_71f3c9a2e05d8b46c3a8"
    public static let bikeAPI = "w_c84e2b6d9a1f03e7b5c2"
    public static let pricingV2 = "w_2f9a7d1c4e8b6035a1e9"
    public static let mortgage = "w_e5a0c3f7b9d2148e6c07"
    public static let giftCardCopy = "w_68d1b9e2f4a7c03d9b15"

    /// The newest moment of trailhead-shop: tax.rs at 2:20 PM.
    public static let taxRsMoment: UInt64 = 81_220
    /// Rounding half to even, read at 2:35 PM.
    public static let roundingMoment: UInt64 = 81_235
    /// The Notes checklist at 1:34 PM.
    public static let checklistMoment: UInt64 = 81_134
    /// The gift card note, Friday at 9:05 AM.
    public static let giftCardMoment: UInt64 = 83_009
    /// bike-api's routes in Cursor, October 2.
    public static let bikeAPIMoment: UInt64 = 90_211
    /// Trailhead pricing v2 in Figma, October 1.
    public static let pricingV2Moment: UInt64 = 90_110

    // MARK: Moments

    /// A moment `minutes` after local midnight, `daysAgo` days before `now`.
    private static func at(_ daysAgo: Int, _ minutes: Int, now: Date, calendar: Calendar) -> UInt64 {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) ?? now
        return UInt64((day.timeIntervalSince1970 + Double(minutes * 60)) * 1_000_000)
    }

    private struct Row {
        let id: UInt64
        let daysAgo: Int
        let minutes: Int
        let app: String
        let title: String
        var url: String?
        let caption: String
        let text: String
        var screen: String?
        var source = "screen_ocr"
    }

    private static let vscode = "com.microsoft.VSCode"
    private static let terminal = "com.apple.Terminal"
    private static let chrome = "com.google.Chrome"
    private static let safari = "com.apple.Safari"
    private static let notes = "com.apple.Notes"
    private static let figma = "com.figma.Desktop"
    private static let numbers = "com.apple.iWork.Numbers"
    private static let slack = "com.tinyspeck.slackmacgap"
    private static let messages = "com.apple.MobileSMS"
    private static let claude = "com.anthropic.claudefordesktop"
    private static let cursor = "com.todesktop.230313mzl4w4u92"

    private static var rows: [Row] {
        [
            // Monday, October 12 (today).
            Row(id: roundingMoment, daysAgo: 0, minutes: 875, app: chrome, title: "Rounding half to even \u{00B7} Dev Notes",
                url: "https://devnotes.example/rounding", caption: "Reading \u{201C}Rounding half to even\u{201D}",
                text: "Why banker\u{2019}s rounding keeps order totals from drifting by a cent \u{00B7} Priya Raman \u{00B7} Oct 12, 2026 \u{00B7} 6 min read \u{00B7} Round half up looks fair, but every tie goes the same way.",
                screen: "article", source: "browser_page"),
            Row(id: 81_228, daysAgo: 0, minutes: 868, app: slack, title: "launch (Channel) - Northwind Studio - Slack",
                caption: "Chatting in #launch",
                text: "Jordan Lee 2:14 PM staging is green, shipping the rounding fix at 4 \u{00B7} Priya Raman 2:15 PM I\u{2019}ll update the changelog before then"),
            Row(id: 81_224, daysAgo: 0, minutes: 864, app: messages, title: "Sam Lee", caption: "Messaging Sam Lee",
                text: "Are we still on for 3? Yes, running five minutes late \u{00B7} See you there", screen: "chat"),
            Row(id: taxRsMoment, daysAgo: 0, minutes: 860, app: vscode, title: "tax.rs \u{2014} trailhead-shop",
                caption: "Working on tax.rs in trailhead-shop",
                text: "/// Rounds half to even, so totals never drift by a cent.\npub fn round_half_even(amount: Money) -> Money {\n    let cents = amount.cents_exact();",
                screen: "editor"),
            Row(id: 81_212, daysAgo: 0, minutes: 852, app: terminal, title: "trailhead-shop \u{2014} zsh \u{2014} 160\u{00D7}40",
                caption: "Working in Terminal: trailhead-shop",
                text: "dev@studio trailhead-shop % cargo test tax\nCompiling trailhead-shop v0.4.2 (/Users/dev/trailhead-shop)",
                screen: "terminal"),
            Row(id: 81_209, daysAgo: 0, minutes: 849, app: chrome, title: "Seat-based pricing: the pros and cons",
                url: "https://saasguide.example/pricing/seats",
                caption: "Reading \u{201C}Seat-based pricing: the pros and cons\u{201D}",
                text: "Charging per seat grows with the customer, but it can slow adoption inside a company. A seat minimum keeps small teams from paying too little.",
                source: "browser_page"),
            Row(id: 81_207, daysAgo: 0, minutes: 847, app: chrome, title: "Per-seat or tiered? How to price a team plan",
                url: "https://pricingnotes.example/team-plans",
                caption: "Reading \u{201C}Per-seat or tiered? How to price a team plan\u{201D}",
                text: "Most teams choose between charging for every seat and charging by tier. A seat minimum is the usual compromise.",
                screen: "pricing", source: "browser_page"),
            Row(id: 81_206, daysAgo: 0, minutes: 846, app: chrome, title: "per seat vs tiered pricing - Google Search",
                url: "https://www.google.com/search?q=per+seat+vs+tiered+pricing",
                caption: "Looking up per seat vs tiered pricing",
                text: "Per-seat or tiered? How to price a team plan pricingnotes.example \u{203A} team-plans \u{00B7} Most teams choose between charging for every seat and charging by tier.",
                source: "browser_page"),
            Row(id: 81_159, daysAgo: 0, minutes: 839, app: chrome, title: "Q4 planning - Google Docs",
                url: "https://docs.google.com/document/d/q4-planning/edit", caption: "Working on \u{201C}Q4 planning\u{201D}",
                text: "Owner: Priya Raman \u{00B7} Updated Oct 12 \u{00B7} Goals \u{00B7} Ship the rounding fix before the holiday sale \u{00B7} Cut checkout to under 30 seconds on mobile",
                screen: "document", source: "browser_page"),
            Row(id: 81_146, daysAgo: 0, minutes: 826, app: figma, title: "Trailhead pricing v3",
                caption: "Designing \u{201C}Trailhead pricing v3\u{201D}",
                text: "Hero \u{00B7} One plan for every team \u{00B7} Start free, then $18 a seat each month, billed annually",
                screen: "figma"),
            Row(id: checklistMoment, daysAgo: 0, minutes: 814, app: notes, title: "Notes",
                caption: "Working on \u{201C}Launch checklist\u{201D}",
                text: "Rounding fix merged \u{00B7} Changelog updated \u{00B7} Gift card copy reviewed \u{00B7} Beta group told about 0.4 \u{00B7} Pricing page live before the October sale",
                screen: "checklist"),
            Row(id: 81_122, daysAgo: 0, minutes: 802, app: figma, title: "Trailhead pricing v3",
                caption: "Designing \u{201C}Trailhead pricing v3\u{201D}",
                text: "Plans \u{00B7} Ride $0, one person \u{00B7} Tour $18 a seat, monthly \u{00B7} Club $29 a seat, monthly"),
            Row(id: 82_159, daysAgo: 0, minutes: 719, app: vscode, title: "tax_tests.rs \u{2014} trailhead-shop",
                caption: "Working on tax_tests.rs in trailhead-shop",
                text: "#[test]\nfn order_total_rounds_once() {\n    let lines = vec![line(1999, 3), line(450, 2)];"),
            Row(id: 81_148, daysAgo: 0, minutes: 708, app: terminal, title: "trailhead-shop \u{2014} zsh \u{2014} 160\u{00D7}40",
                caption: "Working in Terminal: trailhead-shop",
                text: "dev@studio trailhead-shop % cargo test tax\ntest result: ok. 6 passed; 0 failed; 0 ignored"),
            Row(id: 81_131, daysAgo: 0, minutes: 691, app: vscode, title: "tax.rs \u{2014} trailhead-shop",
                caption: "Working on tax.rs in trailhead-shop",
                text: "pub fn order_total(lines: &[Line]) -> Money {\n    let subtotal: Money = lines.iter().map(|l| l.price * l.qty).sum();",
                screen: "editor"),
            Row(id: 81_125, daysAgo: 0, minutes: 685, app: claude, title: "Rounding modes for money",
                caption: "Asking Claude about rounding modes",
                text: "Which rounding mode should a checkout use for sales tax? Most payment processors round half to even on the final total."),
            Row(id: 81_120, daysAgo: 0, minutes: 680, app: chrome, title: "Rounding half to even \u{00B7} Dev Notes",
                url: "https://devnotes.example/rounding", caption: "Reading \u{201C}Rounding half to even\u{201D}",
                text: "Why banker\u{2019}s rounding keeps order totals from drifting by a cent \u{00B7} Priya Raman \u{00B7} Oct 12, 2026",
                screen: "article", source: "browser_page"),
            Row(id: 81_118, daysAgo: 0, minutes: 678, app: chrome, title: "rust round half to even - Google Search",
                url: "https://www.google.com/search?q=rust+round+half+to+even", caption: "Looking up rust round half to even",
                text: "Rounding half to even devnotes.example \u{203A} rounding \u{00B7} Why banker\u{2019}s rounding keeps order totals from drifting by a cent",
                source: "browser_page"),
            Row(id: 81_102, daysAgo: 0, minutes: 662, app: vscode, title: "tax.rs \u{2014} trailhead-shop",
                caption: "Working on tax.rs in trailhead-shop",
                text: "    let tax = subtotal * TAX_RATE;\n    (subtotal + tax).round_cents()", screen: "editor"),
            Row(id: 81_038, daysAgo: 0, minutes: 638, app: notes, title: "Notes", caption: "Working on \u{201C}Pricing page draft\u{201D}",
                text: "Three plans: Ride, Tour and Club. The team plan sits in the middle. \u{00B7} Plans \u{00B7} Ride: free for one person.",
                screen: "draft"),
            Row(id: 81_025, daysAgo: 0, minutes: 625, app: figma, title: "Trailhead pricing v3",
                caption: "Designing \u{201C}Trailhead pricing v3\u{201D}",
                text: "Plans \u{00B7} Ride $0, one person \u{00B7} Tour $18 a seat, monthly \u{00B7} Club $29 a seat, monthly",
                screen: "figma"),
            Row(id: 81_004, daysAgo: 0, minutes: 604, app: slack, title: "design (Channel) - Northwind Studio - Slack",
                caption: "Chatting in #design",
                text: "Priya Raman 10:02 AM Can we try the team plan in the middle? \u{00B7} Sam 10:04 AM Moving it now"),
            Row(id: 80_958, daysAgo: 0, minutes: 598, app: figma, title: "Trailhead pricing v3",
                caption: "Designing \u{201C}Trailhead pricing v3\u{201D}",
                text: "Hero \u{00B7} One plan for every team \u{00B7} Plans \u{00B7} Ride \u{00B7} Tour \u{00B7} Club", screen: "figma"),
            Row(id: 80_941, daysAgo: 0, minutes: 581, app: notes, title: "Notes", caption: "Working on \u{201C}Pricing page draft\u{201D}",
                text: "Three plans: Ride, Tour and Club. \u{00B7} Hero \u{00B7} One plan for every team.", screen: "draft"),
            Row(id: 80_914, daysAgo: 0, minutes: 554, app: numbers, title: "October invoices",
                caption: "Working on \u{201C}October invoices\u{201D}",
                text: "Invoice 1042 \u{00B7} Northwind Supplies \u{00B7} $1,240.00 \u{00B7} Due Oct 30 \u{00B7} Invoice 2291 \u{00B7} Spokewise \u{00B7} $380.00 \u{00B7} Paid Oct 6",
                screen: "invoices"),
            // Friday, October 9.
            Row(id: 83_605, daysAgo: 3, minutes: 965, app: vscode, title: "cart.rs \u{2014} trailhead-shop",
                caption: "Working on cart.rs in trailhead-shop",
                text: "pub fn apply_discount(cart: &mut Cart, code: &str) {\n    let line_total = line.price * line.qty;"),
            Row(id: 83_540, daysAgo: 3, minutes: 940, app: terminal, title: "trailhead-shop \u{2014} zsh \u{2014} 160\u{00D7}40",
                caption: "Working in Terminal: trailhead-shop",
                text: "dev@studio trailhead-shop % cargo test cart\ntest result: ok. 4 passed; 0 failed; 0 ignored"),
            Row(id: 83_516, daysAgo: 3, minutes: 916, app: chrome, title: "Plans and pricing \u{00B7} Spoke & Chain",
                url: "https://spokeandchain.example/plans", caption: "Reading \u{201C}Plans and pricing \u{00B7} Spoke & Chain\u{201D}",
                text: "Annual plans save two months. Every plan includes free tune-ups and a loaner bike while yours is in the shop.",
                source: "browser_page"),
            Row(id: 83_514, daysAgo: 3, minutes: 914, app: chrome, title: "Pricing \u{00B7} Velo Cycles",
                url: "https://velocycles.example/pricing", caption: "Reading \u{201C}Pricing \u{00B7} Velo Cycles\u{201D}",
                text: "Three tiers for shops of every size. Pay per bike, billed yearly, and switch tiers any time.",
                source: "browser_page"),
            Row(id: 83_512, daysAgo: 3, minutes: 912, app: chrome, title: "bike shop pricing page examples - Google Search",
                url: "https://www.google.com/search?q=bike+shop+pricing+page+examples",
                caption: "Looking up bike shop pricing page examples",
                text: "Pricing \u{00B7} Velo Cycles velocycles.example \u{203A} pricing \u{00B7} Plans and pricing \u{00B7} Spoke & Chain spokeandchain.example \u{203A} plans",
                source: "browser_page"),
            Row(id: 83_430, daysAgo: 3, minutes: 870, app: chrome, title: "Currency math without floats \u{00B7} Dev Notes",
                url: "https://devnotes.example/currency", caption: "Reading \u{201C}Currency math without floats\u{201D}",
                text: "Store money as whole cents. Floats can\u{2019}t hold most decimal amounts exactly, so 0.1 + 0.2 is not 0.3.",
                source: "browser_page"),
            Row(id: 83_110, daysAgo: 3, minutes: 670, app: figma, title: "Trailhead pricing v3",
                caption: "Designing \u{201C}Trailhead pricing v3\u{201D}",
                text: "Plans \u{00B7} Ride \u{00B7} Tour \u{00B7} Club \u{00B7} Annual: two months free", screen: "figma"),
            Row(id: 83_002, daysAgo: 3, minutes: 602, app: chrome, title: "Q4 planning - Google Docs",
                url: "https://docs.google.com/document/d/q4-planning/edit", caption: "Working on \u{201C}Q4 planning\u{201D}",
                text: "Goals \u{00B7} Ship the rounding fix before the holiday sale \u{00B7} Cut checkout to under 30 seconds on mobile",
                screen: "document", source: "browser_page"),
            Row(id: 82_930, daysAgo: 3, minutes: 570, app: notes, title: "Notes", caption: "Working on \u{201C}Launch checklist\u{201D}",
                text: "Rounding fix merged \u{00B7} Changelog updated \u{00B7} Gift card copy reviewed"),
            // Thursday, October 8.
            Row(id: 84_620, daysAgo: 4, minutes: 980, app: vscode, title: "money.rs \u{2014} trailhead-shop",
                caption: "Working on money.rs in trailhead-shop",
                text: "pub struct Money { cents: i64 }\nimpl Money { pub fn from_cents(c: i64) -> Self { Money { cents: c } } }"),
            Row(id: 84_507, daysAgo: 4, minutes: 907, app: chrome, title: "Sales tax by state \u{00B7} Tax Guide",
                url: "https://taxguide.example/states", caption: "Reading \u{201C}Sales tax by state\u{201D}",
                text: "Most states round tax to the nearest cent on the invoice total, not on each line.", source: "browser_page"),
            Row(id: 84_505, daysAgo: 4, minutes: 905, app: chrome, title: "sales tax rounding rules by state - Google Search",
                url: "https://www.google.com/search?q=sales+tax+rounding+rules+by+state",
                caption: "Looking up sales tax rounding rules by state",
                text: "Sales tax by state taxguide.example \u{203A} states \u{00B7} Most states round tax to the nearest cent on the invoice total.",
                source: "browser_page"),
            Row(id: 84_315, daysAgo: 4, minutes: 795, app: notes, title: "Notes", caption: "Working on \u{201C}Launch checklist\u{201D}",
                text: "Rounding fix merged \u{00B7} Changelog updated"),
            Row(id: 84_140, daysAgo: 4, minutes: 700, app: figma, title: "Trailhead pricing v3",
                caption: "Designing \u{201C}Trailhead pricing v3\u{201D}", text: "Plans \u{00B7} Ride \u{00B7} Tour \u{00B7} Club",
                screen: "figma"),
            Row(id: 84_010, daysAgo: 4, minutes: 610, app: notes, title: "Notes", caption: "Working on \u{201C}Pricing page draft\u{201D}",
                text: "Three plans: Ride, Tour and Club.", screen: "draft"),
            // Friday, October 9: the gift card note.
            Row(id: giftCardMoment, daysAgo: 3, minutes: 545, app: notes, title: "Notes",
                caption: "Working on \u{201C}Gift card copy\u{201D}",
                text: "Give the ride \u{00B7} Trailhead gift cards work for rentals, tours and anything in the shop.",
                screen: "gift-card"),
            // Friday, October 2, and Thursday, October 1: last month's work.
            Row(id: bikeAPIMoment, daysAgo: 10, minutes: 700, app: cursor, title: "routes.rs \u{2014} bike-api",
                caption: "Working on routes.rs in bike-api",
                text: "/// Every bike in the shop, and where it is now.\npub fn routes() -> Router {", screen: "bike-api"),
            Row(id: pricingV2Moment, daysAgo: 11, minutes: 640, app: figma, title: "Trailhead pricing v2",
                caption: "Designing \u{201C}Trailhead pricing v2\u{201D}",
                text: "Hero \u{00B7} Ride more, pay less \u{00B7} Day pass $12 \u{00B7} Annual $149", screen: "figma-v2"),
        ]
    }

    /// Every moment, newest first, without screenshots: a renderer adds the
    /// sealed drawings for `screen`.
    public static func moments(now: Date, calendar: Calendar) -> [Moment] {
        rows.map { row in
            Moment(hit: Hit(eventId: row.id, tsUs: at(row.daysAgo, row.minutes, now: now, calendar: calendar),
                            appBundleId: row.app, windowTitle: row.title, url: row.url, ocrTextSnippet: row.text,
                            source: "recent", score: nil, sourceKind: row.source, caption: row.caption),
                   screen: row.screen)
        }
        .sorted { $0.hit.tsUs > $1.hit.tsUs }
    }

    private static func ids(_ moments: [Moment], app: String? = nil, titled: String? = nil,
                            caption: String? = nil) -> [UInt64] {
        moments.filter { moment in
            (app.map { moment.hit.appBundleId == $0 } ?? true)
                && (titled.map { moment.hit.windowTitle?.contains($0) == true } ?? true)
                && (caption.map { moment.hit.caption?.contains($0) == true } ?? true)
        }.map(\.hit.id)
    }

    // MARK: The work read

    /// Sam's Working On and Web Pages, as the agent would answer.
    public static func snapshot(now: Date, calendar: Calendar) -> WorkSnapshot {
        let moments = moments(now: now, calendar: calendar)
        let us = { (days: Int, minutes: Int) in at(days, minutes, now: now, calendar: calendar) }
        let shop = ids(moments, titled: "trailhead-shop")
        let figmaIds = ids(moments, titled: "Trailhead pricing v3")
        let q4 = ids(moments, titled: "Q4 planning")
        let checklist = ids(moments, caption: "Launch checklist")
        let draft = ids(moments, caption: "Pricing page draft")
        let invoices = ids(moments, app: numbers)
        let alongsideShop = [
            WorkAlongside(kind: "page", title: "Rounding half to even", host: "devnotes.example", app: chrome,
                          moment: roundingMoment, lastUs: us(0, 875)),
            WorkAlongside(kind: "search", title: "rust round half to even", host: "google.com", app: chrome,
                          moment: 81_118, lastUs: us(0, 678)),
            WorkAlongside(kind: "ai_chat", title: "Asking Claude about rounding modes", host: nil, app: claude,
                          moment: 81_125, lastUs: us(0, 685)),
            WorkAlongside(kind: "page", title: "Currency math without floats", host: "devnotes.example", app: chrome,
                          moment: 83_430, lastUs: us(3, 870)),
            WorkAlongside(kind: "page", title: "Sales tax by state", host: "taxguide.example", app: chrome,
                          moment: 84_507, lastUs: us(4, 907)),
        ]
        let alongsidePricing = [
            WorkAlongside(kind: "page", title: "Per-seat or tiered? How to price a team plan", host: "pricingnotes.example",
                          app: chrome, moment: 81_207, lastUs: us(0, 847)),
            WorkAlongside(kind: "search", title: "per seat vs tiered pricing", host: "google.com", app: chrome,
                          moment: 81_206, lastUs: us(0, 846)),
            WorkAlongside(kind: "page", title: "Pricing \u{00B7} Velo Cycles", host: "velocycles.example", app: chrome,
                          moment: 83_514, lastUs: us(3, 914)),
            WorkAlongside(kind: "page", title: "Plans and pricing \u{00B7} Spoke & Chain", host: "spokeandchain.example",
                          app: chrome, moment: 83_516, lastUs: us(3, 916)),
        ]
        let sessionsShop = [
            WorkSession(startUs: us(0, 845), endUs: us(0, 875)), WorkSession(startUs: us(0, 655), endUs: us(0, 720)),
            WorkSession(startUs: us(3, 930), endUs: us(3, 966)), WorkSession(startUs: us(4, 950), endUs: us(4, 982)),
        ]
        let items = [
            WorkItem(id: trailheadShop, kind: .code, name: "trailhead-shop", apps: [vscode, terminal],
                     lastUs: us(0, 860), weekMinutes: 160, daysThisWeek: 3,
                     files: [
                        WorkFile(name: "tax.rs", lastUs: us(0, 860), moment: taxRsMoment),
                        WorkFile(name: "tax_tests.rs", lastUs: us(0, 719), moment: 82_159),
                        WorkFile(name: "cart.rs", lastUs: us(3, 965), moment: 83_605),
                        WorkFile(name: "money.rs", lastUs: us(4, 980), moment: 84_620),
                        WorkFile(name: "main.rs", lastUs: us(4, 850), moment: 84_620),
                        WorkFile(name: "Cargo.toml", lastUs: us(6, 600), moment: 84_620),
                        WorkFile(name: "README.md", lastUs: us(6, 590), moment: 84_620),
                        WorkFile(name: "discount.rs", lastUs: us(6, 580), moment: 84_620),
                     ],
                     alongside: alongsideShop, folderGuess: "~/dev/trailhead-shop", moments: shop,
                     thumbnailMoment: taxRsMoment, totalMinutes: 640,
                     conversations: [
                        WorkConversation(name: "#launch", app: slack, moment: 81_228, lastUs: us(0, 868)),
                        WorkConversation(name: "#shop-ops", app: slack, moment: 81_004, lastUs: us(0, 568)),
                     ],
                     sessions: sessionsShop),
            WorkItem(id: pricingV3, kind: .design, name: "Trailhead pricing v3", apps: [figma], lastUs: us(0, 826),
                     weekMinutes: 115, daysThisWeek: 3, alongside: alongsidePricing, moments: figmaIds,
                     thumbnailMoment: 81_146, totalMinutes: 230,
                     conversations: [WorkConversation(name: "#design", app: slack, moment: 81_004, lastUs: us(0, 604))],
                     sessions: [WorkSession(startUs: us(0, 590), endUs: us(0, 830))]),
            WorkItem(id: q4Planning, kind: .document, name: "Q4 planning", apps: [chrome], hosts: ["docs.google.com"],
                     lastUs: us(0, 839), weekMinutes: 90, daysThisWeek: 3, alongside: [alongsidePricing[1], alongsidePricing[0]],
                     moments: q4, thumbnailMoment: 81_159, totalMinutes: 150,
                     sessions: [WorkSession(startUs: us(0, 830), endUs: us(0, 845))]),
            WorkItem(id: launchChecklist, kind: .document, name: "Launch checklist", apps: [notes], lastUs: us(0, 814),
                     weekMinutes: 65, daysThisWeek: 4, inSidebar: true, alongside: [alongsideShop[0]],
                     moments: checklist, thumbnailMoment: checklistMoment, totalMinutes: 95,
                     sessions: [WorkSession(startUs: us(0, 794), endUs: us(0, 830))]),
            WorkItem(id: pricingDraft, kind: .document, name: "Pricing page draft", apps: [notes], lastUs: us(0, 638),
                     weekMinutes: 55, daysThisWeek: 2, alongside: Array(alongsidePricing[2...3]), moments: draft,
                     thumbnailMoment: 81_038, totalMinutes: 70),
            WorkItem(id: octoberInvoices, kind: .spreadsheet, name: "October invoices", apps: [numbers], lastUs: us(0, 554),
                     weekMinutes: 35, daysThisWeek: 2, moments: invoices, thumbnailMoment: 80_914, totalMinutes: 35),
            WorkItem(id: mortgage, kind: .spreadsheet, name: "Mortgage refinance", apps: [numbers], lastUs: us(2, 610),
                     weekMinutes: 40, daysThisWeek: 1, inSidebar: false, recent: true, hiddenReason: "personal",
                     totalMinutes: 40),
            WorkItem(id: bikeAPI, kind: .code, name: "bike-api", apps: [cursor], lastUs: us(10, 700), weekMinutes: 0,
                     daysThisWeek: 0, inSidebar: false, folderGuess: "~/dev/bike-api", moments: [bikeAPIMoment],
                     thumbnailMoment: bikeAPIMoment, totalMinutes: 180),
            WorkItem(id: pricingV2, kind: .design, name: "Trailhead pricing v2", apps: [figma], lastUs: us(11, 640),
                     weekMinutes: 0, daysThisWeek: 0, inSidebar: false, moments: [pricingV2Moment],
                     thumbnailMoment: pricingV2Moment, totalMinutes: 130),
        ]
        let giftCard = WorkItem(id: giftCardCopy, kind: .document, name: "Gift card copy", apps: [notes],
                                lastUs: us(3, 545), weekMinutes: 35, daysThisWeek: 1, moments: [giftCardMoment],
                                thumbnailMoment: giftCardMoment, totalMinutes: 35)
        let pages = [
            WorkPage(title: "Rounding half to even", host: "devnotes.example", path: "/rounding", app: chrome, days: 1,
                     lastUs: us(0, 875), moments: [roundingMoment, 81_120]),
            WorkPage(title: "Seat-based pricing: the pros and cons", host: "saasguide.example", path: "/pricing/seats",
                     app: chrome, lastUs: us(0, 849), moments: [81_209]),
            WorkPage(title: "Per-seat or tiered? How to price a team plan", host: "pricingnotes.example",
                     path: "/team-plans", app: chrome, lastUs: us(0, 847), moments: [81_207]),
            WorkPage(title: "Plans and pricing \u{00B7} Spoke & Chain", host: "spokeandchain.example", path: "/plans",
                     app: chrome, lastUs: us(3, 916), moments: [83_516]),
            WorkPage(title: "Pricing \u{00B7} Velo Cycles", host: "velocycles.example", path: "/pricing", app: chrome,
                     lastUs: us(3, 914), moments: [83_514]),
            WorkPage(title: "Currency math without floats", host: "devnotes.example", path: "/currency", app: chrome,
                     lastUs: us(3, 870), moments: [83_430]),
            WorkPage(title: "Sales tax by state", host: "taxguide.example", path: "/states", app: chrome,
                     lastUs: us(4, 907), moments: [84_507]),
        ]
        return WorkSnapshot(generatedUs: UInt64(now.timeIntervalSince1970 * 1_000_000),
                            items: items.prefix(6) + [giftCard] + items.dropFirst(6), pages: pages,
                            momentItems: Dictionary(uniqueKeysWithValues: shop.map { ($0, trailheadShop) }))
    }

    /// The same pages without their addresses: a Mac that never allowed a
    /// browser to say them.
    public static func snapshotWithoutAddresses(now: Date, calendar: Calendar) -> WorkSnapshot {
        let snapshot = snapshot(now: now, calendar: calendar)
        let pages = snapshot.pages.map { page in
            WorkPage(title: page.title, host: nil, path: nil, app: page.app, days: page.days, lastUs: page.lastUs,
                     moments: page.moments)
        }
        return WorkSnapshot(generatedUs: snapshot.generatedUs, items: snapshot.items, pages: pages,
                            momentItems: snapshot.momentItems)
    }

    // MARK: Looked Up

    /// Sam's searches, as `mci-agent searches --json` answers.
    public static func searches(now: Date, calendar: Calendar) -> [SearchRecord] {
        let us = { (days: Int, minutes: Int) in at(days, minutes, now: now, calendar: calendar) }
        return [
            SearchRecord(query: "per seat vs tiered pricing", engine: "google", tsUs: us(0, 846), app: "Chrome",
                         url: "https://www.google.com/search?q=per+seat+vs+tiered+pricing", eventId: 81_206),
            SearchRecord(query: "rust round half to even", engine: "google", tsUs: us(0, 678), app: "Chrome",
                         url: "https://www.google.com/search?q=rust+round+half+to+even", eventId: 81_118),
            SearchRecord(query: "bike shop pricing page examples", engine: "google", tsUs: us(3, 912), app: "Chrome",
                         url: "https://www.google.com/search?q=bike+shop+pricing+page+examples", eventId: 83_512),
            SearchRecord(query: "bike shop pricing page examples", engine: "google", tsUs: us(3, 905), app: "Chrome",
                         url: "https://www.google.com/search?q=bike+shop+pricing+page+examples", eventId: 83_512),
            SearchRecord(query: "Bike shop pricing page examples", engine: "google", tsUs: us(3, 899), app: "Chrome",
                         url: "https://www.google.com/search?q=Bike+shop+pricing+page+examples", eventId: 83_512),
            SearchRecord(query: "sales tax rounding rules by state", engine: "google", tsUs: us(4, 905), app: "Chrome",
                         url: "https://www.google.com/search?q=sales+tax+rounding+rules+by+state", eventId: 84_505),
        ]
    }

    // MARK: Resume

    /// What Resume would open for Sam's items.
    public static func plans(now: Date, calendar: Calendar) -> [String: ResumePlan] {
        let us = { (days: Int, minutes: Int) in at(days, minutes, now: now, calendar: calendar) }
        let shop = ResumePlan(
            items: [
                .init(kind: "folder", title: "trailhead-shop", app: vscode, path: "~/dev/trailhead-shop"),
                .init(kind: "folder", title: "trailhead-shop", app: terminal, path: "~/dev/trailhead-shop"),
                .init(kind: "document", title: "Q4 planning", app: chrome,
                      url: "https://docs.google.com/document/d/q4-planning/edit"),
                .init(kind: "document", title: "Launch checklist", app: notes, reason: "single_note"),
                .init(kind: "page", title: "Rounding half to even", app: chrome, url: "https://devnotes.example/rounding"),
                .init(kind: "page", title: "Seat-based pricing: the pros and cons", app: chrome,
                      url: "https://saasguide.example/pricing/seats"),
                .init(kind: "page", title: "Per-seat or tiered? How to price a team plan", app: chrome,
                      url: "https://pricingnotes.example/team-plans"),
                .init(kind: "page", title: "Currency math without floats", app: chrome,
                      url: "https://devnotes.example/currency"),
                .init(kind: "page", title: "A page read without its address", app: safari, checked: false,
                      reason: "no_address"),
                .init(kind: "app", title: "Slack", app: slack),
                .init(kind: "app", title: "Claude", app: claude),
            ],
            item: .init(name: "trailhead-shop", kind: "code"),
            session: .init(startUs: us(0, 845), endUs: us(0, 875)))
        let checklist = ResumePlan(
            items: [
                .init(kind: "document", title: "Launch checklist", app: notes, reason: "single_note"),
                .init(kind: "page", title: "Rounding half to even", app: chrome, url: "https://devnotes.example/rounding"),
            ],
            item: .init(name: "Launch checklist", kind: "document"),
            session: .init(startUs: us(0, 794), endUs: us(0, 830)))
        return [trailheadShop: shop, launchChecklist: checklist]
    }

    // MARK: Calendar

    /// Sam's calendar today and Friday: titles and times only.
    public static func calendarEvents(now: Date, calendar: Calendar) -> [CalendarEvent] {
        let date = { (days: Int, minutes: Int) in
            Date(timeIntervalSince1970: Double(at(days, minutes, now: now, calendar: calendar)) / 1_000_000)
        }
        return [
            CalendarEvent(id: "ev-standup", title: "Team sync", start: date(0, 840), end: date(0, 855),
                          calendarName: "Work"),
            CalendarEvent(id: "ev-review", title: "Pricing review", start: date(0, 600), end: date(0, 630),
                          calendarName: "Work"),
            CalendarEvent(id: "ev-tax", title: "Checkout tax pairing", start: date(3, 935), end: date(3, 965),
                          calendarName: "Work"),
        ]
    }
}
