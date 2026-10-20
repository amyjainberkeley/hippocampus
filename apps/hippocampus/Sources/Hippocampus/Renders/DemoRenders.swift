#if DEBUG
import Combine
import HippocampusKit
import SwiftUI

extension StatusPreviewRenderer {
    /// Preferences › About with Demo Memory off, being made and in use
    /// (`prefs-about-demo-*`). Drawn with every other picture by
    /// `HIPPOCAMPUS_RENDER_BAR`, from controllers that change nothing.
    static var demoPanes: [Pane] {
        [(DemoMemoryController.Phase.off, "off"), (.making, "making"), (.on, "in-use"), (.leaving, "leaving")]
            .map { phase, name in
                let pane = fixturePane("about-demo-\(name)", .about,
                                       state: phase == .on ? .paused : .running,
                                       receipt: savedReceipt(savedAt: Date().addingTimeInterval(-8)),
                                       paused: phase == .on)
                let controller = DemoRenderFixture.controller(phase)
                return Pane(name: pane.name, view: AnyView(pane.view.environment(\.demoMemoryPreview, controller)))
            }
    }

    /// The hi menu with Option held (`menu-demo-option`), while the week is
    /// made (`menu-demo-making`), and while it is in use with remembering
    /// paused (`menu-demo-in-use`, light and dark).
    static var demoMenuStates: [MenuState] {
        let saved = now.addingTimeInterval(-8)
        let pausedSince = now.addingTimeInterval(-6 * 60)
        func state(_ name: String, _ phase: DemoMemoryController.Phase, optionHeld: Bool,
                   paused: Bool, dark: Bool = false) -> MenuState {
            let status: MenuBarStatus = paused ? .paused : .recording
            let row = StatusRow(StatusFacts(status: status, lastSavedAt: paused ? nil : saved,
                                            pausedSince: paused ? pausedSince : nil), now: now)
            let extra = DemoRenderFixture.controller(phase).menuItems(optionHeld: optionHeld)
            return MenuState(
                name: name, status: status,
                items: StatusMenuModel.items(row: row, setupComplete: true, askLabel: "⇧⇧",
                                             aiToolsConnected: true, extraItems: extra),
                dark: dark
            )
        }
        return [
            state("demo-option", .off, optionHeld: true, paused: false),
            state("demo-making", .making, optionHeld: false, paused: false),
            state("demo-in-use", .on, optionHeld: false, paused: true),
            state("demo-in-use-dark", .on, optionHeld: false, paused: true, dark: true),
        ]
    }
}

/// Controllers for pictures: shown in a phase, with a host and a maker
/// that do nothing.
@MainActor
private enum DemoRenderFixture {
    static func controller(_ phase: DemoMemoryController.Phase) -> DemoMemoryController {
        let folder = DemoMemoryFolder(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-memory-picture-\(UUID().uuidString)", isDirectory: true))
        let controller = DemoMemoryController(host: PictureHost(), maker: PictureMaker(), folder: folder)
        controller.showForPreview(phase)
        return controller
    }

    private final class PictureHost: DemoMemoryHost {
        var isPaused: Bool { false }
        var isQuiet: Bool { true }
        var isConnectingAITools: Bool { false }
        func pauseRemembering() async throws {}
        func resumeRemembering() {}
        func restartReaders(openWindow: Bool) async {}
        func watchRemembering(_ change: @escaping @MainActor () -> Void) -> AnyCancellable { AnyCancellable {} }
        func confirmUse() async -> Bool { false }
        func report(_ message: String) {}
    }

    private struct PictureMaker: DemoMemoryMaking {
        func make(into folder: DemoMemoryFolder, keyHex: String, now: Date, timeZone: TimeZone) async throws
            -> DemoMemoryWeek {
            throw DemoMemoryMakeError.missingTool("pictures make nothing")
        }
    }
}
#endif
