import Foundation

/// Process-local request to re-read the encrypted brain.
///
/// The signal carries no memory contents. Each visible surface performs its
/// own existing read operation, so refresh cannot bypass `BrainReader` or
/// invent a successful result.
public enum MemoryRefreshSignal {
    public static let notification = Notification.Name(
        "ai.hippocampus.recall.refresh.v1"
    )

    public static func post(center: NotificationCenter = .default) {
        center.post(name: notification, object: nil)
    }
}
