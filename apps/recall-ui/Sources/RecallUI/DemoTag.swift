import RecallUIKit
import SwiftUI

/// The small "Demo" tag by the window's title while the window reads Demo
/// Memory, the made-up week for the launch video and screenshots
/// (SPEC-DELTA 6). The menu bar's menu shows it too (`DemoMemory` in the app).
struct DemoTag: View {
    var body: some View {
        Text(DemoCopy.tag)
            .mciFont(.caption)
            .foregroundStyle(MCI.Color.foregroundSecondary)
            .padding(.horizontal, MCI.Spacing.s)
            .padding(.vertical, MCI.Spacing.xxs)
            .overlay(Capsule().strokeBorder(MCI.Color.border, lineWidth: 1))
            .accessibilityLabel(DemoCopy.tagLabel)
    }
}

/// The window's slot for the tag, which the window shell applies once. It
/// adds nothing at all, not even an empty toolbar, unless the window reads
/// Demo Memory. Off-screen renders draw no toolbar, so a picture of the tag
/// (`WindowRenderer.Scene.demoMemory`) needs it drawn where a render sees it.
struct DemoTagSlot: ViewModifier {
    let isDemoMemory: Bool

    func body(content: Content) -> some View {
        if isDemoMemory {
            content.toolbar {
                ToolbarItem(placement: .navigation) { DemoTag() }
            }
        } else {
            content
        }
    }
}
