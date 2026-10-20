// HippocampusURLRoute.swift — pure parser for the `hippocampus://`
// URL scheme. Kept in HippocampusKit (not the executable target) so
// the routing decisions are unit-testable without spinning up an
// NSApplication.
//
// The executable target's `AppDelegate.application(_:open:)` calls
// `HippocampusURLRoute.parse(url)` and dispatches on the returned
// enum. That's the sole responsibility of this type — the actual
// side effects (opening Recall, spawning Onboarding) live in the
// AppDelegate where they belong.
//
// Supported routes (as of cycle 8.48):
//   - `hippocampus://recall`                     → open Recall
//   - `hippocampus://recall?tab=brief`           → open the Briefs workspace
//   - `hippocampus://recall?popup=1`             → reveal global Recall
//   - `hippocampus://recall?tab=search&focus=42` → inspect event 42
//   - `hippocampus://preferences/sources`       → open a preferences pane
//   - `hippocampus://ask`                        → open the command bar
//   - `hippocampus://ask?q=what+did+I+decide`    → …and ask right away
//   - `hippocampus://resume?item=w_9c41e2`       → the window on a Working On
//     item with Resume's sheet over it (SPEC-DELTA 3); nothing opens until
//     the person clicks in the sheet
//   - `hippocampus://restart`                    → restart remembering in place
//     (setup's Try it, "Try Again"; onboarding-app contract section 3b)
//   - `hippocampus://onboarding/show`            → .showOnboarding
//   - `hippocampus://onboarding?show=1`          → .showOnboarding
//     (both forms honored — the cycle 8.46 Action Panel command
//     initially shipped the `?show=1` short-form; cycle 8.48
//     standardizes on the path form to match Raycast-style URLs.)

import Foundation

/// Shared by URL routing and the preferences toolbar. Raw values preserve
/// the existing toolbar identifiers; canonical URL paths are lowercase.
public enum PreferencesSection: String, CaseIterable, Identifiable, Sendable {
    case general = "General"
    case capture = "Capture"
    case sources = "Sources"
    case privacy = "Privacy"
    case advanced = "Advanced"
    case about = "About"

    public var id: String { rawValue }

    /// The name a person reads (spec-copy S4.4); the raw value stays the
    /// link and toolbar identifier.
    public var label: String {
        switch self {
        case .general: "General"
        case .capture: "Remembering"
        case .sources: "AI Tools"
        case .privacy: "Privacy"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }
}

public enum HippocampusURLRoute: Equatable, Sendable {
    /// Open or command the Recall UI. Invalid and zero event ids are ignored.
    case openRecall(tab: String?, focusEventId: UInt64?, openPopup: Bool)
    /// Display an existing preferences pane. Never applies settings or consent.
    case openPreferences(section: PreferencesSection)
    /// Re-open the Onboarding executable (safe to call post-first-run).
    case showOnboarding
    /// Open the command bar, optionally asking `question` right away.
    case ask(question: String?)
    /// Restart remembering in place, as the menu's Try Again does. Never
    /// quits the app: setup, which asked, exits with it.
    case restartRemembering
    /// Open the window on a Working On item, by its id, with Resume's sheet
    /// over it. The sheet lists what would open; nothing opens until the
    /// person clicks in it, and nothing is sent anywhere.
    case resume(item: String)
    /// URL scheme matched, but the host / path combination is unknown.
    /// Callers should log-and-ignore rather than throw.
    case unknown

    /// Parse a `hippocampus://…` URL into a route. Returns `nil` for
    /// URLs outside the scheme (e.g. `http://` or `onboarding://` —
    /// AppKit may hand us anything registered against our bundle).
    public static func parse(_ url: URL) -> HippocampusURLRoute? {
        guard url.scheme == "hippocampus" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        switch url.host {
        case "recall":
            let tab = queryItems.first(where: { $0.name == "tab" })?.value
            let focusEventId = queryItems
                .first(where: { $0.name == "focus" })?.value
                .flatMap(UInt64.init)
                .flatMap { $0 == 0 ? nil : $0 }
            let openPopup = queryItems.contains {
                $0.name == "popup" && $0.value == "1"
            }
            return .openRecall(
                tab: tab,
                focusEventId: focusEventId,
                openPopup: openPopup
            )
        case "preferences":
            // Accept only the six canonical URLs, not decoded aliases,
            // credentials, ports, queries, fragments, or extra path components.
            guard let section = PreferencesSection.allCases.first(where: {
                url.absoluteString == "hippocampus://preferences/\($0.rawValue.lowercased())"
            }) else { return .unknown }
            return .openPreferences(section: section)
        case "ask":
            let question = queryItems.first(where: { $0.name == "q" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .ask(question: question?.isEmpty == false ? question : nil)
        case "restart":
            // Exact match only, like the preferences route.
            return url.absoluteString == "hippocampus://restart" ? .restartRemembering : .unknown
        case "resume":
            // Exactly one item id and nothing else: no path, credentials,
            // port, fragment or other query. Ids, never names, travel in links.
            guard let components, components.user == nil, components.password == nil,
                  components.port == nil, components.path.isEmpty, components.fragment == nil,
                  queryItems.count == 1, queryItems[0].name == "item",
                  let item = queryItems[0].value, isWorkItemId(item)
            else { return .unknown }
            return .resume(item: item)
        case "onboarding":
            let showQuery = queryItems.first(where: { $0.name == "show" })?.value
            if url.path == "/show" || showQuery == "1" {
                return .showOnboarding
            }
            return .unknown
        default:
            return .unknown
        }
    }

    /// The longest id a Working On item can have.
    public static let maxWorkItemIdLength = 64

    /// Whether `id` has the shape of a Working On item's id: 1 to 64 ASCII
    /// letters, digits, `_` and `-`, not starting with `-` (the agent's
    /// `work::is_item_id`, and RecallUIKit's `RecallLaunchRequest`). A name
    /// never passes.
    public static func isWorkItemId(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= maxWorkItemIdLength && !id.hasPrefix("-")
            && id.utf8.allSatisfy { byte in
                (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                    || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte == 0x2D
            }
    }

    /// How Resume for `item` is asked of the window: as the tab
    /// `resume:<id>`, which RecallUIKit's `RecallLaunchRequest` reads at
    /// launch and in a command to a window that is open.
    public static func resumeTab(item: String) -> String {
        "resume:\(item)"
    }
}
