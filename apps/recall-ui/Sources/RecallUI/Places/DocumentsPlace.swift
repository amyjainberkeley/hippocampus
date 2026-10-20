import RecallUIKit
import SwiftUI

/// Documents (SPEC-DELTA 1): docs, notes, sheets and designs worked on. A
/// lens over History: History's own rows and detail, filtered to documents,
/// with nothing History doesn't have.
///
/// A seam for now: an empty page. It is built as History's lens.
struct DocumentsPlace: View {
    let reader: BrainReader
    let open: (RecallRoute) -> Void

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
