#if DEBUG
import AppKit
import Combine
import HippocampusKit
import SwiftUI

/// Debug only, run by `CommandBarPreviewRenderer` under the same rules:
/// nothing reaches the screen. An `NSMenu` cannot be drawn off screen, so the
/// menu is a facsimile of `StatusMenuModel`'s rows, labelled as one
/// (critique-shell-engineering 13), drawn under the status item's real
/// picture. The Preferences panes are the real views, fed fixtures.
@MainActor
enum StatusPreviewRenderer {
    static func render(to out: URL) {
        for state in menuStates() + contributedMenuStates {
            let view = MenuFacsimile(name: state.name, status: state.status, items: state.items, dark: state.dark)
            if let png = OffscreenPNG.render(view, dark: state.dark) {
                try? png.write(to: out.appendingPathComponent("menu-\(state.name).png"))
            }
        }
        for pane in preferencePanes() + contributedPanes {
            let view = pane.view
                .frame(width: 560)
                .background(Color(nsColor: .windowBackgroundColor))
            if let png = OffscreenPNG.render(view, dark: false) {
                try? png.write(to: out.appendingPathComponent("prefs-\(pane.name).png"))
            }
        }
    }

    /// Every other package's pictures, from its own `Renders/*.swift` file,
    /// so no package edits this file to add one: the hi menu with Option
    /// held (Demo Memory), and Preferences' panes for side-window pictures,
    /// AI Tools, the Ask key, the calendar and Demo Memory.
    private static var contributedMenuStates: [MenuState] { demoMenuStates }
    private static var contributedPanes: [Pane] {
        sidePicturePanes + aiToolsPanes + askKeyPanes + calendarPanes + demoPanes
    }

    // MARK: The menu

    /// One picture of the menu: `menu-<name>.png`.
    struct MenuState {
        let name: String
        let status: MenuBarStatus
        let items: [StatusMenuModel.Item]
        var dark = false
    }

    /// Oct 13, 3:10 PM in the renderer's time zone, so times read the same
    /// on every run.
    static let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 15, minute: 10))!
    }()

    private static func menuStates() -> [MenuState] {
        let sixMinutesAgo = now.addingTimeInterval(-6 * 60)
        let yesterday = now.addingTimeInterval(-26 * 3600)
        func state(
            _ name: String, _ status: MenuBarStatus, setup: AskPanelStatus.Setup = .complete,
            lastSaved: Date? = nil, paused: Date? = nil, stopped: Date? = nil,
            turningOn: Bool = false, stopping: Bool = false,
            askLabel: String? = "⇧⇧", connected: Bool = false, dark: Bool = false
        ) -> MenuState {
            let row = StatusRow(StatusFacts(
                status: status, setup: setup, lastSavedAt: lastSaved, pausedSince: paused, stoppedSharingAt: stopped,
                turningOn: turningOn, stopping: stopping
            ), now: now)
            return MenuState(
                name: name, status: status,
                items: StatusMenuModel.items(row: row, setupComplete: setup == .complete,
                                             askLabel: askLabel, aiToolsConnected: connected),
                dark: dark
            )
        }
        return [
            state("remembering", .recording, lastSaved: now.addingTimeInterval(-8)),
            state("remembering-dark", .recording, lastSaved: now.addingTimeInterval(-8), dark: true),
            state("remembering-unchanged", .unchanged, lastSaved: now.addingTimeInterval(-3 * 3600 - 60)),
            state("starting", .starting),
            // Turn On under way: its helper may read already, so Turn Off.
            state("turning-on", .starting, turningOn: true),
            state("turning-on-dark", .starting, turningOn: true, dark: true),
            // A turn-off or Quit still stopping: nothing to press until Off.
            state("stopping", .starting, stopping: true),
            state("nothing-saved", .noMemory),
            state("skipping-private", .skipping(reason: "private_browsing")),
            // The Oct 13 receipt, once its skip has held: still the solid dot.
            state("skipping-never-read", .skipping(reason: "denylist-source")),
            state("skipping-password", .skipping(reason: "secure-event-input")),
            state("skipping-password-dark", .skipping(reason: "secure-event-input"), dark: true),
            state("paused", .paused, paused: sixMinutesAgo),
            state("paused-another-day", .paused, paused: yesterday),
            state("off", .idle),
            state("off-stop-sharing", .idle, stopped: sixMinutesAgo),
            state("off-stop-sharing-another-day", .idle, stopped: yesterday),
            state("needs-permission", .needsPermission(.screenRecording)),
            state("not-saving", .blocked(reason: "storage_error")),
            state("not-saving-unconfirmed", .stale(reason: "fixture")),
            state("not-saving-stopped", .error(reason: "fixture")),
            state("couldnt-stop", .stopFailed(reason: "fixture")),
            state("couldnt-stop-dark", .stopFailed(reason: "fixture"), dark: true),
            state("couldnt-turn-on", .turnOnFailed(reason: "fixture")),
            state("couldnt-turn-on-dark", .turnOnFailed(reason: "fixture"), dark: true),
            state("turn-on-needs-permission", .needsPermission(.screenRecording)),
            state("turn-on-needs-accessibility", .needsPermission(.accessibility)),
            state("not-set-up", .idle, setup: .notFinished),
            state("not-set-up-onboarding-open", .idle, setup: .inProgress),
            state("ai-tools-connected", .recording, lastSaved: now.addingTimeInterval(-8), connected: true),
            state("ask-fallback-key", .recording, lastSaved: now.addingTimeInterval(-8), askLabel: AskShortcut.fallbackLabel),
        ]
    }

    // MARK: Preferences

    /// One picture of Preferences: `prefs-<name>.png`, 560 pt wide.
    struct Pane {
        let name: String
        let view: AnyView
    }

    /// A saved status from `savedAt`, as the menu bar's receipt has it.
    static func savedReceipt(savedAt: Date) -> CaptureStatusReceipt? {
        PreviewFixtures.receipt(savedAt: savedAt)
    }

    /// Preferences on `section`, fed fixtures: a supervisor in `state` that
    /// starts nothing, its own throwaway settings (`configure` sets them
    /// before the pane reads them), and Shift twice as the Ask key. Nothing
    /// reads or writes the person's own settings or memory.
    static func fixturePane(
        _ name: String, _ section: PreferencesSection, state: SupervisorState = .running,
        captureEnabled: Bool = true, receipt: CaptureStatusReceipt?,
        stoppedSharingAt: Date? = nil, stopFailed: Bool = false, paused: Bool = false,
        turnOnFailure: TurnOnFailure? = nil, turningOn: Bool = false,
        configure: (UserDefaults) -> Void = { _ in }
    ) -> Pane {
        let pauses = UserPauseController(clock: { Date().addingTimeInterval(-6 * 60) })
        if paused { pauses.setPaused(true) }
        let supervisor = ProcessSupervisor(
            locator: PreviewLocator(), keyStore: PreviewKeyStore(),
            runtimeConfig: PreviewRuntimeConfig(captureEnabled: captureEnabled),
            topology: PreviewTopology(), keyCustodyPreparer: PreviewKeyCustody(),
            readinessTimeout: 0.1, captureStatusReader: { (nil, receipt) }, pauses: pauses
        )
        supervisor.showForPreview(
            state: state, captureEnabled: captureEnabled, receipt: receipt,
            startedAt: Date().addingTimeInterval(-600), stoppedSharingAt: stoppedSharingAt, stopFailed: stopFailed,
            turnOnFailure: turnOnFailure, turningOn: turningOn
        )
        let defaults = UserDefaults(suiteName: "ai.hippocampus.preview.\(UUID().uuidString)")!
        configure(defaults)
        let retention = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-\(UUID().uuidString)/retention.json")
        let askKey = AskKeyWatch(hooks: AskKeyWatch.Hooks(
            isTrusted: { true }, install: { _ in true }, uninstall: {},
            after: { _, _ in AnyCancellable {} }
        ))
        askKey.setFallbackRegistered(true)
        askKey.start(key: .shiftTwice)
        let view = PreferencesRootView(
            store: PreferencesStore(defaults: defaults, retentionURL: retention),
            section: .constant(section),
            loginItemVM: LoginItemViewModel(service: PreviewLoginService()),
            captureController: CapturePreferenceController(applier: supervisor),
            supervisor: supervisor,
            askKey: askKey,
            updater: PreviewUpdater(),
            actions: PreferencesActions(),
            aiToolsPreview: SessionContextPreferencesView.Facts(
                connected: [.claudeCode], statuses: [.claudeCode: .configured, .codex: .notConfigured]
            )
        )
        return Pane(name: name, view: AnyView(view))
    }

    private static func preferencePanes() -> [Pane] {
        let saved = Date().addingTimeInterval(-8)
        func pane(
            _ name: String, _ section: PreferencesSection, state: SupervisorState = .running,
            captureEnabled: Bool = true, receipt: CaptureStatusReceipt? = PreviewFixtures.receipt(savedAt: saved),
            stoppedSharingAt: Date? = nil, stopFailed: Bool = false, paused: Bool = false,
            turnOnFailure: TurnOnFailure? = nil, turningOn: Bool = false
        ) -> Pane {
            fixturePane(name, section, state: state, captureEnabled: captureEnabled, receipt: receipt,
                        stoppedSharingAt: stoppedSharingAt, stopFailed: stopFailed, paused: paused,
                        turnOnFailure: turnOnFailure, turningOn: turningOn)
        }
        return [
            pane("general", .general),
            pane("remembering", .capture),
            pane("remembering-paused", .capture, state: .paused, paused: true),
            pane("remembering-off-stop-sharing", .capture, state: .stopped, captureEnabled: false,
                 receipt: nil, stoppedSharingAt: Date().addingTimeInterval(-6 * 60)),
            pane("remembering-couldnt-stop", .capture, state: .crashed(reason: "fixture"), captureEnabled: false,
                 receipt: nil, stopFailed: true),
            pane("remembering-needs-permission", .capture, receipt: PreviewFixtures.receipt(
                savedAt: saved, blocked: "screen_recording_permission"
            )),
            pane("remembering-off", .capture, captureEnabled: false, receipt: nil),
            // The switch reads On while Turn On is under way.
            pane("remembering-turning-on", .capture, captureEnabled: false, receipt: nil, turningOn: true),
            pane("remembering-couldnt-turn-on", .capture, captureEnabled: false, receipt: nil,
                 turnOnFailure: .didNotStart(reason: "fixture")),
            pane("remembering-turn-on-needs-permission", .capture, state: .crashed(reason: "fixture"),
                 captureEnabled: false, receipt: nil, turnOnFailure: .permission(.screenRecording)),
            pane("ai-tools", .sources),
            pane("privacy", .privacy),
            pane("advanced", .advanced),
            pane("about", .about),
        ]
    }
}

/// One view drawn into a 2x bitmap that is never put in a window.
@MainActor
enum OffscreenPNG {
    static func render<V: View>(_ view: V, dark: Bool) -> Data? {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: Int((size.width * scale).rounded()),
                  pixelsHigh: Int((size.height * scale).rounded()),
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              )
        else { return nil }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

/// The status item's picture over a menu drawn from `StatusMenuModel`.
private struct MenuFacsimile: View {
    let name: String
    let status: MenuBarStatus
    let items: [StatusMenuModel.Item]
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Facsimile of the menu from StatusMenuModel: \(name)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                Spacer()
                Image(nsImage: MenuBarStatusIcon.image(for: status))
                    .renderingMode(.template)
                    .foregroundStyle(dark ? Color.white : Color.black)
                    .frame(width: 30, height: 24)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)))
                    .padding(.trailing, 40)
            }
            .frame(width: 300, height: 24)
            .background(dark ? Color(white: 0.16) : Color(white: 0.93))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    row(item)
                }
            }
            .padding(.vertical, 5)
            .frame(width: 270, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(dark ? Color(white: 0.2) : Color(white: 0.97)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.15)))
            .padding(.leading, 20)
        }
        .padding(16)
        .background(dark ? Color(white: 0.1) : Color(white: 0.85))
    }

    @ViewBuilder
    private func row(_ item: StatusMenuModel.Item) -> some View {
        switch item.role {
        case .separator:
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                .padding(.horizontal, 10).padding(.vertical, 5)
        case .status:
            Text(item.title).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 3)
        case .detail:
            Text(item.title).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.bottom, 3)
        default:
            HStack(spacing: 6) {
                Text(item.title).font(.system(size: 13))
                    .foregroundStyle(item.isEnabled ? Color.primary : Color.secondary.opacity(0.6))
                Spacer()
                if let badge = item.badge {
                    Text(badge).font(.system(size: 11))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
                if let key = item.key {
                    Text(Self.label(key)).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 3)
        }
    }

    private static func label(_ key: StatusMenuModel.KeyEquivalent) -> String {
        (key.control ? "⌃" : "") + (key.shift ? "⇧" : "") + (key.command ? "⌘" : "")
            + (key.key == " " ? "Space" : key.key.uppercased())
    }
}

// MARK: Fixtures

private enum PreviewFixtures {
    static func receipt(savedAt: Date, blocked: String? = nil) -> CaptureStatusReceipt? {
        let formatter = ISO8601DateFormatter()
        var json: [String: Any] = [
            "schema_version": 1, "updated_at": formatter.string(from: Date()),
            "stored_frame_count": 120, "stored_screenshot_count": 40,
            "last_stored_frame_at": formatter.string(from: savedAt),
        ]
        json["blocked_reason"] = blocked
        return try? CaptureStatusReceipt.decode(JSONSerialization.data(withJSONObject: json))
    }
}

private struct PreviewLocator: BinaryLocator {
    func helperPath() -> URL? { nil }
    func agentPath() -> URL? { nil }
    func recallUIPath() -> URL? { nil }
    func onboardingPath() -> URL? { nil }
    func brainCLIPath() -> URL? { nil }
    func knownSafeAppsPath() -> URL? { nil }
}

private struct PreviewKeyStore: KeyStore {
    func readKey() throws -> String { throw KeyStoreError.noKeyFound }
    func writeKey(_ hex: String) throws {}
}

private struct PreviewRuntimeConfig: RuntimeConfiguring {
    let captureEnabled: Bool
    var crashReportOptedIn: Bool { false }
    func setCrashReportOptedIn(_ value: Bool) throws {}
    func setCaptureEnabled(_ value: Bool) throws {}
}

@MainActor
private final class PreviewTopology: SupervisorTopologyControlling {
    var isRunning: Bool { false }
    func launch(
        plan: ProcessSupervisorLaunchPlan, generation: SupervisorProcessGeneration,
        onUnexpectedExit: @escaping @MainActor @Sendable (String, Int32) -> Void
    ) async throws {}
    func waitForReadiness(generation: SupervisorProcessGeneration, timeout: TimeInterval) async throws {}
    func stop(timeout: TimeInterval) async throws {}
}

@MainActor
private final class PreviewKeyCustody: KeyCustodyPreparing {
    func prepare(agentURL: URL, databaseURL: URL, keyReference: KeychainKeyReference) async throws {}
}

private struct PreviewLoginService: LoginItemService {
    func status() -> LoginItemStatus { .enabled }
    func register() throws {}
    func unregister() throws {}
}

@MainActor
private final class PreviewUpdater: UpdaterService {
    var statePublisher: AnyPublisher<UpdaterState, Never> { Just(.idle).eraseToAnyPublisher() }
    var canCheckForUpdates: Bool { true }
    var automaticallyChecksForUpdates = false
    func checkForUpdates() {}
}
#endif
