import Foundation
import os

/// News, inside this process, that moments were deleted (RULINGS W9,
/// critique-recall-engineering finding 4).
///
/// Deleting a moment also deletes what was learned from it, its session's
/// notes and its day's summary. Everything the window made from those must go
/// at once: cached reads of the day and of what Hippocampus understands, and
/// the text on screen. Every cache in the window is in memory only and checks
/// `generation`; every screen that shows such text clears and reads again on
/// `notification`. The signal carries no content.
public final class MemoryDeletionSignal: Sendable {
    public static let notification = Notification.Name("ai.hippocampus.recall.deleted.v1")
    public static let shared = MemoryDeletionSignal(center: .default)

    public let center: NotificationCenter
    private let count = OSAllocatedUnfairLock(initialState: UInt64(0))

    public init(center: NotificationCenter = NotificationCenter()) {
        self.center = center
    }

    /// Moves on with every delete. A read cached under an older value is gone.
    public var generation: UInt64 {
        count.withLock { $0 }
    }

    /// Say that moments were deleted: caches drop their reads, and screens
    /// clear what they show and read it again.
    @MainActor
    public func post() {
        count.withLock { $0 &+= 1 }
        center.post(name: Self.notification, object: self)
        MemoryRefreshSignal.post(center: center)
    }

    /// Run a delete, and when it commits, say so. A delete that fails or does
    /// not commit removed nothing, so nothing is said.
    public func reporting(_ delete: () async throws -> DeleteResult) async throws -> DeleteResult {
        let result = try await delete()
        if result.committed {
            await post()
        }
        return result
    }
}
