#if DEBUG
import AppKit
import HippocampusKit
import SwiftUI

extension StatusPreviewRenderer {
    /// Preferences › General with the calendar off, on, turned off by macOS,
    /// and not allowed on this Mac (`prefs-calendar-*`), light and dark. Drawn
    /// with every other picture by `HIPPOCAMPUS_RENDER_BAR`, from fakes:
    /// nothing reads this Mac's calendar or asks macOS for it.
    static var calendarPanes: [Pane] {
        let states: [(name: String, choice: Bool?, permission: CalendarPermission)] = [
            ("calendar-off", nil, .notDetermined),
            ("calendar-on", true, .fullAccess),
            ("calendar-denied", true, .denied),
            ("calendar-restricted", nil, .restricted),
        ]
        return states.flatMap { state in
            [false, true].map { dark in
                let model = CalendarPreferenceModel(
                    store: FixedCalendarAccess(state.permission), setting: .inMemory(state.choice), openURL: { _ in }
                )
                let general = fixturePane(state.name, .general,
                                          receipt: savedReceipt(savedAt: Date().addingTimeInterval(-8)))
                let view = AnyView(general.view.environment(\.calendarPreferencePreview, model))
                return dark
                    ? Pane(name: "\(state.name)-dark", view: AnyView(DarkAppearance(content: view)))
                    : Pane(name: state.name, view: view)
            }
        }
    }
}

/// A pane as the Mac draws it in Dark Mode. Panes are drawn light, so this
/// hosts one in an AppKit view of its own with the dark appearance, which
/// the switches and buttons follow as the text does.
private struct DarkAppearance: NSViewRepresentable {
    let content: AnyView

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(content.environment(\.colorScheme, .dark)))
        host.appearance = NSAppearance(named: .darkAqua)
        return host
    }

    func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView host: NSHostingView<AnyView>, context: Context) -> CGSize? {
        host.fittingSize
    }
}
#endif
