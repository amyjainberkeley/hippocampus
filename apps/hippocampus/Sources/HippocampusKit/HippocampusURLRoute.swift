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
//   - `hippocampus://onboarding/show`            → .showOnboarding
//   - `hippocampus://onboarding?show=1`          → .showOnboarding
//     (both forms honored — the cycle 8.46 Action Panel command
//     initially shipped the `?show=1` short-form; cycle 8.48
//     standardizes on the path form to match Raycast-style URLs.)

import Foundation

public enum HippocampusURLRoute: Equatable, Sendable {
    /// Open or command the Recall UI. Invalid and zero event ids are ignored.
    case openRecall(tab: String?, focusEventId: UInt64?, openPopup: Bool)
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
