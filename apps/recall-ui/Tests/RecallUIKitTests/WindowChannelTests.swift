import Darwin
import XCTest
@testable import RecallUIKit

/// The window's end of the private pipe (SPEC 2.6.4). The app's end here is
/// a thread in this test, on pipes made for it: nothing reaches the app.
final class WindowChannelTests: XCTestCase {
    /// A stand-in for the app: reads the window's lines and answers each
    /// as `answer` says, and can push lines of its own.
    private final class FakeApp: @unchecked Sendable {
        let read: Int32
        let write: Int32
        var answer: (([String: Any]) -> Bool?) = { _ in true }
        private let lock = NSLock()
        private(set) var received: [[String: Any]] = []

        init(read: Int32, write: Int32) {
            self.read = read
            self.write = write
            Thread { [weak self] in self?.loop() }.start()
        }

        func push(_ line: String) {
            let data = Array((line + "\n").utf8)
            _ = data.withUnsafeBytes { Darwin.write(write, $0.baseAddress, $0.count) }
        }

        func requests() -> [[String: Any]] { lock.withLock { received } }

        private func loop() {
            var buffer = Data()
            var byte: UInt8 = 0
            while Darwin.read(read, &byte, 1) == 1 {
                guard byte == 0x0A else {
                    buffer.append(byte)
                    continue
                }
                let object = (try? JSONSerialization.jsonObject(with: buffer)) as? [String: Any]
                buffer.removeAll()
                guard let object else { continue }
                lock.withLock { received.append(object) }
                if let ok = answer(object), let id = object["id"] as? String {
                    push("{\"v\":1,\"id\":\"\(id)\",\"ok\":\(ok)}")
                }
            }
        }
    }

    private var descriptors: [Int32] = []

    override func tearDown() {
        // Only the write ends close: every reader on these pipes (the
        // stand-in app's thread and the channel's) then reads end of file and
        // stops. The read ends stay open for the life of the test process. A
        // reader still on its way back into read(2) when a test ends would
        // otherwise find its descriptor's number reused by the next test's
        // pipe(2) and take that test's bytes: an answer read by the last
        // test's channel never reaches this one's, and the request times out.
        for descriptor in descriptors where fcntl(descriptor, F_GETFL) & O_ACCMODE != O_RDONLY {
            Darwin.close(descriptor)
        }
        descriptors = []
    }

    /// Two pipes, as the app makes them: the window writes on one and reads
    /// the other.
    private func wire() -> (WindowChannel, FakeApp) {
        var toApp: [Int32] = [0, 0]
        var toWindow: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&toApp), 0)
        XCTAssertEqual(pipe(&toWindow), 0)
        descriptors += toApp + toWindow
        let app = FakeApp(read: toApp[0], write: toWindow[1])
        return (WindowChannel(writeDescriptor: toApp[1], readDescriptor: toWindow[0]), app)
    }

    func testARequestIsOneVersionedLineOfJSON() throws {
        let until = Date(timeIntervalSince1970: 1_791_844_800)
        let line = try XCTUnwrap(WindowChannelRequest(id: "r1", op: .pause, until: until).line())
        XCTAssertEqual(line.last, 0x0A)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["id"] as? String, "r1")
        XCTAssertEqual(object["op"] as? String, "pause")
        XCTAssertEqual(WindowChannelProtocol.date(object["until"] as? String), until)
        XCTAssertNil(WindowChannelRequest(op: .openSystemSettings, permission: String(repeating: "x", count: 5_000))
            .line(), "nothing longer than 4 KB is sent")
        XCTAssertEqual(WindowChannelProtocol.Op.allCases.map(\.rawValue),
                       ["pause", "resume", "turnOn", "tryAgain", "openSystemSettings", "quit", "hold", "release",
                        "erase", "status"])
    }

    func testTheAppsAnswerIsHeard() async throws {
        let (channel, app) = wire()
        let paused = await channel.send(WindowChannelRequest(op: .pause), timeout: .seconds(5))
        XCTAssertTrue(paused)
        XCTAssertEqual(app.requests().first?["op"] as? String, "pause")
        app.answer = { _ in false }
        let refused = await channel.send(WindowChannelRequest(op: .turnOn), timeout: .seconds(5))
        XCTAssertFalse(refused, "the app decides, and may refuse")
    }

    func testAnUnansweredRequestIsARefusal() async throws {
        let (channel, app) = wire()
        app.answer = { _ in nil }
        let started = Date()
        let answered = await channel.send(WindowChannelRequest(op: .hold), timeout: .milliseconds(300))
        XCTAssertFalse(answered)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testPushedStatusArrivesAndMalformedOrLongLinesAreDropped() async throws {
        let (channel, app) = wire()
        let stream = channel.statuses()
        app.push("not json")
        app.push("{\"v\":2,\"op\":\"status\",\"state\":\"paused\",\"title\":\"Paused\"}")
        app.push(String(repeating: "x", count: 5_000))
        app.push("{\"v\":1,\"op\":\"status\",\"state\":\"weird\",\"title\":\"Paused\"}")
        app.push("{\"v\":1,\"op\":\"status\",\"state\":\"paused\",\"title\":\"Paused\",\"action\":\"resume\"}")
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.state, .paused)
        XCTAssertEqual(first?.title, "Paused")
        XCTAssertEqual(first?.action, "resume")
    }

    func testANewListenerHearsTheNewestStatusAtOnce() async throws {
        let (channel, app) = wire()
        let first = channel.statuses()
        app.push("{\"v\":1,\"op\":\"status\",\"state\":\"off\",\"title\":\"Off\",\"action\":\"turnOn\"}")
        var iterator = first.makeAsyncIterator()
        _ = await iterator.next()
        var late = channel.statuses().makeAsyncIterator()
        let current = await late.next()
        XCTAssertEqual(current?.state, .off)
    }

    func testWhenTheAppIsGoneEveryWaitingRequestIsRefused() async throws {
        var toApp: [Int32] = [0, 0]
        var toWindow: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&toApp), 0)
        XCTAssertEqual(pipe(&toWindow), 0)
        descriptors += [toApp[0], toApp[1], toWindow[0]]
        let channel = WindowChannel(writeDescriptor: toApp[1], readDescriptor: toWindow[0])
        Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            Darwin.close(toWindow[1])
        }
        let answered = await channel.send(WindowChannelRequest(op: .resume), timeout: .seconds(10))
        XCTAssertFalse(answered)
    }

    /// The window marks both ends close-on-exec as its first act, so the
    /// agent processes it starts never inherit them.
    func testTheDescriptorsAreMarkedCloseOnExec() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        descriptors += fds
        XCTAssertEqual(fcntl(fds[0], F_GETFD) & FD_CLOEXEC, 0)
        XCTAssertTrue(WindowChannel.closeOnExec(fds[0]))
        XCTAssertNotEqual(fcntl(fds[0], F_GETFD) & FD_CLOEXEC, 0)
        XCTAssertTrue(WindowChannel.isPipe(fds[0]))
        XCTAssertFalse(WindowChannel.closeOnExec(-1))
    }

    /// A window opened by hand has no channel; only exactly "3,4", both
    /// pipes, is one.
    func testOnlyTheAppsTwoPipesAreAChannel() {
        XCTAssertNil(WindowChannel.descriptors(environment: [:]))
        XCTAssertNil(WindowChannel.descriptors(environment: ["MCI_WINDOW_CHANNEL": "1,2"]))
        XCTAssertNil(WindowChannel.descriptors(environment: ["MCI_WINDOW_CHANNEL": "4,3"]))
        XCTAssertNil(WindowChannel.descriptors(environment: ["MCI_WINDOW_CHANNEL": "three,four"]))
        XCTAssertNil(WindowChannel.open(environment: ["MCI_WINDOW_CHANNEL": "0,0"]))
        XCTAssertEqual(WindowChannelProtocol.environmentKey, "MCI_WINDOW_CHANNEL")
    }

    func testNoChannelRefusesEverything() async {
        let none = NoWindowChannel()
        let answered = await none.send(WindowChannelRequest(op: .turnOn), timeout: .seconds(1))
        XCTAssertFalse(answered)
        var iterator = none.statuses().makeAsyncIterator()
        let status = await iterator.next()
        XCTAssertNil(status)
    }
}
