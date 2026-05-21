import AppKit
import RecallUIKit
import SwiftUI

@main
struct MCIRecallApp: App {
    @MainActor
    private static let reader: BrainReader = Self.makeReader()

    var body: some Scene {
        WindowGroup("Hippocampus Recall") {
            RootView(reader: MCIRecallApp.reader)
                .frame(minWidth: 720, minHeight: 480)
                .background(Color.brandBgPrimary)
                .preferredColorScheme(.dark)
        }
    }

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
            return StubBrainReader()
        }
    }

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

enum Tab: Int, Hashable {
    case search = 1
    case timeline = 2
    case privacy = 3
}

struct RootView: View {
    let reader: BrainReader
    @State private var selectedTab: Tab = .search
    @State private var searchFocusTrigger = false

    var body: some View {
        TabView(selection: $selectedTab) {
            SearchView(
                viewModel: SearchViewModel(reader: reader),
                focusTrigger: searchFocusTrigger
            )
            .tag(Tab.search)
            .tabItem { Label("Search", systemImage: "magnifyingglass") }

            TimelineView(viewModel: TimelineViewModel(reader: reader))
                .tag(Tab.timeline)
                .tabItem { Label("Timeline", systemImage: "clock") }

            PrivacyMomentsView(
                viewModel: PrivacyMomentsViewModel(reader: reader)
            )
            .tag(Tab.privacy)
            .tabItem { Label("Privacy Moments", systemImage: "eye.slash") }
        }
        .padding(.top, 6)
        .background(Color.brandBgPrimary)
        .focusable()
        .onKeyPress(keys: [.init("1"), .init("2"), .init("3")], phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            switch press.key {
            case KeyEquivalent("1"): selectedTab = .search
            case KeyEquivalent("2"): selectedTab = .timeline
            case KeyEquivalent("3"): selectedTab = .privacy
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress(.init("f"), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            selectedTab = .search
            searchFocusTrigger.toggle()
            return .handled
        }
    }
}
