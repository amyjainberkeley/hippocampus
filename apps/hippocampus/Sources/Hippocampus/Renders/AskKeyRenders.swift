#if DEBUG
import AppKit
import Combine
import HippocampusKit
import SwiftUI

extension StatusPreviewRenderer {
    /// Preferences › General with Fn (Globe) as the key that opens Ask
    /// (SPEC-DELTA 7), light and dark: Fn listening, Fn waiting while Wispr
    /// Flow uses it, Fn waiting on macOS's own Globe key setting, and a
    /// keyboard without Fn (`prefs-key-picker-*`). Drawn with every other
    /// picture by `HIPPOCAMPUS_RENDER_BAR`, from fixtures: nothing lists
    /// this Mac's apps, reads its keyboard setting or its keyboards, and
    /// nothing reads or writes the person's settings.
    static var askKeyPanes: [Pane] {
        let wispr = FnKeyCheck(hasFnKey: true, appsUsingFn: ["Wispr Flow"], globeAction: .doNothing)
        let globe = FnKeyCheck(hasFnKey: true, appsUsingFn: [], globeAction: .showEmojiAndSymbols)
        let noKey = FnKeyCheck(hasFnKey: false, appsUsingFn: [], globeAction: .doNothing)
        let both = FnKeyCheck(hasFnKey: true, appsUsingFn: ["Wispr Flow", "Superwhisper"], globeAction: .changeInputSource)
        var panes: [Pane] = []
        for (name, check) in [("key-picker-fn", FnKeyCheck.clear), ("key-picker-fn-conflict-wispr", wispr),
                              ("key-picker-fn-globe-setting", globe)] {
            panes.append(Pane(name: name, view: AnyView(AskKeyPicture(check: check, dark: false))))
            panes.append(Pane(name: "\(name)-dark", view: AnyView(AskKeyPicture(check: check, dark: true))))
        }
        panes.append(Pane(name: "key-picker-fn-no-key", view: AnyView(AskKeyPicture(check: noKey, dark: false))))
        panes.append(Pane(name: "key-picker-fn-two-apps-and-globe", view: AnyView(AskKeyPicture(check: both, dark: false))))
        panes.append(Pane(name: "key-picker-fn-no-accessibility",
                          view: AnyView(AskKeyPicture(check: wispr, dark: false, trusted: false))))
        panes.append(Pane(name: "key-picker-menu", view: AnyView(KeyMenuFacsimile())))
        return panes
    }
}

/// Preferences › General as it draws the key picker, fed fixtures: the
/// store in memory, and a watch whose checks are `check`.
private struct AskKeyPicture: View {
    let check: FnKeyCheck
    let dark: Bool
    var trusted = true

    var body: some View {
        Appearance(dark: dark) {
            VStack(alignment: .leading, spacing: 16) {
                Text("General")
                    .font(.system(size: 17, weight: .semibold))
                Toggle("Open at login", isOn: .constant(true))
                AskKeyPicker(store: Self.store(), askKey: Self.watch(check, trusted: trusted))
            }
            .padding(24)
            .frame(width: 560, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// A store that keeps Fn in memory only.
    @MainActor static func store() -> PreferencesStore {
        let retention = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-key-picture-\(UUID().uuidString)/retention.json")
        let store = PreferencesStore(defaults: PictureDefaults(), retentionURL: retention)
        store.askKey = .fn
        return store
    }

    /// A watch on Fn whose monitor is a no-op, its checks `check`.
    @MainActor static func watch(_ check: FnKeyCheck, trusted: Bool) -> AskKeyWatch {
        let watch = AskKeyWatch(hooks: AskKeyWatch.Hooks(
            isTrusted: { trusted }, install: { _ in true }, uninstall: {},
            after: { _, _ in AnyCancellable {} }, fnCheck: { check }
        ))
        watch.setFallbackRegistered(true)
        watch.start(key: .fn)
        return watch
    }
}

/// The picker's menu, open, as a labelled facsimile: a menu can't be drawn
/// off screen. Fn (Globe) is second, after Shift twice.
private struct KeyMenuFacsimile: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Facsimile of the Open Ask with menu")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(SoloKey.allCases) { key in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .opacity(key == .fn ? 1 : 0)
                        Text(key.label).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(key == .fn ? Color.accentColor.opacity(0.85) : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(key == .fn ? Color.white : Color.primary)
                }
            }
            .padding(5)
            .frame(width: 200, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.97)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
        }
        .padding(24)
        .frame(width: 560, alignment: .topLeading)
    }
}

/// Draws its content in light or dark whatever the picture around it: a
/// hosting view of its own, with its own appearance, so AppKit's controls
/// follow too.
private struct Appearance<Content: View>: NSViewRepresentable {
    let dark: Bool
    let content: Content

    init(dark: Bool, @ViewBuilder content: () -> Content) {
        self.dark = dark
        self.content = content()
    }

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: AnyView(content.environment(\.colorScheme, dark ? .dark : .light)))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return hosting
    }

    func updateNSView(_ nsView: NSHostingView<AnyView>, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<AnyView>, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}

/// Settings kept in memory for a picture: nothing reaches the person's
/// defaults or leaves a file behind.
private final class PictureDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
}
#endif
