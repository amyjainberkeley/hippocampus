import SwiftUI

/// True inside the synthetic preview, which shows fixtures only. There, rows
/// that open the person's own data (what is remembered, the names they use,
/// their AI tools) and every button that deletes, exports or writes are
/// disabled, so the preview never reaches real data
/// (critique-recall-engineering finding 12). `MemoryWorkspaceView` sets it.
private struct SyntheticPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSyntheticPreview: Bool {
        get { self[SyntheticPreviewKey.self] }
        set { self[SyntheticPreviewKey.self] = newValue }
    }
}
