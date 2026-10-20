// SPDX-License-Identifier: Apache-2.0
//
// DemoScreenSpec.swift — the screen list `mci-seed-brain --demo-week
// --print-screens` prints, and the manifest `demo-screens` writes back.

import Foundation

/// Any JSON value, for a screen's `meta`: each drawing reads what it needs.
public enum DemoJSON: Decodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([DemoJSON])
    case object([String: DemoJSON])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DemoJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: DemoJSON].self))
        }
    }

    public subscript(key: String) -> DemoJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    /// Text, with numbers and booleans written as text.
    public var text: String? {
        switch self {
        case .string(let value): value
        case .number(let value):
            value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }

    public var int: Int? {
        if case .number(let value) = self, value == value.rounded() { return Int(value) }
        if case .string(let value) = self { return Int(value) }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var items: [DemoJSON] {
        if case .array(let values) = self { return values }
        return []
    }

    /// A list of text.
    public var texts: [String] { items.compactMap(\.text) }

    /// A table: rows of text, a missing or null cell as "".
    public var rows: [[String]] { items.map { $0.items.map { $0.text ?? "" } } }
}

/// One screenshot to draw: the window it shows and how it looks.
public struct DemoScreenSpec: Decodable, Equatable, Sendable {
    /// Stable id the moments name.
    public let id: String
    /// The drawing: `editor`, `terminal`, `browser`, `slack`, `zoom`,
    /// `notion`, `figma` or `calendar`.
    public let template: String
    /// The app's bundle id.
    public let app: String
    /// The window's title.
    public let title: String
    /// A browser page's address.
    public let url: String?
    /// What the window says.
    public let main: String
    /// Its own tabs, bars and side panels.
    public let rest: String
    /// What the drawing needs besides the text.
    public let meta: DemoJSON

    public init(
        id: String, template: String, app: String, title: String, url: String? = nil,
        main: String, rest: String = "", meta: DemoJSON = .object([:])
    ) {
        self.id = id
        self.template = template
        self.app = app
        self.title = title
        self.url = url
        self.main = main
        self.rest = rest
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case id, template, app, title, url, main, rest, meta
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            template: try values.decode(String.self, forKey: .template),
            app: try values.decode(String.self, forKey: .app),
            title: try values.decode(String.self, forKey: .title),
            url: try values.decodeIfPresent(String.self, forKey: .url),
            main: try values.decode(String.self, forKey: .main),
            rest: try values.decodeIfPresent(String.self, forKey: .rest) ?? "",
            meta: try values.decodeIfPresent(DemoJSON.self, forKey: .meta) ?? .object([:])
        )
    }
}

/// The whole list, as the seeder prints it.
public struct DemoScreenList: Decodable, Equatable, Sendable {
    /// The list's version; this tool reads 1.
    public let version: Int
    /// The week's clock, microseconds since 1970.
    public let nowUs: UInt64
    /// Its time zone, seconds east of UTC.
    public let tzOffsetSecs: Int
    public let screens: [DemoScreenSpec]

    public static let supportedVersion = 1

    private enum CodingKeys: String, CodingKey {
        case version, screens
        case nowUs = "now_us"
        case tzOffsetSecs = "tz_offset_secs"
    }

    public enum ReadError: Error, Equatable {
        case unsupportedVersion(Int)
        case duplicateId(String)
        case badId(String)
    }

    /// Read and check a list: the version this tool draws, and each id once,
    /// made of letters, digits and dashes.
    public static func read(_ data: Data) throws -> DemoScreenList {
        let list = try JSONDecoder().decode(DemoScreenList.self, from: data)
        guard list.version == supportedVersion else { throw ReadError.unsupportedVersion(list.version) }
        var seen = Set<String>()
        for screen in list.screens {
            guard !screen.id.isEmpty, screen.id.count <= 64,
                  screen.id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }),
                  screen.id.allSatisfy(\.isASCII)
            else { throw ReadError.badId(screen.id) }
            guard seen.insert(screen.id).inserted else { throw ReadError.duplicateId(screen.id) }
        }
        return list
    }
}

/// What `demo-screens` writes: each screen's sealed blob, by id, for
/// `mci-seed-brain --demo-week --screens`.
public struct DemoScreenManifest: Codable, Equatable, Sendable {
    public var version = 1
    /// Lowercase SHA-256 hex of each sealed blob, by screen id.
    public var screens: [String: String]

    public init(screens: [String: String]) {
        self.screens = screens
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
