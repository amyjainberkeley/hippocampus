import XCTest

@testable import MCICaptureHelperKit

final class OrderedCaptureDispatcherTests: XCTestCase {
    func testSerializesInCallbackOrderAndBoundsPendingJobs() async {
        let dispatcher = OrderedCaptureDispatcher(capacity: 2)
        let gate = DispatcherGate()
        let recorder = DispatcherRecorder()

        dispatcher.submit(
            captureOrdinal: 1,
            operation: {
                recorder.started(1)
                await gate.wait()
                recorder.finished(1)
            },
            onDrop: {
                recorder.dropped(1)
            }
        )
        for _ in 0..<200 {
            if recorder.startedOrdinals() == [1] { break }
            try? await Task.sleep(for: .milliseconds(5))
        }

        for ordinal in 2...4 {
            dispatcher.submit(
                captureOrdinal: UInt64(ordinal),
                operation: {
                    recorder.started(UInt64(ordinal))
                    recorder.finished(UInt64(ordinal))
                },
                onDrop: {
                    recorder.dropped(UInt64(ordinal))
                }
            )
        }
        await gate.open()
        for _ in 0..<200 {
            if recorder.finishedOrdinals().count == 3 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }

        let started = recorder.startedOrdinals()
        let finished = recorder.finishedOrdinals()
        let dropped = recorder.droppedOrdinals()
        XCTAssertEqual(started, [1, 3, 4])
        XCTAssertEqual(finished, [1, 3, 4])
        XCTAssertEqual(dropped, [2])
        await dispatcher.finishAndDrain()
    }

    func testFinishAndDrainRunsEveryBufferedOperation() async {
        let dispatcher = OrderedCaptureDispatcher(capacity: 2)
        let recorder = DispatcherRecorder()
        for ordinal in 1...2 {
            dispatcher.submit(
                captureOrdinal: UInt64(ordinal),
                operation: { recorder.finished(UInt64(ordinal)) },
                onDrop: { recorder.dropped(UInt64(ordinal)) }
            )
        }

        await dispatcher.finishAndDrain()

        XCTAssertEqual(recorder.finishedOrdinals(), [1, 2])
        XCTAssertTrue(recorder.droppedOrdinals().isEmpty)
    }

    func testCancelAndDrainWaitsForOwnedWorkAndRejectsLateSubmission() async {
        let dispatcher = OrderedCaptureDispatcher(capacity: 1)
        let recorder = DispatcherRecorder()
        dispatcher.submit(
            captureOrdinal: 1,
            operation: {
                recorder.started(1)
                try? await Task.sleep(for: .seconds(5))
                recorder.finished(1)
            },
            onDrop: {
                recorder.dropped(1)
            }
        )
        for _ in 0..<200 {
            if recorder.startedOrdinals() == [1] { break }
            try? await Task.sleep(for: .milliseconds(5))
        }

        await dispatcher.cancelAndDrain()
        XCTAssertEqual(recorder.finishedOrdinals(), [1])
        let late = dispatcher.submit(
            captureOrdinal: 2,
            operation: { recorder.finished(2) },
            onDrop: { recorder.dropped(2) }
        )
        XCTAssertEqual(late, .terminated)
        XCTAssertEqual(recorder.finishedOrdinals(), [1])
        XCTAssertEqual(recorder.droppedOrdinals(), [2])
    }
}

private actor DispatcherGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class DispatcherRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var startedValues: [UInt64] = []
    private var finishedValues: [UInt64] = []
    private var droppedValues: [UInt64] = []

    func started(_ ordinal: UInt64) { lock.withLock { startedValues.append(ordinal) } }
    func finished(_ ordinal: UInt64) { lock.withLock { finishedValues.append(ordinal) } }
    func dropped(_ ordinal: UInt64) { lock.withLock { droppedValues.append(ordinal) } }
    func startedOrdinals() -> [UInt64] { lock.withLock { startedValues } }
    func finishedOrdinals() -> [UInt64] { lock.withLock { finishedValues } }
    func droppedOrdinals() -> [UInt64] { lock.withLock { droppedValues } }
}
