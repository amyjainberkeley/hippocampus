import Foundation

/// An OpenAI-style model server for tests. It listens on 127.0.0.1 only, on
/// a port the system picks, and answers each request with what `reply`
/// returns for it, one request per connection.
final class FakeModelServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let body: [String: Any]

        /// The user message sent, for a chat request.
        var prompt: String { ((body["messages"] as? [[String: String]])?.last?["content"]) ?? "" }
        /// The schema's name in `response_format`, when there is one.
        var schemaName: String? { ((body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["name"] as? String }
    }

    struct Reply {
        var status = 200
        var body: String
        var headers: [String: String] = [:]
        var delay: TimeInterval = 0
    }

    let port: UInt16
    var baseURL: String { "http://127.0.0.1:\(port)/v1" }
    var requests: [Request] { lock.withLock { seen } }

    private let listener: Int32
    private let source: DispatchSourceRead
    private let reply: @Sendable (Request) -> Reply
    private let lock = NSLock()
    private var seen: [Request] = []

    init(reply: @escaping @Sendable (Request) -> Reply) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var one: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, length) == 0 && listen(listener, 32) == 0 && getsockname(listener, $0, &length) == 0
            }
        }
        guard bound else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        self.listener = listener
        self.port = UInt16(bigEndian: address.sin_port)
        self.reply = reply
        source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: DispatchQueue(label: "fake-model-server"))
        source.setEventHandler { [weak self] in self?.acceptWaiting() }
        source.setCancelHandler { close(listener) }
        source.resume()
    }

    deinit { source.cancel() }

    func stop() { source.cancel() }

    private func acceptWaiting() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            DispatchQueue.global().async { self.answer(client) }
        }
    }

    private func answer(_ client: Int32) {
        defer { close(client) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            received.append(contentsOf: buffer[0..<count])
            headEnd = received.range(of: Data("\r\n\r\n".utf8))
        }
        guard let headEnd else { return }
        let head = String(decoding: received[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = head.first?.split(separator: " ").map(String.init) ?? []
        let length = head.dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        var body = Data(received[headEnd.upperBound...])
        while body.count < length {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            body.append(contentsOf: buffer[0..<count])
        }
        let request = Request(method: start.first ?? "", path: start.count > 1 ? start[1] : "",
                              body: (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:])
        lock.withLock { seen.append(request) }
        let answer = reply(request)
        if answer.delay > 0 { Thread.sleep(forTimeInterval: answer.delay) }
        let payload = Data(answer.body.utf8)
        var head2 = "HTTP/1.1 \(answer.status) Reply\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n"
        for (name, value) in answer.headers { head2 += "\(name): \(value)\r\n" }
        var response = Data((head2 + "\r\n").utf8)
        response.append(payload)
        response.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
    }

    // MARK: Replies

    /// `GET /models` as Ollama and LM Studio answer it.
    static func models(_ names: [String]) -> Reply {
        Reply(body: json(["object": "list", "data": names.map { ["id": $0, "object": "model", "owned_by": "library"] }]))
    }

    /// A chat completion whose message is `content`.
    static func chat(_ content: String) -> Reply {
        Reply(body: json(["id": "chatcmpl-1", "object": "chat.completion", "model": "m", "choices": [
            ["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"],
        ]]))
    }

    static func json(_ object: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    /// A port on 127.0.0.1 with nothing listening on it.
    static func closedPort() throws -> UInt16 {
        let server = try FakeModelServer { _ in Reply(body: "") }
        let port = server.port
        server.stop()
        return port
    }
}

/// A flag that tests set from one thread and the fake server reads on another.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
