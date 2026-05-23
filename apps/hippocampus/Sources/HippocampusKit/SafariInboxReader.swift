// SPDX-License-Identifier: TBD-private
//
// SafariInboxReader — watches the App Group shared container for
// JSON payloads written by the Safari web extension handler, applies
// URL denylist + secret-pattern filtering (same rules as the Chromium
// native-messaging host), encodes PageContentEvent wire frames, and
// writes them to the agent's page_content.sock.
//
// Architecture:
//   Safari .appex → group.ai.hippocampus/safari-inbox/ → [this] →
//   page_content.sock → mci-agent PageContentListener → BrainPump
//
// ADR-0020 §4 invariants preserved:
//   - URL denylist: same substring/prefix checks as native host
//   - Secret filter: same 4 regex patterns as native host §6 cascade
//   - Incognito: Safari disables extensions in Private Browsing by
//     default (manifest + OS enforcement); no payload files created
//   - Text truncation: same 200 KB cap at sentence boundary

import Foundation
import os

@MainActor
public final class SafariInboxReader: Sendable {
    private let logger = Logger(
        subsystem: "ai.hippocampus",
        category: "safari-inbox"
    )

    nonisolated(unsafe) private static let groupID = "group.ai.hippocampus"
    nonisolated(unsafe) private static let inboxDir = "safari-inbox"
    nonisolated(unsafe) private static let maxTextBytes = 200 * 1024

    // Wire protocol constants — must match core/src/ipc/wire.rs
    nonisolated(unsafe) private static let frameMagic: UInt8 = 0x4D
    nonisolated(unsafe) private static let frameVersion: UInt8 = 0x06
    nonisolated(unsafe) private static let pageContentEventType: UInt16 = 0x0050

    // Content-free telemetry counters
    public private(set) var forwarded: UInt64 = 0
    public private(set) var droppedDenylist: UInt64 = 0
    public private(set) var droppedSecret: UInt64 = 0
    public private(set) var failedParse: UInt64 = 0

    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var timer: Timer?
    private let socketPath: String

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.socketPath = "\(home)/Library/Application Support/MCI/page_content.sock"
    }

    public func start() {
        drainBacklog()
        startWatching()
    }

    public func stop() {
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
        if dirFD >= 0 {
            close(dirFD)
            dirFD = -1
        }
    }

    // MARK: - Directory watching

    private func startWatching() {
        guard let inboxURL = inboxURL() else {
            logger.warning("safari-inbox: App Group container not available")
            return
        }

        try? FileManager.default.createDirectory(
            at: inboxURL, withIntermediateDirectories: true
        )

        dirFD = Darwin.open(inboxURL.path, O_EVTONLY)
        guard dirFD >= 0 else {
            logger.error("safari-inbox: cannot open directory for monitoring")
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: .write,
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.drainBacklog()
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 {
                Darwin.close(fd)
                self?.dirFD = -1
            }
        }
        src.resume()
        self.source = src

        // Low-rate polling fallback (every 5 s) in case DispatchSource
        // misses an event (e.g. rapid file creation).
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.drainBacklog()
            }
        }

        logger.info("safari-inbox: watching \(inboxURL.path, privacy: .public)")
    }

    // MARK: - Inbox drain

    private func drainBacklog() {
        guard let inboxURL = inboxURL() else { return }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
        guard !jsonFiles.isEmpty else { return }

        for fileURL in jsonFiles {
            processPayloadFile(fileURL)
        }
    }

    private func processPayloadFile(_ fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL) else {
            failedParse += 1
            removeFile(fileURL)
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            failedParse += 1
            logger.warning("safari-inbox: invalid JSON, removing")
            removeFile(fileURL)
            return
        }

        guard let url = json["url"] as? String,
              let title = json["title"] as? String,
              let text = json["text"] as? String,
              let tsUs = json["ts_us"] as? UInt64
        else {
            failedParse += 1
            logger.warning("safari-inbox: missing required fields, removing")
            removeFile(fileURL)
            return
        }

        let tabId = (json["tab_id"] as? UInt32) ?? 0
        let sourceBrowser = (json["source_browser"] as? String) ?? "safari"

        // ADR-0020 §4 — URL denylist (same rules as native host)
        if Self.isDeniedURL(url) {
            droppedDenylist += 1
            removeFile(fileURL)
            return
        }

        // §6 secret-pattern filter (same patterns as native host)
        if Self.containsSecret(text) {
            droppedSecret += 1
            removeFile(fileURL)
            return
        }

        let truncated = Self.truncateAtSentenceBoundary(
            text, maxBytes: Self.maxTextBytes
        )

        let frame = Self.encodePageContentEvent(
            seq: forwarded,
            tsUs: tsUs,
            url: url,
            title: title,
            fullText: truncated,
            sourceBrowser: sourceBrowser,
            tabId: tabId
        )

        if writeToSocket(frame) {
            forwarded += 1
            removeFile(fileURL)
        }
        // On write failure, leave the file for retry on next drain.
    }

    // MARK: - Socket write

    private func writeToSocket(_ data: Data) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, pathBytes.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddr in
                Darwin.connect(fd, saddr, addrLen)
            }
        }
        guard result == 0 else { return false }

        return data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress else { return false }
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, ptr + offset, remaining)
                if written <= 0 { return false }
                offset += written
                remaining -= written
            }
            return true
        }
    }

    // MARK: - URL denylist (mirrors native host is_denied_url)

    nonisolated static func isDeniedURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("password")
            || lower.contains("signin")
            || lower.contains("sign-in")
            || lower.contains("login")
            || lower.hasPrefix("chrome:")
            || lower.hasPrefix("chrome-extension:")
            || lower.hasPrefix("about:")
            || lower.hasPrefix("data:")
            || lower.hasPrefix("file:")
    }

    // MARK: - Secret filter (mirrors native host secret_filter.rs §6)

    nonisolated(unsafe) private static let secretPatterns: [NSRegularExpression] = {
        let specs = [
            #"(?i)(?:password|passwd|secret|api[_\-]?key|token|bearer|access[_\-]?token)\s*[:=]\s*\S+"#,
            #"gh[pousr]_[A-Za-z0-9]{36}"#,
            #"(?:AKIA|ASIA)[A-Z0-9]{16}"#,
            #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
        ]
        return specs.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    nonisolated static func containsSecret(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in secretPatterns {
            if pattern.firstMatch(in: text, range: range) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Text truncation (mirrors native host)

    nonisolated static func truncateAtSentenceBoundary(
        _ text: String, maxBytes: Int
    ) -> String {
        let utf8 = Array(text.utf8)
        guard utf8.count > maxBytes else { return text }

        let slice = utf8.prefix(maxBytes)
        let sliceStr = String(decoding: slice, as: UTF8.self)

        if let pos = sliceStr.range(
            of: ". ", options: .backwards
        )?.lowerBound {
            return String(sliceStr[...pos])
        }
        if let pos = sliceStr.lastIndex(of: "\n") {
            return String(sliceStr[..<pos])
        }
        return sliceStr
    }

    // MARK: - Wire encoding (mirrors core/src/ipc/wire.rs)

    nonisolated static func encodePageContentEvent(
        seq: UInt64,
        tsUs: UInt64,
        url: String,
        title: String,
        fullText: String,
        sourceBrowser: String,
        tabId: UInt32
    ) -> Data {
        let urlBytes = Array(url.utf8)
        let titleBytes = Array(title.utf8)
        let textBytes = Array(fullText.utf8)
        let browserBytes = Array(sourceBrowser.utf8)

        // Payload: seq(8) + ts_us(8) + url_len(2) + title_len(2) +
        // full_text_len(4) + source_browser_len(1) + tab_id(4) +
        // url + title + full_text + source_browser
        let fixedHeader = 8 + 8 + 2 + 2 + 4 + 1 + 4  // 29
        let payloadLen = fixedHeader + urlBytes.count + titleBytes.count
            + textBytes.count + browserBytes.count

        // Frame header: magic(1) + version(1) + msg_type(2) + seq(8) + len(4) = 16
        var data = Data(capacity: 16 + payloadLen)

        // Frame header
        data.append(frameMagic)
        data.append(frameVersion)
        appendLE(&data, pageContentEventType)
        appendLE(&data, seq)
        appendLE(&data, UInt32(payloadLen))

        // Payload
        appendLE(&data, seq)
        appendLE(&data, tsUs)
        appendLE(&data, UInt16(urlBytes.count))
        appendLE(&data, UInt16(titleBytes.count))
        appendLE(&data, UInt32(textBytes.count))
        data.append(UInt8(browserBytes.count))
        appendLE(&data, tabId)
        data.append(contentsOf: urlBytes)
        data.append(contentsOf: titleBytes)
        data.append(contentsOf: textBytes)
        data.append(contentsOf: browserBytes)

        return data
    }

    // MARK: - Helpers

    private func inboxURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.groupID
        )?.appendingPathComponent(Self.inboxDir, isDirectory: true)
    }

    private func removeFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated private static func appendLE(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 2))
    }

    nonisolated private static func appendLE(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 4))
    }

    nonisolated private static func appendLE(_ data: inout Data, _ value: UInt64) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 8))
    }
}
