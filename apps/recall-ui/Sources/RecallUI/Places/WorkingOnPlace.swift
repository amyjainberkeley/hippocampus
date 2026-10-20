import RecallUIKit
import SwiftUI

/// Working On, all of it (SPEC 3.3, SPEC-DELTA 2): every project and
/// document by name, each card with its screenshot, kind, apps, when it was
/// last worked on and its time this week; This week, Earlier, and what isn't
/// in the sidebar.
///
/// A seam for now: an empty page. It is built from the `work` read with
/// Working On.
struct WorkingOnPlace: View {
    let work: any WorkReader
    let reader: BrainReader
    let open: (RecallRoute) -> Void

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
