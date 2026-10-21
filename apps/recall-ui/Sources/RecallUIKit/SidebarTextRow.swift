import SwiftUI

/// A sidebar row with no symbol whose words still start where every other
/// row's do: Show All, "aligned with the labels" (SPEC 2.2). It is a Label
/// whose symbol slot is kept and drawn as nothing, so its words line up at
/// whatever sidebar icon size the person picked in System Settings, as the
/// rows with symbols and the Working On rows with screenshots do.
public struct SidebarTextRow: View {
    let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Label {
            Text(verbatim: title)
        } icon: {
            Image(systemName: "circle")
                .hidden()
        }
    }
}
