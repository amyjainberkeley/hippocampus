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
//   - `hippocampus://recall`                     → .openRecall(tab: nil)
//   - `hippocampus://recall?tab=brief`           → .openRecall(tab: "brief")
//   - `hippocampus://recall?popup=1`             → .openRecall(tab: nil)
//     (the popup=1 flag is consumed by the recall-ui process itself
//     via its own `.onOpenURL` in MCIRecallApp; from HippocampusApp's
//     perspective we still spawn the recall UI.)
//   - `hippocampus://onboarding/show`            → .showOnboarding
//   - `hippocampus://onboarding?show=1`          → .showOnboarding
//     (both forms honored — the cycle 8.46 Action Panel command
//     initially shipped the `?show=1` short-form; cycle 8.48
//     standardizes on the path form to match Raycast-style URLs.)

import Foundation

public enum HippocampusURLRoute: Equatable, Sendable {
    /// Open the Recall UI, optionally with an initial tab hint.
    case openRecall(tab: String?)
    /// Re-open the Onboarding executable (safe to call post-first-run).
    case showOnboarding
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
            return .openRecall(tab: tab)
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
}
