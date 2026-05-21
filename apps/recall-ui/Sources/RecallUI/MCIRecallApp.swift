// MCIRecallApp.swift — SwiftUI @main scene for the MCI recall-ui v1.
//
// # P3.9b — FFIBrainReader wired against the real read-only brain
//
// The reader now opens `~/Library/Application Support/MCI/mci.sqlite` with
// the SQLCipher key from the `MCI_DB_KEY_HEX` environment variable. If
// the env var is missing OR the open fails (no DB yet, wrong key, file
// missing), the app falls back to `StubBrainReader` so the SwiftUI views
// still have something to render — the user sees the canned demo corpus
// instead of an empty window or a crashed app.
//
// # TODO — Keychain integration (P4.6 retention work or follow-on)
//
// The env-var key source is a developer-mode demo handle. The production
// key path per ADR-0008 is the macOS Keychain (Secure-Enclave-wrapped,
// biometric-controlled, non-exportable). When that adapter lands in
// `adapters/macos/` (currently behind the `KeyWrap` trait in `mci-core`),
// this site swaps `MCI_DB_KEY_HEX` for a Keychain lookup. The trust-
// boundary moment is CSO-gated.

import SwiftUI
import RecallUIKit

@main
struct MCIRecallApp: App {
    /// Single shared reader for the whole app session. Constructed once
    /// at process start; the `@MainActor` annotation pins construction
    /// to the main actor (every view model is built on it).
    @MainActor
    private static let reader: BrainReader = Self.makeReader()

    var body: some Scene {
        WindowGroup("MCI Recall") {
            RootView(reader: MCIRecallApp.reader)
                .frame(minWidth: 720, minHeight: 480)
        }
    }

    /// Construct the production `FFIBrainReader` if a real brain exists +
    /// the env-var key is set, else fall back to `StubBrainReader` so the
    /// UI is still rendered. The fallback is dev-mode only; once the
    /// Keychain integration lands the env-var path goes away.
    @MainActor
    private static func makeReader() -> BrainReader {
        guard let keyHex = ProcessInfo.processInfo.environment["MCI_DB_KEY_HEX"],
              !keyHex.isEmpty
        else {
            return StubBrainReader()
        }
        do {
            return try FFIBrainReader(path: defaultBrainPath(), keyHex: keyHex)
        } catch {
            // Open failed (file missing, wrong key, etc.) — fall back to
            // the stub so the SwiftUI scenes still render. A future
            // onboarding UX (Phase 4 P4.2) surfaces this as a banner.
            return StubBrainReader()
        }
    }

    /// Canonical brain path: `~/Library/Application Support/MCI/mci.sqlite`.
    /// Matches ADR-0008's app-support-dir convention.
    @MainActor
    private static func defaultBrainPath() -> String {
        let supportDir = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory,
            .userDomainMask,
            true
        ).first ?? NSTemporaryDirectory()
        return (supportDir as NSString)
            .appendingPathComponent("MCI/mci.sqlite")
    }
}

struct RootView: View {
    let reader: BrainReader

    var body: some View {
        TabView {
            SearchView(viewModel: SearchViewModel(reader: reader))
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            TimelineView(viewModel: TimelineViewModel(reader: reader))
                .tabItem { Label("Timeline", systemImage: "clock") }
            PrivacyMomentsView(
                viewModel: PrivacyMomentsViewModel(reader: reader)
            )
            .tabItem {
                Label("Privacy Moments", systemImage: "eye.slash")
            }
        }
        .padding(.top, 6)
    }
}
