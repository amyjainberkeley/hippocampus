// SPDX-License-Identifier: Apache-2.0
//
// WindowReadsProbe — the window's own reads and deletes, without the window.
//
// Development and test only; never bundled. `scripts/e2e-full.sh` drives it.
//
// It opens the memory with `FFIBrainReader`, the reader the window uses, and
// answers in JSON on stdout:
//
//   history [LIMIT]          History's rows: caption, snippet, screenshot path
//   reading EVENT_ID         the moment's clean text (main, rest) and caption
//   search QUERY             the window's search
//   screenshot EVENT_ID      opens the moment's screenshot the way the window
//                            does (ThumbnailDataProvider): says whether it
//                            decrypts to an image, and its size; never the bytes
//   privacy [LIMIT]          moments skipped for privacy, as the window lists them
//   forget EVENT_ID          the window's Forget for one moment
//   forget-range START END   the window's delete for a time range (µs)
//
// The key is the development file key only: it refuses to run without
// MCI_DEVELOPMENT_FILE_KEY=1, so it can never ask the Keychain.

import CoreGraphics
import Foundation
import ImageIO
import RecallUIKit

private enum ProbeError: Error, CustomStringConvertible {
    case usage
    case developmentModeRequired
    case notFound(UInt64)

    var description: String {
        switch self {
        case .usage:
            return "usage: WindowReadsProbe history [LIMIT] | reading ID | search QUERY | screenshot ID | privacy [LIMIT] | forget ID | forget-range START END"
        case .developmentModeRequired:
            return "development file-key mode is required (MCI_DEVELOPMENT_FILE_KEY=1); the Keychain is never read"
        case .notFound(let id):
            return "no moment \(id)"
        }
    }
}

private struct Row: Encodable {
    let eventId: UInt64
    let tsUs: UInt64
    let app: String?
    let title: String?
    let caption: String?
    let snippet: String
    let screenshotPath: String?
    let screenshotTsUs: UInt64?
    let sourceKind: String?

    init(_ hit: Hit) {
        eventId = hit.eventId
        tsUs = hit.tsUs
        app = hit.appBundleId
        title = hit.windowTitle
        caption = hit.caption
        snippet = hit.ocrTextSnippet
        screenshotPath = hit.thumbnailPath
        screenshotTsUs = hit.thumbnailTsUs
        sourceKind = hit.sourceKind
    }

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id", tsUs = "ts_us", app, title, caption, snippet
        case screenshotPath = "screenshot_path", screenshotTsUs = "screenshot_ts_us"
        case sourceKind = "source_kind"
    }
}

@main
private enum WindowReadsProbe {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("WindowReadsProbe: \(error)\n".utf8))
            exit(2)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { throw ProbeError.usage }
        let environment = ProcessInfo.processInfo.environment
        guard environment["MCI_DEVELOPMENT_FILE_KEY"] == "1",
              let keyHex = try DevelopmentDatabaseKeyMaterial.hex(from: environment)
        else {
            throw ProbeError.developmentModeRequired
        }
        let path = environment["MCI_DB_PATH"] ?? defaultBrainPath()
        let reader: FFIBrainReader
        if let model = environment["MCI_ARCTIC_MODEL_PATH"], !model.isEmpty {
            reader = try FFIBrainReader(path: path, keyHex: keyHex, modelPath: model)
        } else {
            reader = try FFIBrainReader(path: path, keyHex: keyHex)
        }
        defer { reader.close() }

        switch command {
        case "history":
            let limit = arguments.count > 1 ? Int(arguments[1]) ?? 200 : 200
            try emit(try await reader.recentEvents(limit: limit).map(Row.init))
        case "reading":
            let id = try eventId(arguments, at: 1)
            guard let reading = try await reader.eventReading(eventId: id, query: nil) else {
                try emit(nil as [String: String]?)
                return
            }
            try emit([
                "event_id": "\(reading.eventId)",
                "main": reading.main,
                "rest": reading.rest,
                "caption": reading.caption ?? "",
                "truncated": reading.isTruncated ? "true" : "false",
                "source_kind": reading.sourceKind,
            ])
        case "search":
            guard arguments.count > 1 else { throw ProbeError.usage }
            let query = arguments[1...].joined(separator: " ")
            try emit(try await reader.search(SearchOptions(text: query, limit: 50)).map(Row.init))
        case "screenshot":
            let id = try eventId(arguments, at: 1)
            guard let hit = try await reader.fetchEventsByIds([id]).first else {
                throw ProbeError.notFound(id)
            }
            guard let url = hit.thumbnailURL else {
                try emit(["event_id": "\(id)", "screenshot": "none"])
                return
            }
            let provider = ThumbnailDataProvider.production(environment: environment)
            let data = await provider.screenshotData(for: url)
            try emit(describe(image: data, eventId: id, path: url.path))
        case "privacy":
            let limit = arguments.count > 1 ? Int(arguments[1]) ?? 200 : 200
            let moments = try await reader.recentPrivacyMoments(limit: limit)
            try emit(moments.map {
                ["ts_us": "\($0.tsUs)", "app": $0.appBundleId ?? "", "reason": "\($0.reasonCode)"]
            })
        case "forget":
            let id = try eventId(arguments, at: 1)
            try emit(deleteSummary(try await reader.deleteEvent(id: id)))
        case "forget-range":
            guard arguments.count == 3,
                  let start = UInt64(arguments[1]),
                  let end = UInt64(arguments[2])
            else { throw ProbeError.usage }
            try emit(deleteSummary(try await reader.deleteEventsInRange(startTsUs: start, endTsUs: end)))
        default:
            throw ProbeError.usage
        }
    }

    private static func eventId(_ arguments: [String], at index: Int) throws -> UInt64 {
        guard arguments.count > index, let id = UInt64(arguments[index]) else { throw ProbeError.usage }
        return id
    }

    private static func deleteSummary(_ result: DeleteResult) -> [String: String] {
        [
            "committed": "\(result.committed)",
            "events_deleted": "\(result.eventsDeleted)",
            "vacuum_ok": "\(result.vacuumOk)",
            "blob_cleanup_ok": "\(result.blobCleanupOk)",
        ]
    }

    /// What the window would show: an image, its kind and size. Never the bytes.
    private static func describe(image data: Data?, eventId: UInt64, path: String) -> [String: String] {
        guard let data else {
            return ["event_id": "\(eventId)", "path": path, "screenshot": "unreadable"]
        }
        let kind: String
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            kind = "jpeg"
        } else if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            kind = "png"
        } else {
            kind = "other"
        }
        var width = 0
        var height = 0
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        }
        return [
            "event_id": "\(eventId)", "path": path, "screenshot": "decrypted",
            "kind": kind, "bytes": "\(data.count)", "width": "\(width)", "height": "\(height)",
        ]
    }

    private static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func defaultBrainPath() -> String {
        let support = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)
            .first ?? NSTemporaryDirectory()
        return (support as NSString).appendingPathComponent("MCI/mci.sqlite")
    }
}
