// SPDX-License-Identifier: Apache-2.0
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
//   - NSToolbar with six selectable items (General, Remembering, AI Tools,
//     Privacy, Advanced, About). Toolbar switching is the same pattern
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
// Retention writes atomically to the agent's canonical
// `retention.json`; cosmetic settings remain in UserDefaults.

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

// MARK: - Section presentation

extension PreferencesSection {
    /// SF-Symbol icon rendered in the toolbar item.
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .capture: return "rectangle.stack"
        case .sources: return "point.3.connected.trianglepath.dotted"
        case .privacy: return "hand.raised"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Root view

/// What Preferences asks the app to do.
struct PreferencesActions {
    /// The status row's button.
    var statusAction: (CaptureStatusAction) -> Void = { _ in }
    /// Open the window on a place.
    var openWindow: (String) -> Void = { _ in }
    var neverRead: () -> Void = {}
    var chooseApps: () -> Void = {}
    /// Run Connect AI Tools…, then call back.
    var connectAITools: (@escaping () -> Void) -> Void = { done in done() }
    var restart: () -> Void = {}
    /// Setup again, in review once it is done (RULINGS O4).
    var showSetup: () -> Void = {}
}

struct PreferencesRootView: View {
    @ObservedObject var store: PreferencesStore
    @Binding var section: PreferencesSection
    @ObservedObject var loginItemVM: LoginItemViewModel
    @ObservedObject var captureController: CapturePreferenceController
    @ObservedObject var supervisor: ProcessSupervisor
    /// What opens Ask right now: the key's caption follows it.
    @ObservedObject var askKey: AskKeyWatch
    let updater: any UpdaterService
    let actions: PreferencesActions
    /// Fixed AI tool facts for the off-screen renderer.
    var aiToolsPreview: SessionContextPreferencesView.Facts?

    @State private var confirmingReset = false
    @State private var resetResult: (title: String, message: String)?
    /// Pictures of side windows; the section shows only when given.
    @Environment(\.sidePictures) private var sidePictures

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                sectionContent
                    .padding(PreferencesStyle.contentPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: PreferencesStyle.panelWidth, height: PreferencesStyle.panelHeight)
        // Preferences follows the Mac's light or dark appearance (SPEC 8.4).
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .general: generalSection
        case .capture: captureSection
        case .sources: SessionContextPreferencesView(supervisor: supervisor, connect: actions.connectAITools, preview: aiToolsPreview)
        case .privacy: privacySection
        case .advanced: advancedSection
        case .about: aboutSection
        }
    }

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: PreferencesStyle.sectionSpacing) {
            sectionHeader("General")

            Toggle("Open at login", isOn: Binding(
                get: { loginItemVM.isEnabled },
                set: { _ in loginItemVM.toggle() }
            ))

            AskKeyPicker(store: store, askKey: askKey)

            CalendarPreferencesSection()
        }
    }

    // MARK: Remembering

    /// Start Remembering in onboarding is the only consent, so before setup
    /// the switch waits (product critique 4).
    private var setupFinished: Bool {
        OnboardingSentinel.isComplete || !supervisor.hasOnboarding
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: PreferencesStyle.sectionSpacing) {
            sectionHeader(PreferencesSection.capture.label)

            CaptureHealthView(supervisor: supervisor, perform: actions.statusAction)

            Divider()

            // On while a turn-on is under way, since its helper may read
            // before the setting is: turning the switch off then drops it.
            Toggle("Remember my screen", isOn: Binding(
                get: { supervisor.captureEnabled || supervisor.turningOn },
                set: { on in
                    Task { @MainActor in
                        await captureController.setCaptureEnabled(on)
                    }
                }
            ))
            .disabled(captureController.isApplying || !setupFinished)

            if let sidePictures {
                SidePicturesSection(model: sidePictures, setupFinished: setupFinished)
            }

            Divider()

            Button("Choose Apps…") { actions.chooseApps() }
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: PreferencesStyle.sectionSpacing) {
            sectionHeader("Privacy")

            // Opens the read-only panel of that name; no list of apps to
            // edit exists (onboarding contract, section 3).
            Button("What Is Never Read…") { actions.neverRead() }

            Divider()

            Picker("Keep my memory for", selection: Binding(
                get: { store.retentionPolicy },
                set: { policy in
                    _ = store.setRetentionPolicy(
                        policy,
                        customDays: policy == .custom
                            ? (store.retentionCustomDays ?? 90)
                            : nil
                    )
                }
            )) {
                ForEach(RetentionPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayLabel).tag(policy)
                }
            }
            .pickerStyle(.menu)
            if store.retentionPolicy == .custom {
                Stepper(
                    "\(store.retentionCustomDays ?? 90) days",
                    value: Binding(
                        get: { store.retentionCustomDays ?? 90 },
                        set: { days in
                            _ = store.setRetentionPolicy(.custom, customDays: days)
                        }
                    ),
                    in: 1...365
                )
            }
            Text("Anything older is deleted for good.")
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)
            if store.retentionNeedsReview {
                Label("Confirm how long to keep your memory. Nothing is deleted until you do.", systemImage: "exclamationmark.triangle")
                    .font(PreferencesStyle.captionFont)
                    .foregroundStyle(.orange)
                Button("Confirm") {
                    _ = store.setRetentionPolicy(store.retentionPolicy, customDays: store.retentionCustomDays)
                }
            }
            if let retentionWriteError = store.retentionWriteError {
                Text(retentionWriteError)
                    .font(PreferencesStyle.captionFont)
                    .foregroundStyle(.red)
            }

            Divider()

            Button("See or Delete What’s Remembered…") {
                actions.openWindow("privacy")
            }
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: PreferencesStyle.sectionSpacing) {
            sectionHeader("Advanced")

            Text("Troubleshooting").font(.headline)

            Button("Show Logs") {
                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/MCI"))
            }
            Button("Reset Permissions…") { confirmingReset = true }
            Button("Show Setup Again") { actions.showSetup() }
            Button("Restart Hippocampus") { actions.restart() }
        }
        .alert(PermissionReset.confirmTitle, isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button(PermissionReset.confirmButton, role: .destructive) { resetPermissions() }
        } message: {
            Text(PermissionReset.confirmMessage)
        }
        .alert(resetResult?.title ?? "", isPresented: Binding(
            get: { resetResult != nil },
            set: { if !$0 { resetResult = nil } }
        )) {
            Button("OK") { resetResult = nil }
        } message: {
            Text(resetResult?.message ?? "")
        }
    }

    /// Resets only Hippocampus's own grants (RULINGS S10), off the main thread.
    private func resetPermissions() {
        Task {
            let failed = await Task.detached(priority: .userInitiated) {
                PermissionReset.reset(run: PermissionReset.runTCCUtil)
            }.value
            resetResult = failed.isEmpty
                ? (PermissionReset.doneTitle, PermissionReset.doneMessage)
                : ("Couldn’t reset permissions", PermissionReset.failureMessage(names: failed))
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
                Text("Build \(sha)")
                    .font(PreferencesStyle.captionFont)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Hippocampus remembers your screen so you and your AI don’t have to. It stays on this Mac unless you send it to an AI tool.")
                .font(PreferencesStyle.bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
            }

            DemoMemoryPreferencesSection()

            Divider()

            // The facts in NOTICE and LICENSE (spec-copy M2 finding 8).
            Text("© 2026 Amy Jain")
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)
            Text("Apache License 2.0")
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)

            Divider()

            Button("Third-party licenses") {
                #if canImport(AppKit)
                NSWorkspace.shared.open(
                    Bundle.main.url(forResource: "NOTICE", withExtension: "txt") ?? Self.noticeOnline
                )
                #endif
            }
            .buttonStyle(.link)

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

    /// The bundled notices open offline; a development build without them
    /// opens the repository's copy.
    private static let noticeOnline = URL(string: "https://github.com/amyjainberkeley/hippocampus/blob/main/NOTICE")!

    /// External URLs surfaced in the About tab. Kept in a static
    /// tuple array so the URL set is reviewable in one place; a
    /// future policy-page rename is a single-line edit.
    private static let aboutLinks: [(label: String, url: String)] = [
        ("Privacy policy", "https://github.com/amyjainberkeley/hippocampus/blob/main/PRIVACY.md"),
        ("License", "https://github.com/amyjainberkeley/hippocampus/blob/main/LICENSE"),
        ("Report a problem", "https://github.com/amyjainberkeley/hippocampus/issues"),
        ("Send feedback", "https://github.com/amyjainberkeley/hippocampus/issues/new?title=Feedback"),
    ]

    // MARK: Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(PreferencesStyle.sectionTitleFont)
            .padding(.bottom, 4)
    }
}

// MARK: - Pictures of side windows

private struct SidePicturesKey: EnvironmentKey {
    static let defaultValue: SidePicturesPreferences? = nil
}

extension EnvironmentValues {
    /// Preferences' pictures of side windows (SPEC 6.7). Nil hides them.
    var sidePictures: SidePicturesPreferences? {
        get { self[SidePicturesKey.self] }
        set { self[SidePicturesKey.self] = newValue }
    }
}

/// Keep screenshots of windows beside the one you’re using (SPEC 6.7):
/// the switch and what it means; while on, the budget and what the pictures
/// use; while off, forgetting them. A change is written at once, and the
/// capture helper and the agent act on it at their next read.
struct SidePicturesSection: View {
    @ObservedObject var model: SidePicturesPreferences
    let setupFinished: Bool
    @State private var confirmingForget = false

    /// The checkbox's label starts this far in; the lines under it line up.
    private static let indent: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(SidePicturesCopy.toggle, isOn: Binding(
                get: { model.enabled },
                set: { model.setEnabled($0) }
            ))
            VStack(alignment: .leading, spacing: PreferencesStyle.controlSpacing) {
                Text(SidePicturesCopy.explanation)
                    .font(PreferencesStyle.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.enabled {
                    HStack(spacing: PreferencesStyle.rowSpacing) {
                        Picker(SidePicturesCopy.useAtMost, selection: Binding(
                            get: { model.budgetMB },
                            set: { model.setBudget(megabytes: $0) }
                        )) {
                            ForEach(SidePictureSettings.budgetChoicesMB, id: \.self) { megabytes in
                                Text(SidePicturesCopy.budget(megabytes: megabytes)).tag(megabytes)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        if let line = model.usageLine {
                            Text(line)
                                .font(PreferencesStyle.captionFont)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button(SidePicturesCopy.forgetButton) { confirmingForget = true }
                        .disabled(!model.hasPictures)
                }
                if let writeError = model.writeError {
                    Text(writeError)
                        .font(PreferencesStyle.captionFont)
                        .foregroundStyle(.red)
                }
            }
            .padding(.leading, Self.indent)
        }
        .disabled(!setupFinished)
        .alert(SidePicturesCopy.forgetTitle, isPresented: $confirmingForget) {
            // Cancel is the default: Return never forgets.
            Button(SidePicturesCopy.cancel, role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button(SidePicturesCopy.forget, role: .destructive) { model.forgetPictures() }
        } message: {
            Text(SidePicturesCopy.forgetMessage)
        }
        .task {
            // What the pictures use changes as the agent thins and forgets.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                model.refresh()
            }
        }
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
    private var hostingView: NSHostingView<AnyView>?

    /// Injected on first `configure`. Stored so a subsequent ⌘, from a
    /// different call site (menu-bar → recall UI → onboarding) reuses
    /// the same instances.
    private var store: PreferencesStore?
    private var loginItemVM: LoginItemViewModel?
    private var updater: SparkleUpdaterService?
    private var captureController: CapturePreferenceController?
    private var supervisor: ProcessSupervisor?
    private var actions = PreferencesActions()
    /// Pictures of side windows, read from the person's own settings when
    /// Preferences first opens.
    private var sidePictures: SidePicturesPreferences?

    /// Provide the dependencies the window needs. Safe to call more
    /// than once — later calls overwrite so a re-initialized supervisor
    /// updates the closures.
    func configure(
        store: PreferencesStore,
        loginItemVM: LoginItemViewModel,
        updater: SparkleUpdaterService,
        captureApplier: any CaptureSettingApplying,
        supervisor: ProcessSupervisor,
        actions: PreferencesActions
    ) {
        self.store = store
        self.loginItemVM = loginItemVM
        self.updater = updater
        self.captureController = CapturePreferenceController(applier: captureApplier)
        self.supervisor = supervisor
        self.actions = actions
    }

    /// Open (or focus) the preferences window.
    func show(section requestedSection: PreferencesSection? = nil) {
        if let requestedSection { setSection(requestedSection) }
        guard let store, let loginItemVM, let updater, let captureController else {
            // Not configured yet — silently no-op. The app's first ⌘,
            // arrives after `configure` from AppDelegate, so this only
            // fires in test / uninitialized contexts.
            return
        }

        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate()
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
            captureController: captureController,
            updater: updater,
            panel: panel
        )

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Programmatically switch section — used by the toolbar action.
    private func setSection(_ new: PreferencesSection) {
        section = new
        panel?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(new.rawValue)
        guard let store, let loginItemVM, let updater, let captureController, let panel else { return }
        rebuildContent(
            store: store,
            loginItemVM: loginItemVM,
            captureController: captureController,
            updater: updater,
            panel: panel
        )
    }

    private func rebuildContent(
        store: PreferencesStore,
        loginItemVM: LoginItemViewModel,
        captureController: CapturePreferenceController,
        updater: SparkleUpdaterService,
        panel: NSPanel
    ) {
        guard let supervisor else { return }
        let sectionBinding = Binding<PreferencesSection>(
            get: { [weak self] in self?.section ?? .general },
            set: { [weak self] new in self?.setSection(new) }
        )
        let root = PreferencesRootView(
            store: store,
            section: sectionBinding,
            loginItemVM: loginItemVM,
            captureController: captureController,
            supervisor: supervisor,
            askKey: SoloKeyMonitor.shared.watch,
            updater: updater,
            actions: actions
        )
        let sidePictures = self.sidePictures ?? SidePicturesPreferences.live()
        self.sidePictures = sidePictures
        sidePictures.refresh()
        let host = NSHostingView(rootView: AnyView(root.environment(\.sidePictures, sidePictures)))
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
        item.label = section.label
        item.paletteLabel = section.label
        item.image = NSImage(
            systemSymbolName: section.symbol,
            accessibilityDescription: section.label
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
