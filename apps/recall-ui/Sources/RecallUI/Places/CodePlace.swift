import RecallUIKit
import SwiftUI

/// Code (SPEC-DELTA 1): projects worked on in an editor or a terminal. A
/// lens over History: History's own rows and detail, filtered to code, with
/// nothing History doesn't have.
///
/// A seam for now: an empty page. It is built as History's lens.
struct CodePlace: View {
    let reader: BrainReader
    let open: (RecallRoute) -> Void

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
