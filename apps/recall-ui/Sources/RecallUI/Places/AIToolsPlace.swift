import RecallUIKit
import SwiftUI

/// AI Tools (SPEC 3.8): what leaves this Mac and to whom. Each connected
/// tool with its plain status and the exact words it starts with, the tool
/// ⌘↩ opens, and the tools on this Mac that aren't connected.
///
/// A seam for now: an empty page. It is built from the agent's `clients`
/// read with the handoff.
struct AIToolsPlace: View {
    let understanding: UnderstandingReader
    let open: (RecallRoute) -> Void

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
