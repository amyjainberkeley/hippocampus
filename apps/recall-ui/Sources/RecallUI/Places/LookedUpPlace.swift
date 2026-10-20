import RecallUIKit
import SwiftUI

/// Looked Up (SPEC 3.6): searches made on the sites the agent reads, newest
/// first, each with the pages opened next. A lens over History.
///
/// A seam for now: an empty page. It is built from the agent's `searches`
/// read with Working On.
struct LookedUpPlace: View {
    let understanding: UnderstandingReader
    let reader: BrainReader
    let open: (RecallRoute) -> Void

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
