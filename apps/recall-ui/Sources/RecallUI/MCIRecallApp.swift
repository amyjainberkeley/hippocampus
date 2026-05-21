// MCIRecallApp.swift — SwiftUI @main scene for the MCI recall-ui v1.
//
// P3.9a wires the `StubBrainReader` so the views render canned data
// out of the box (and the unit-test surface is the binding contract,
// not the SwiftUI rendering). P3.9b swaps in `FFIBrainReader` against
// a real read-only SQLCipher brain at
// `~/Library/Application Support/MCI/mci.sqlite`.

import SwiftUI
import RecallUIKit

@main
struct MCIRecallApp: App {
    /// Single shared reader for the whole app session. Swapped to
    /// `FFIBrainReader` in P3.9b. `@MainActor` injection — every view
    /// model is constructed on the main actor.
    @MainActor
    private static let reader: BrainReader = StubBrainReader()

    var body: some Scene {
        WindowGroup("MCI Recall") {
            RootView(reader: MCIRecallApp.reader)
                .frame(minWidth: 720, minHeight: 480)
        }
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
