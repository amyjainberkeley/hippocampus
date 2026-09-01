import Foundation

/// Synchronous callback ingress with one asynchronous consumer.
///
/// AsyncStream continuation yield preserves the order in which the serial
/// SCStream callback submits jobs. The bounded newest buffer drops one older
/// pending job under pressure and immediately releases its owned surface via
/// onDrop; only the single consumer may execute operation.
final class OrderedCaptureDispatcher: @unchecked Sendable {
    struct Job: Sendable {
        let captureOrdinal: UInt64
        let operation: @Sendable () async -> Void
        let onDrop: @Sendable () -> Void
    }

    enum Submission: Sendable, Equatable {
        case enqueued
        case dropped(captureOrdinal: UInt64)
        case terminated
    }

    private let continuation: AsyncStream<Job>.Continuation
    private let worker: Task<Void, Never>

    init(capacity: Int) {
        precondition(capacity >= 1)
        let pair = AsyncStream<Job>.makeStream(
            bufferingPolicy: .bufferingNewest(capacity)
        )
        self.continuation = pair.continuation
        self.worker = Task.detached(priority: .userInitiated) {
            for await job in pair.stream {
                await job.operation()
            }
        }
    }

    @discardableResult
    func submit(
        captureOrdinal: UInt64,
        operation: @Sendable @escaping () async -> Void,
        onDrop: @Sendable @escaping () -> Void
    ) -> Submission {
        let job = Job(
            captureOrdinal: captureOrdinal,
            operation: operation,
            onDrop: onDrop
        )
        switch continuation.yield(job) {
        case .enqueued:
            return .enqueued
        case .dropped(let dropped):
            dropped.onDrop()
            return .dropped(captureOrdinal: dropped.captureOrdinal)
        case .terminated:
            onDrop()
            return .terminated
        @unknown default:
            onDrop()
            return .terminated
        }
    }
}
