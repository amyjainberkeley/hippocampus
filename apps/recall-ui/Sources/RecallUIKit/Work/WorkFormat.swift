import Foundation

/// How Working On says what it knows: kinds, the places an item was worked
/// in, its time, and when it was last worked on, formatted on this Mac
/// (RULINGS I4) in the person's calendar.
public enum WorkFormat {
    /// "Code project", "Document", "Design", "Spreadsheet".
    public static func kindLabel(_ kind: WorkItem.Kind) -> String {
        switch kind {
        case .code: WorkCopy.codeProject
        case .document: WorkCopy.document
        case .design: WorkCopy.design
        case .spreadsheet: WorkCopy.spreadsheet
        }
    }

    /// The kind's SF Symbol, drawn monochrome (SPEC 2.2).
    public static func symbol(_ kind: WorkItem.Kind) -> String {
        switch kind {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .document: "doc.text"
        case .design: "paintbrush.pointed"
        case .spreadsheet: "tablecells"
        }
    }

    /// A length of time the way Screen Time writes it: "2 hr 40 min",
    /// "55 min", "3 hr". Never under a minute.
    public static func duration(minutes: Int) -> String {
        let minutes = max(1, minutes)
        let hours = minutes / 60
        let rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) hr"
        default: return "\(hours) hr \(rest) min"
        }
    }

    /// A site's own name, for a document worked on in a browser.
    public static func siteName(host: String, kind: WorkItem.Kind) -> String? {
        let host = host.lowercased().hasPrefix("www.") ? String(host.lowercased().dropFirst(4)) : host.lowercased()
        func on(_ site: String) -> Bool { host == site || host.hasSuffix("." + site) }
        if on("docs.google.com") { return kind == .spreadsheet ? "Google Sheets" : "Google Docs" }
        if on("sheets.google.com") { return "Google Sheets" }
        if on("figma.com") { return "Figma" }
        if on("canva.com") { return "Canva" }
        if on("notion.so") || on("notion.site") { return "Notion" }
        if on("coda.io") { return "Coda" }
        if on("quip.com") { return "Quip" }
        if on("paper.dropbox.com") { return "Dropbox Paper" }
        return nil
    }

    /// The names of what an item was worked in, most time first: a site's
    /// name for a document on the web ("Google Docs"), else its apps'.
    public static func places(_ item: WorkItem, appName: (String) -> String = Formatters.appDisplayName) -> [String] {
        var names: [String] = item.hosts.compactMap { siteName(host: $0, kind: item.kind) }
        for app in item.apps where !Self.isBrowser(app) || names.isEmpty {
            let name = appName(app)
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// For an item's header: "VS Code and Terminal", "Google Docs in
    /// Chrome", "Figma".
    public static func placesSentence(_ item: WorkItem,
                                      appName: (String) -> String = Formatters.appDisplayName) -> String {
        if let site = item.hosts.compactMap({ siteName(host: $0, kind: item.kind) }).first,
           let browser = item.apps.first(where: Self.isBrowser) {
            return "\(site) in \(appName(browser))"
        }
        let names = places(item, appName: appName)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }

    /// For a list or card: "VS Code, Terminal", "Google Docs".
    public static func placesList(_ item: WorkItem, appName: (String) -> String = Formatters.appDisplayName) -> String {
        places(item, appName: appName).prefix(3).joined(separator: ", ")
    }

    static func isBrowser(_ app: String) -> Bool {
        [
            "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta",
            "com.google.Chrome.dev", "com.google.Chrome.canary", "org.chromium.Chromium",
            "company.thebrowser.Browser", "company.thebrowser.dia", "com.brave.Browser", "com.microsoft.edgemac",
            "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS",
            "app.zen-browser.zen",
        ].contains(app)
    }

    /// When something was, in a sentence: "today at 2:20 PM", "yesterday at
    /// 6:12 PM", "Friday at 4:05 PM" within the week, "Oct 2 at 4:05 PM"
    /// within the year, else "Oct 2, 2025".
    public static func when(us: UInt64, now: Date, calendar: Calendar) -> String {
        let date = Date(timeIntervalSince1970: Double(us) / 1_000_000)
        let time = clock(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: now)).day, days > 0, days < 7 {
            return "\(format(date, "EEEE", calendar)) at \(time)"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return "\(format(date, "MMM d", calendar)) at \(time)"
        }
        return format(date, "MMM d, yyyy", calendar)
    }

    /// When something was, short, for a column or a card: "Today 2:20 PM",
    /// "Yesterday 6:12 PM", "Fri 4:05 PM", "Oct 2".
    public static func whenShort(us: UInt64, now: Date, calendar: Calendar) -> String {
        let date = Date(timeIntervalSince1970: Double(us) / 1_000_000)
        let time = clock(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return "\(WorkCopy.today) \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "\(WorkCopy.yesterday) \(time)"
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: now)).day, days > 0, days < 7 {
            return "\(format(date, "EEE", calendar)) \(time)"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return format(date, "MMM d", calendar)
        }
        return format(date, "MMM d, yyyy", calendar)
    }

    /// A list row's time: "2:35 PM" today, else "Fri 3:16 PM" or "Oct 2".
    public static func rowTime(us: UInt64, now: Date, calendar: Calendar) -> String {
        let date = Date(timeIntervalSince1970: Double(us) / 1_000_000)
        return calendar.isDate(date, inSameDayAs: now) ? clock(date, calendar: calendar)
            : whenShort(us: us, now: now, calendar: calendar)
    }

    /// A clock time in the person's format: "2:20 PM".
    public static func clock(_ date: Date, calendar: Calendar) -> String {
        Formatters.clockTime(us: Int64((date.timeIntervalSince1970 * 1_000_000).rounded()),
                             locale: calendar.locale ?? .autoupdatingCurrent, timeZone: calendar.timeZone)
    }

    private static func format(_ date: Date, _ template: String, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// The sidebar's tooltip for an item.
    public static func tooltip(_ item: WorkItem, now: Date, calendar: Calendar) -> String {
        WorkCopy.itemTooltip(name: item.name, when: when(us: item.lastUs, now: now, calendar: calendar))
    }

    /// What VoiceOver reads for an item in the sidebar.
    public static func accessibilityLabel(_ item: WorkItem, now: Date, calendar: Calendar) -> String {
        let date = Date(timeIntervalSince1970: Double(item.lastUs) / 1_000_000)
        let when = calendar.isDate(date, inSameDayAs: now)
            ? clock(date, calendar: calendar) : Self.when(us: item.lastUs, now: now, calendar: calendar)
        return WorkCopy.itemAccessibility(name: item.name, kind: kindLabel(item.kind), when: when)
    }

    /// An item's time, as Show All and its page say it: this week's, or in
    /// all for one from before.
    public static func time(_ item: WorkItem) -> String {
        item.weekMinutes > 0
            ? duration(minutes: item.weekMinutes)
            : duration(minutes: max(item.totalMinutes, item.weekMinutes))
    }

    /// The second line of an item's header: "On 3 days this week · 2 hr 40
    /// min", or "3 hr in all" for one from before this week.
    public static func weekLine(_ item: WorkItem) -> String {
        if item.daysThisWeek > 0, item.weekMinutes > 0 {
            return "\(WorkCopy.onDaysThisWeek(item.daysThisWeek)) \u{00B7} \(duration(minutes: item.weekMinutes))"
        }
        return WorkCopy.inAllTime(duration(minutes: max(1, item.totalMinutes)))
    }

    /// The first line of an item's header: "Code project · VS Code and
    /// Terminal · Last worked on today at 2:20 PM".
    public static func headerLine(_ item: WorkItem, now: Date, calendar: Calendar,
                                  appName: (String) -> String = Formatters.appDisplayName) -> String {
        [kindLabel(item.kind), placesSentence(item, appName: appName),
         WorkCopy.lastWorkedOn(when(us: item.lastUs, now: now, calendar: calendar))]
            .filter { !$0.isEmpty }
            .joined(separator: " \u{00B7} ")
    }
}
