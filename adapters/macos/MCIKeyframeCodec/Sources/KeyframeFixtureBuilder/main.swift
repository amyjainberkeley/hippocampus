import Darwin
import Foundation
import MCIKeyframeCodec

private enum FixtureError: Error, CustomStringConvertible {
    case usage
    case developmentModeRequired
    case missingKey
    case invalidKey
    case invalidInput(String)
    case conflictingBlob(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: KeyframeFixtureBuilder --blob-root DIR IMAGE [IMAGE ...]"
        case .developmentModeRequired:
            return "MCI_DEVELOPMENT_FILE_KEY must be exactly 1"
        case .missingKey:
            return "MCI_DB_KEY_HEX is required"
        case .invalidKey:
            return "MCI_DB_KEY_HEX must contain exactly 64 hexadecimal characters"
        case let .invalidInput(path):
            return "cannot read a non-empty regular image file: \(path)"
        case let .conflictingBlob(path):
            return "refusing to replace a conflicting content-addressed blob: \(path)"
        }
    }
}

@main
private enum KeyframeFixtureBuilder {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("KeyframeFixtureBuilder: \(error)\n".utf8))
            exit(2)
        }
    }

    private static func run() throws {
        guard ProcessInfo.processInfo.environment["MCI_DEVELOPMENT_FILE_KEY"] == "1" else {
            throw FixtureError.developmentModeRequired
        }
        guard let keyHex = ProcessInfo.processInfo.environment["MCI_DB_KEY_HEX"] else {
            throw FixtureError.missingKey
        }
        guard let key = decodeKey(keyHex) else {
            throw FixtureError.invalidKey
        }

        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 3,
              arguments[0] == "--blob-root"
        else {
            throw FixtureError.usage
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        for path in arguments.dropFirst(2) {
            let input = URL(fileURLWithPath: path)
            let values = try input.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0,
                  let plaintext = try? Data(contentsOf: input, options: .mappedIfSafe)
            else {
                throw FixtureError.invalidInput(path)
            }

            let sealed = try KeyframeBlobCodec.seal(plaintext: plaintext, keyMaterial: key)
            let output = root.appendingPathComponent("\(sealed.lowercaseHexDigest).bin")
            if FileManager.default.fileExists(atPath: output.path) {
                let existing = try Data(contentsOf: output, options: .mappedIfSafe)
                guard existing == sealed.bytes else {
                    throw FixtureError.conflictingBlob(output.path)
                }
            } else {
                try sealed.bytes.write(to: output, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: output.path
                )
            }
            print(sealed.lowercaseHexDigest)
        }
    }

    private static func decodeKey(_ value: String) -> Data? {
        guard value.utf8.count == 64 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var index = value.startIndex
        for _ in 0 ..< 32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
