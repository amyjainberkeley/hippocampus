// SPDX-License-Identifier: TBD-private
//
// PreferencesWindow — the comprehensive Preferences surface.
//
// A proper Mac-native Preferences window (like Xcode / Slack / Cotypist)
// invoked via ⌘, from anywhere — the menu-bar drop-down, the recall UI,
// even the onboarding flow. Distinct from the Settings tab inside the
// recall UI (which is a per-window preferences pane the recall-ui
// package owns); this is the app-level surface.
//
// Layout:
//   - NSPanel host (borderless-titled, non-modal, floating) with
//     `contentView` set to an `NSHostingView` wrapping the SwiftUI root.
//   - NSToolbar with five selectable items (General / Capture / Privacy
//     / Advanced / About). Toolbar switching is the same pattern
//     Xcode and Slack use; feels native.
//   - Each section is a compact SwiftUI `Form` bound directly to the
//     `PreferencesStore` (`@ObservedObject`, so toggling writes
//     immediately to UserDefaults via the store's didSet observers).
//
// Singleton lifecycle:
//   - The panel is created lazily on first ⌘, and cached on the
//     coordinator so subsequent ⌘, focuses the existing window
//     rather than opening a stack of duplicates. Closing hides but
//     does not destroy — next open is instant.
//
// Design tokens: mirrors the `MCIDesignSystem` (RecallUIKit) values
// for spacing + typography without importing that package (which
// would drag in the Rust FFI link path — the Hippocampus executable
// stays FFI-free by design). Hex + spacing constants are pinned in
// PreferencesStyle below; a future refactor can bridge the two if
// design-token drift becomes a problem.
//
// About every preference we render, defaults MUST match current
// behavior — a first-run user who never opens Preferences sees zero
// behavior change. Every write goes through the store's `@Published`
// setters which persist to UserDefaults synchronously.

import SwiftUI
import HippocampusKit
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Style tokens

/// A small mirror of the `MCIDesignSystem` (RecallUIKit) spacing and
/// typography constants — inlined here so the Hippocampus executable
/// stays FFI-free. Values match `MCI.Spacing` + `MCI.Font` verbatim so
/// the Preferences window feels visually identical to the recall UI
/// once both surfaces adopt the tokens.
enum PreferencesStyle {
    static let sectionSpacing: CGFloat = 16    // MCI.Spacing.l
    static let rowSpacing: CGFloat = 12        // MCI.Spacing.m
    static let controlSpacing: CGFloat = 8     // MCI.Spacing.s
    static let contentPadding: CGFloat = 24    // MCI.Spacing.xl
    static let sectionTitleFont: Font = .system(size: 17, weight: .semibold)
    static let bodyFont: Font = .system(size: 14, weight: .regular)
    static let captionFont: Font = .system(size: 12, weight: .regular)
    static let panelWidth: CGFloat = 560
    static let panelHeight: CGFloat = 460
}

// MARK: - Section enum

/// The five top-level tabs. The rawValue is the NSToolbar item
/// identifier — matched in the AppKit shim below.
enum PreferencesSection: String, CaseIterable, Identifiable {
    case general = "General"
    case capture = "Capture"
    case privacy = "Privacy"
    case advanced = "Advanced"
    case about = "About"

    var id: String { rawValue }

    /// SF-Symbol icon rendered in the toolbar item.
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .capture: return "camera.viewfinder"
        case .privacy: return "hand.raised"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Root view

struct PreferencesRootView: View {
    @ObservedObject var store: PreferencesStore
    @Binding var section: PreferencesSection
    @ObservedObject var loginItemVM: LoginItemViewModel
    let updater: SparkleUpdaterService
    let dbPath: String
    let onOpenRecallTab: (String) -> Void
    let onOpenDenylistEditor: () -> Void
    let onOpenAllowlistEditor: () -> Void
    let onExportDebugBundle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                sectionContent
                    .padding(PreferencesStyle.contentPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: PreferencesStyle.panelWidth, height: PreferencesStyle.panelHeight)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .general: generalSection
        case .capture: captureSection
        case .privacy: privacySection
        case .advanced: advancedSection
        case .about: aboutSection
        }
    }

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: PreferencesStyle.sectionSpacing) {
            sectionHeader("General")

            Toggle("Launch at login", isOn: Binding(
                get: { loginItemVM.isEnabled },
                set: { _ in loginItemVM.toggle() }
            ))
            Text("Hippocampus will start automatically when you log in.")
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)

            Toggle("Show menu-bar icon", isOn: $store.showMenuBarIcon)
            Text("If off, only ⇧⌘Space (Recall popup) remains as an entry point. Restart to apply.")
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)

            Picker("Default view when opening recall UI", selection: $store.defaultRecallTab) {
                ForEach(PreferredRecallTab.allCases, id: \.self) { tab in
                    Text(tab.displayLabel).tag(tab)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: Capture

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: PreferencesStyle.sectionSpacing) {
            sectionHeader("Capture")

            HStack {
                Text("V2-P1 recording engine")
                Spacer()
                Text(v2p1Status)
                    .font(PreferencesStyle.captionFont)
                    .foregroundStyle(.secondary)
            }
            Text("Controlled by the HIPPOCAMPUS_ENABLE_V2P1 environment variable (PR #101).")
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Screen recording enabled", isOn: Binding(
                get: { !UserPauseController.shared.isPaused },
                set: { on in UserPauseController.shared.setPaused(!on) }
            ))
            Text("Same as menu-bar Pause. When off, the helper is suspended (SIGSTOP).")
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)

            Divider()

            Text("Deep-hook plugins")
                .font(.system(size: 13, weight: .semibold))
            ForEach(PreferencesStore.deepHookPluginOrder, id: \.self) { name in
                Toggle(name, isOn: pluginBinding(name))
            }
        }
    }

    private func pluginBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { store.deepHookPlugins[name] ?? false },
            set: { store.deepHookPlugins[name] = $0 }
        )
    }

    private var v2p1Status: String {
        (ProcessInfo.processInfo.environment["HIPPOCAMPUS_ENABLE_V2P1"] == "1")
            ? "Enabled"
            : "Disabled (default)"
    }

    // MARK: Privacy

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: PreferencesStyle.sectionSpacing) {
            sectionHeader("Privacy")

            Button("Open denylist editor…") { onOpenDenylistEditor() }
            Button("Open allowlist editor…") { onOpenAllowlistEditor() }

            Divider()

            Picker("Retention policy", selection: $store.retentionPolicy) {
                ForEach(RetentionPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayLabel).tag(policy)
                }
            }
            .pickerStyle(.menu)
            Text("Older events are pruned automatically. Default: forever (no pruning).")
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)

            Divider()

            Button("Open Privacy Dashboard (⌘7)") {
                onOpenRecallTab("privacy")
            }
            Button("View recent activity (audit log)") {
                onOpenRecallTab("privacy")
            }
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: PreferencesStyle.sectionSpacing) {
            sectionHeader("Advanced")

            Toggle("Automatic updates (Sparkle)", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))

            Divider()

            VStack(alignment: .leading, spacing: PreferencesStyle.controlSpacing) {
                Text("Ollama endpoint (optional)")
                TextField("http://localhost:11434", text: $store.ollamaEndpoint)
                    .textFieldStyle(.roundedBorder)
                Text("BYOK local-LLM endpoint for brief authoring. Empty = use bundled Qwen3.")
                    .font(PreferencesStyle.captionFont)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: PreferencesStyle.controlSpacing) {
                Text("Custom database path (optional)")
                TextField(dbPath, text: $store.customDatabasePath)
                    .textFieldStyle(.roundedBorder)
                Text("Requires restart. Default: \(dbPath)")
                    .font(PreferencesStyle.captionFont)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Export debug bundle…") { onExportDebugBundle() }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: PreferencesStyle.sectionSpacing) {
            sectionHeader("About Hippocampus")

            let info = Bundle.main.infoDictionary ?? [:]
            let version = info["CFBundleShortVersionString"] as? String ?? "0.1.0"
            let build = info["CFBundleVersion"] as? String ?? "1"
            let sha = info["MCIGitSHA"] as? String ?? "dev"

            VStack(alignment: .leading, spacing: 4) {
                Text("Version \(version) (\(build))")
                    .font(PreferencesStyle.sectionTitleFont)
                Text("Git SHA: \(sha)")
                    .font(PreferencesStyle.captionFont)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Local-first total-recall for your Mac. All capture and inference runs on-device; nothing leaves your machine without your explicit opt-in.")
                .font(PreferencesStyle.bodyFont)
                .foregroundStyle(.secondary)

            Divider()

            Text("Copyright © 2026 MCI — Memory Context Interface")
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)
            Text("License: TBD-private")
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)

            Divider()

            ForEach(Self.aboutLinks, id: \.label) { link in
                Button(link.label) {
                    if let u = URL(string: link.url) {
                        #if canImport(AppKit)
                        NSWorkspace.shared.open(u)
                        #endif
                    }
                }
                .buttonStyle(.link)
            }
        }
    }

    /// External URLs surfaced in the About tab. Kept in a static
    /// tuple array so the URL set is reviewable in one place; a
    /// future policy-page rename is a single-line edit.
    private static let aboutLinks: [(label: String, url: String)] = [
        ("Privacy policy", "https://hippocampus-swart.vercel.app/privacy"),
        ("Terms of service", "https://hippocampus-swart.vercel.app/terms"),
        ("Third-party licenses", "https://hippocampus-swart.vercel.app/licenses"),
        ("Report an issue on GitHub", "https://github.com/amyjainberkeley/hippocampus/issues"),
        ("Send feedback (email)",
         "mailto:hippocampus@amyjainberkeley.com?subject=Hippocampus%20feedback"),
    ]

    // MARK: Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(PreferencesStyle.sectionTitleFont)
            .padding(.bottom, 4)
    }
}

// MARK: - AppKit coordinator

#if canImport(AppKit)

/// Owns the single `NSPanel` instance + the currently selected section.
/// The panel is created lazily on first `show()` and cached; subsequent
/// `show()` calls focus the existing window.
@MainActor
final class PreferencesWindowController: NSObject, NSToolbarDelegate {
    static let shared = PreferencesWindowController()

    private var panel: NSPanel?
    private var section: PreferencesSection = .general
    private var hostingView: NSHostingView<PreferencesRootView>?

    /// Injected on first `configure`. Stored so a subsequent ⌘, from a
    /// different call site (menu-bar → recall UI → onboarding) reuses
    /// the same instances.
    private var store: PreferencesStore?
    private var loginItemVM: LoginItemViewModel?
    private var updater: SparkleUpdaterService?
    private var dbPath: String = "~/Library/Application Support/Hippocampus/mci.sqlite"
    private var onOpenRecallTab: (String) -> Void = { _ in }
    private var onOpenDenylistEditor: () -> Void = {}
    private var onOpenAllowlistEditor: () -> Void = {}
    private var onExportDebugBundle: () -> Void = {}

    /// Provide the dependencies the window needs. Safe to call more
    /// than once — later calls overwrite so a re-initialized supervisor
    /// updates the closures.
    func configure(
        store: PreferencesStore,
        loginItemVM: LoginItemViewModel,
        updater: SparkleUpdaterService,
        dbPath: String,
        onOpenRecallTab: @escaping (String) -> Void,
        onOpenDenylistEditor: @escaping () -> Void,
        onOpenAllowlistEditor: @escaping () -> Void,
        onExportDebugBundle: @escaping () -> Void
    ) {
        self.store = store
        self.loginItemVM = loginItemVM
        self.updater = updater
        self.dbPath = dbPath
        self.onOpenRecallTab = onOpenRecallTab
        self.onOpenDenylistEditor = onOpenDenylistEditor
        self.onOpenAllowlistEditor = onOpenAllowlistEditor
        self.onExportDebugBundle = onExportDebugBundle
    }

    /// Open (or focus) the preferences window.
    func show() {
        guard let store, let loginItemVM, let updater else {
            // Not configured yet — silently no-op. The app's first ⌘,
            // arrives after `configure` from AppDelegate, so this only
            // fires in test / uninitialized contexts.
            return
        }

        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentRect = NSRect(
            x: 0, y: 0,
            width: PreferencesStyle.panelWidth,
            height: PreferencesStyle.panelHeight + 40  // + toolbar
        )
        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Hippocampus Preferences"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.center()

        let toolbar = NSToolbar(identifier: "ai.hippocampus.preferences.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(section.rawValue)
        panel.toolbar = toolbar
        if #available(macOS 11.0, *) {
            panel.toolbarStyle = .preference
        }

        rebuildContent(
            store: store,
            loginItemVM: loginItemVM,
            updater: updater,
            panel: panel
        )

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Programmatically switch section — used by the toolbar action.
    private func setSection(_ new: PreferencesSection) {
        section = new
        guard let store, let loginItemVM, let updater, let panel else { return }
        rebuildContent(
            store: store,
            loginItemVM: loginItemVM,
            updater: updater,
            panel: panel
        )
    }

    private func rebuildContent(
        store: PreferencesStore,
        loginItemVM: LoginItemViewModel,
        updater: SparkleUpdaterService,
        panel: NSPanel
    ) {
        let sectionBinding = Binding<PreferencesSection>(
            get: { [weak self] in self?.section ?? .general },
            set: { [weak self] new in self?.setSection(new) }
        )
        let root = PreferencesRootView(
            store: store,
            section: sectionBinding,
            loginItemVM: loginItemVM,
            updater: updater,
            dbPath: dbPath,
            onOpenRecallTab: onOpenRecallTab,
            onOpenDenylistEditor: onOpenDenylistEditor,
            onOpenAllowlistEditor: onOpenAllowlistEditor,
            onExportDebugBundle: onExportDebugBundle
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(
            x: 0, y: 0,
            width: PreferencesStyle.panelWidth,
            height: PreferencesStyle.panelHeight
        )
        panel.contentView = host
        panel.setContentSize(NSSize(
            width: PreferencesStyle.panelWidth,
            height: PreferencesStyle.panelHeight
        ))
        hostingView = host
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        PreferencesSection.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let section = PreferencesSection(rawValue: itemIdentifier.rawValue) else {
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = section.rawValue
        item.paletteLabel = section.rawValue
        item.image = NSImage(
            systemSymbolName: section.symbol,
            accessibilityDescription: section.rawValue
        )
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        guard let new = PreferencesSection(rawValue: sender.itemIdentifier.rawValue) else {
            return
        }
        setSection(new)
    }
}

#endif
