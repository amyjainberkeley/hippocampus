import Darwin
import Foundation
import RecallUIKit

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func read() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@main
struct MemoryRefreshBehavior {
    @MainActor
    static func main() async {
        let center = NotificationCenter()
        let counter = LockedCounter()
        let observer = center.addObserver(
            forName: MemoryRefreshSignal.notification,
            object: nil,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { center.removeObserver(observer) }

        MemoryRefreshSignal.post(center: center)
        guard counter.read() == 1 else {
            fail("refresh signal was not delivered exactly once")
        }

        let viewModel = SearchViewModel(reader: StubBrainReader())
        viewModel.query = "privacy"
        await viewModel.refresh()
        guard viewModel.hits.map(\.eventId) == [101] else {
            fail("active search was not re-run")
        }
        guard !viewModel.observedApps.isEmpty else {
            fail("observed apps were not refreshed")
        }

        print("memory refresh behavior: PASS")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("memory refresh behavior: FAIL: \(message)\n".utf8))
        Darwin.exit(1)
    }
}
