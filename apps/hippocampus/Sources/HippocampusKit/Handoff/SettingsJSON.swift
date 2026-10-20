// SPDX-License-Identifier: Apache-2.0
//
// SettingsJSON.swift — format-preserving edits of an AI tool's JSON
// settings file (SPEC 5.5): one SessionStart group put in, replaced or taken
// out, and every other byte left as it was. A person's settings keep their
// own order, spacing and keys, and Disconnect leaves the file exactly as it
// was before Connect.
//
// Compiled on its own with SessionContextInstaller.swift by the
// session-context check, so it uses Foundation only.

import Foundation

enum SettingsJSON {
    enum Failure: Error, Equatable {
        case malformed
    }

    /// A parsed value and the bytes it spans.
    indirect enum Node {
        case object(Range<Int>, [Member])
        case array(Range<Int>, [Node])
        case scalar(Range<Int>)

        var range: Range<Int> {
            switch self {
            case .object(let range, _), .array(let range, _), .scalar(let range): range
            }
        }

        var members: [Member]? {
            if case .object(_, let members) = self { return members }
            return nil
        }

        var elements: [Node]? {
            if case .array(_, let elements) = self { return elements }
            return nil
        }
    }

    /// One member of an object: its key (decoded), where the key starts, and
    /// its value.
    struct Member {
        let key: String
        let keyStart: Int
        let value: Node
    }

    /// A file's text, parsed. The root must be an object.
    struct Document {
        let bytes: [UInt8]
        let root: Node

        init(_ data: Data) throws {
            bytes = Array(data)
            var parser = Parser(bytes: bytes)
            parser.skipWhitespace()
            let root = try parser.value(depth: 0)
            parser.skipWhitespace()
            guard parser.index == bytes.count, root.members != nil else { throw Failure.malformed }
            self.root = root
        }

        /// `hooks.SessionStart`, when it is there: its node, and the nodes of
        /// the two objects above it. Malformed when either is the wrong type.
        func sessionStart() throws -> (hooks: Member?, start: Member?) {
            guard let hooks = root.members?.last(where: { $0.key == "hooks" }) else { return (nil, nil) }
            guard let members = hooks.value.members else { throw Failure.malformed }
            guard let start = members.last(where: { $0.key == "SessionStart" }) else { return (hooks, nil) }
            guard start.value.elements != nil else { throw Failure.malformed }
            return (hooks, start)
        }

        /// The groups of `hooks.SessionStart`, each decoded.
        func groups() throws -> [(node: Node, value: Any)] {
            guard let start = try sessionStart().start, let elements = start.value.elements else { return [] }
            return try elements.map { node in
                let slice = Data(bytes[node.range])
                guard let value = try? JSONSerialization.jsonObject(with: slice, options: [.fragmentsAllowed]) else {
                    throw Failure.malformed
                }
                return (node, value)
            }
        }

        // MARK: Style

        /// The file is written on one line.
        var isCompact: Bool {
            guard case .object(let range, _) = root else { return true }
            return !bytes[range].contains(0x0A)
        }

        /// The indentation one level adds: the first member's, else two spaces.
        var unit: [UInt8] {
            guard let first = root.members?.first else { return Array("  ".utf8) }
            let indent = indentation(at: first.keyStart)
            return indent.isEmpty ? Array("  ".utf8) : indent
        }

        /// What comes between a key and its value: `": "` or `" : "`.
        var colon: [UInt8] {
            guard let first = root.members?.first else { return Array(": ".utf8) }
            var end = first.keyStart + 1
            while end < bytes.count, bytes[end] != 0x22 {
                end += bytes[end] == 0x5C ? 2 : 1
            }
            let between = Array(bytes[(end + 1)..<first.value.range.lowerBound])
            if isCompact { return between.filter { $0 != 0x20 && $0 != 0x09 } }
            return between.isEmpty ? Array(": ".utf8) : between
        }

        /// The whitespace before `offset` on its line, when only whitespace
        /// is there; else the indentation of the line it is on.
        func indentation(at offset: Int) -> [UInt8] {
            var start = offset
            while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
            var end = start
            while end < offset, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
            return Array(bytes[start..<end])
        }
    }

    // MARK: Edits

    /// What an edit leaves: new text, or nothing at all when only an empty
    /// object would be left, so the file can go as it came.
    enum Outcome: Equatable {
        case write(Data)
        case remove
    }

    /// The file with `group` added as the last SessionStart group.
    static func appending(_ group: [String: Any], to data: Data?) throws -> Data {
        guard let data, data.contains(where: { !isWhitespace($0) }) else {
            // A new file, in the shape the tools write themselves.
            let unit = Array("  ".utf8)
            var out = Array("{\n  \"hooks\": {\n    \"SessionStart\": [\n      ".utf8)
            out += render(group, indent: Array("      ".utf8), unit: unit, colon: Array(": ".utf8), compact: false)
            out += Array("\n    ]\n  }\n}\n".utf8)
            return Data(out)
        }
        let document = try Document(data)
        let compact = document.isCompact
        let unit = document.unit
        let colon = document.colon
        let (hooks, start) = try document.sessionStart()
        let bytes = document.bytes
        if let start, let elements = start.value.elements {
            let indent = document.indentation(at: start.keyStart)
            if let last = elements.last {
                let at = last.range.upperBound
                let level = compact ? [] : document.indentation(at: last.range.lowerBound)
                let text = (compact ? Array(",".utf8) : Array(",\n".utf8) + level)
                    + render(group, indent: level, unit: unit, colon: colon, compact: compact)
                return Data(bytes[..<at] + text + bytes[at...])
            }
            let inner = start.value.range
            let text: [UInt8] = compact
                ? render(group, indent: [], unit: unit, colon: colon, compact: true)
                : Array("\n".utf8) + indent + unit
                    + render(group, indent: indent + unit, unit: unit, colon: colon, compact: false)
                    + Array("\n".utf8) + indent
            return Data(bytes[..<(inner.lowerBound + 1)] + text + bytes[(inner.upperBound - 1)...])
        }
        let wrapped: [String: Any] = ["SessionStart": [group]]
        if let hooks {
            return Data(try appendMember(
                "SessionStart", [group], to: hooks.value, in: document, compact: compact, unit: unit, colon: colon
            ))
        }
        return Data(try appendMember(
            "hooks", wrapped, to: document.root, in: document, compact: compact, unit: unit, colon: colon
        ))
    }

    /// The file with the group at `index` written as `group`, in the place
    /// and at the indentation the old one had.
    static func replacing(groupAt index: Int, with group: [String: Any], in data: Data) throws -> Data {
        let document = try Document(data)
        guard let start = try document.sessionStart().start, let elements = start.value.elements,
              elements.indices.contains(index) else { throw Failure.malformed }
        let node = elements[index]
        let compact = document.isCompact
        let level = compact ? [] : document.indentation(at: node.range.lowerBound)
        let text = render(group, indent: level, unit: document.unit, colon: document.colon, compact: compact)
        let bytes = document.bytes
        return Data(bytes[..<node.range.lowerBound] + text + bytes[node.range.upperBound...])
    }

    /// The file without the groups at `indexes`. A SessionStart left empty
    /// goes, then a `hooks` left empty; a file left as an empty object is
    /// `.remove`.
    static func removing(groupsAt indexes: Set<Int>, from data: Data) throws -> Outcome {
        var current = data
        // From the last, so earlier offsets stay true.
        for index in indexes.sorted(by: >) {
            current = try removing(groupAt: index, from: current)
        }
        let document = try Document(current)
        if document.root.members?.isEmpty == true,
           current.filter({ !isWhitespace($0) }) == Data("{}".utf8) {
            return .remove
        }
        return .write(current)
    }

    private static func removing(groupAt index: Int, from data: Data) throws -> Data {
        let document = try Document(data)
        let (hooks, start) = try document.sessionStart()
        guard let hooks, let start, let elements = start.value.elements,
              elements.indices.contains(index) else { throw Failure.malformed }
        if elements.count > 1 {
            return Data(cut(document.bytes, between: elements.map(\.range), at: index))
        }
        guard let hookMembers = hooks.value.members,
              let at = hookMembers.firstIndex(where: { $0.keyStart == start.keyStart }) else { throw Failure.malformed }
        if hookMembers.count > 1 {
            return Data(cut(document.bytes, between: hookMembers.map(memberRange), at: at))
        }
        guard let rootMembers = document.root.members,
              let hooksAt = rootMembers.firstIndex(where: { $0.keyStart == hooks.keyStart }) else { throw Failure.malformed }
        if rootMembers.count > 1 {
            return Data(cut(document.bytes, between: rootMembers.map(memberRange), at: hooksAt))
        }
        // Nothing else in the file: an empty object.
        let range = document.root.range
        let bytes = document.bytes
        return Data(bytes[..<(range.lowerBound + 1)] + bytes[(range.upperBound - 1)...])
    }

    private static func memberRange(_ member: Member) -> Range<Int> {
        member.keyStart..<member.value.range.upperBound
    }

    /// `bytes` without the item at `index` of `items` (members or elements
    /// in one container) and its separator: from the end of the one before
    /// it, or for the first, up to the start of the next. The exact
    /// opposite of appending one after the last.
    private static func cut(_ bytes: [UInt8], between items: [Range<Int>], at index: Int) -> [UInt8] {
        let range: Range<Int> = index > 0
            ? items[index - 1].upperBound..<items[index].upperBound
            : items[index].lowerBound..<items[index + 1].lowerBound
        return Array(bytes[..<range.lowerBound] + bytes[range.upperBound...])
    }

    private static func appendMember(
        _ key: String, _ value: Any, to object: Node, in document: Document,
        compact: Bool, unit: [UInt8], colon: [UInt8]
    ) throws -> [UInt8] {
        guard let members = object.members else { throw Failure.malformed }
        let bytes = document.bytes
        let keyText = Array(quote(key).utf8)
        if let last = members.last {
            let level = compact ? [] : document.indentation(at: last.keyStart)
            let text = (compact ? Array(",".utf8) : Array(",\n".utf8) + level)
                + keyText + colon + render(value, indent: level, unit: unit, colon: colon, compact: compact)
            let at = last.value.range.upperBound
            return Array(bytes[..<at] + text + bytes[at...])
        }
        // An empty object: fill it.
        let range = object.range
        let outer = compact ? [] : document.indentation(at: range.lowerBound)
        let text: [UInt8] = compact
            ? keyText + colon + render(value, indent: [], unit: unit, colon: colon, compact: true)
            : Array("\n".utf8) + outer + unit + keyText + colon
                + render(value, indent: outer + unit, unit: unit, colon: colon, compact: false)
                + Array("\n".utf8) + outer
        return Array(bytes[..<(range.lowerBound + 1)] + text + bytes[(range.upperBound - 1)...])
    }

    // MARK: Writing

    /// `value` as JSON: keys sorted, and one item a line at `indent` plus
    /// `unit` per level unless `compact`. Strings are escaped as JSON
    /// requires and nothing more; `/` stays as it is.
    static func render(_ value: Any, indent: [UInt8], unit: [UInt8], colon: [UInt8], compact: Bool) -> [UInt8] {
        switch value {
        case let dictionary as [String: Any]:
            if dictionary.isEmpty { return Array("{}".utf8) }
            let inner = indent + unit
            let items = dictionary.keys.sorted().map { key in
                (compact ? [] : inner) + Array(quote(key).utf8) + colon
                    + render(dictionary[key]!, indent: inner, unit: unit, colon: colon, compact: compact)
            }
            return wrap(items, open: 0x7B, close: 0x7D, indent: indent, compact: compact)
        case let array as [Any]:
            if array.isEmpty { return Array("[]".utf8) }
            let inner = indent + unit
            let items = array.map {
                (compact ? [] : inner) + render($0, indent: inner, unit: unit, colon: colon, compact: compact)
            }
            return wrap(items, open: 0x5B, close: 0x5D, indent: indent, compact: compact)
        case let string as String:
            return Array(quote(string).utf8)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return Array((number.boolValue ? "true" : "false").utf8) }
            return Array(number.stringValue.utf8)
        default:
            return Array("null".utf8)
        }
    }

    private static func wrap(_ items: [[UInt8]], open: UInt8, close: UInt8, indent: [UInt8], compact: Bool) -> [UInt8] {
        if compact { return [open] + Array(items.joined(separator: [0x2C])) + [close] }
        return [open, 0x0A] + Array(items.joined(separator: [0x2C, 0x0A])) + [0x0A] + indent + [close]
    }

    /// A JSON string literal.
    static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    // MARK: Reading

    /// A strict JSON reader that remembers where each value is.
    struct Parser {
        let bytes: [UInt8]
        var index = 0
        static let maxDepth = 256

        mutating func skipWhitespace() {
            while index < bytes.count, SettingsJSON.isWhitespace(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> Node {
            guard depth < Self.maxDepth, index < bytes.count else { throw Failure.malformed }
            switch bytes[index] {
            case 0x7B: return try object(depth: depth)
            case 0x5B: return try array(depth: depth)
            case 0x22:
                let start = index
                _ = try string()
                return .scalar(start..<index)
            case 0x74: return try literal("true")
            case 0x66: return try literal("false")
            case 0x6E: return try literal("null")
            case 0x2D, 0x30...0x39: return try number()
            default: throw Failure.malformed
            }
        }

        private mutating func object(depth: Int) throws -> Node {
            let start = index
            index += 1
            var members: [Member] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == 0x7D {
                index += 1
                return .object(start..<index, members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 0x22 else { throw Failure.malformed }
                let keyStart = index
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 0x3A else { throw Failure.malformed }
                index += 1
                skipWhitespace()
                let value = try value(depth: depth + 1)
                members.append(Member(key: key, keyStart: keyStart, value: value))
                skipWhitespace()
                guard index < bytes.count else { throw Failure.malformed }
                if bytes[index] == 0x2C {
                    index += 1
                    continue
                }
                guard bytes[index] == 0x7D else { throw Failure.malformed }
                index += 1
                return .object(start..<index, members)
            }
        }

        private mutating func array(depth: Int) throws -> Node {
            let start = index
            index += 1
            var elements: [Node] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == 0x5D {
                index += 1
                return .array(start..<index, elements)
            }
            while true {
                skipWhitespace()
                elements.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw Failure.malformed }
                if bytes[index] == 0x2C {
                    index += 1
                    continue
                }
                guard bytes[index] == 0x5D else { throw Failure.malformed }
                index += 1
                return .array(start..<index, elements)
            }
        }

        /// A string, decoded; the index ends after its closing quote.
        private mutating func string() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []
            func flush() throws {
                guard !raw.isEmpty else { return }
                guard let text = String(bytes: raw, encoding: .utf8) else { throw Failure.malformed }
                scalars.append(contentsOf: text.unicodeScalars)
                raw.removeAll()
            }
            while index < bytes.count {
                let byte = bytes[index]
                switch byte {
                case 0x22:
                    index += 1
                    try flush()
                    return String(scalars)
                case 0x5C:
                    try flush()
                    guard index + 1 < bytes.count else { throw Failure.malformed }
                    let escape = bytes[index + 1]
                    index += 2
                    switch escape {
                    case 0x22: scalars.append("\"")
                    case 0x5C: scalars.append("\\")
                    case 0x2F: scalars.append("/")
                    case 0x62: scalars.append("\u{08}")
                    case 0x66: scalars.append("\u{0C}")
                    case 0x6E: scalars.append("\n")
                    case 0x72: scalars.append("\r")
                    case 0x74: scalars.append("\t")
                    case 0x75:
                        var code = try hex4()
                        if (0xD800...0xDBFF).contains(code), index + 1 < bytes.count,
                           bytes[index] == 0x5C, bytes[index + 1] == 0x75 {
                            index += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw Failure.malformed }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw Failure.malformed }
                        scalars.append(scalar)
                    default:
                        throw Failure.malformed
                    }
                case 0x00..<0x20:
                    throw Failure.malformed
                default:
                    raw.append(byte)
                    index += 1
                }
            }
            throw Failure.malformed
        }

        private mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                  let text = String(bytes: bytes[index..<(index + 4)], encoding: .ascii),
                  let value = UInt32(text, radix: 16) else { throw Failure.malformed }
            index += 4
            return value
        }

        private mutating func literal(_ word: String) throws -> Node {
            let start = index
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected else { throw Failure.malformed }
            index += expected.count
            return .scalar(start..<index)
        }

        private mutating func number() throws -> Node {
            let start = index
            if bytes[index] == 0x2D { index += 1 }
            func digits() -> Int {
                let from = index
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
                return index - from
            }
            guard digits() > 0 else { throw Failure.malformed }
            if index < bytes.count, bytes[index] == 0x2E {
                index += 1
                guard digits() > 0 else { throw Failure.malformed }
            }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                index += 1
                if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
                guard digits() > 0 else { throw Failure.malformed }
            }
            return .scalar(start..<index)
        }
    }
}
