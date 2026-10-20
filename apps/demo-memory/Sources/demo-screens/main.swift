// SPDX-License-Identifier: Apache-2.0
//
// demo-screens — draw Demo Memory's screenshots and seal them with the
// capture helper's codec (SPEC-DELTA 6).
//
//   mci-seed-brain --demo-week --print-screens --now-us N > screens.json
//   demo-screens --spec screens.json --blob-root "<folder>/blobs" \
//       --manifest manifest.json --key-stdin < key
//   mci-seed-brain --demo-week --screens manifest.json --now-us N \
//       --db-path "<folder>/mci.sqlite" --key-stdin < key
//
// The key is Demo Memory's own, never the person's: it comes on standard
// input (`--key-stdin`, the app's way), or, for development, from
// MCI_DB_KEY_HEX with MCI_DEVELOPMENT_FILE_KEY=1. Nothing is read from the
// screen, and nothing leaves the Mac.

import DemoScreensKit
import Foundation

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("demo-screens: \(message)\n".utf8))
    exit(code)
}

func decodeKey(_ text: String) -> Data? {
    let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard hex.utf8.count == 64 else { return nil }
    var bytes = [UInt8]()
    var index = hex.startIndex
    for _ in 0..<32 {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
    }
    return Data(bytes)
}

let usage = """
    usage: demo-screens --spec FILE --blob-root DIR --manifest FILE [--key-stdin] [--png-dir DIR]
    """

var arguments = Array(CommandLine.arguments.dropFirst())
var options: [String: String] = [:]
var keyFromStdin = false
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--key-stdin":
        keyFromStdin = true
    case "--spec", "--blob-root", "--manifest", "--png-dir":
        guard let value = arguments.first else { fail("\(argument) needs a value\n\(usage)", 2) }
        arguments.removeFirst()
        options[argument] = value
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        fail("unknown argument \(argument)\n\(usage)", 2)
    }
}
guard let specPath = options["--spec"], let blobRoot = options["--blob-root"],
      let manifestPath = options["--manifest"] else { fail(usage, 2) }

let environment = ProcessInfo.processInfo.environment
let key: Data
if keyFromStdin {
    let input = FileHandle.standardInput.readData(ofLength: 256)
    guard let text = String(data: input, encoding: .utf8), let decoded = decodeKey(text) else {
        fail("the key on standard input must be 64 hexadecimal characters", 11)
    }
    key = decoded
} else {
    guard environment["MCI_DEVELOPMENT_FILE_KEY"] == "1" else {
        fail("pass --key-stdin, or MCI_DEVELOPMENT_FILE_KEY=1 with MCI_DB_KEY_HEX", 9)
    }
    guard let decoded = environment["MCI_DB_KEY_HEX"].flatMap(decodeKey) else {
        fail("MCI_DB_KEY_HEX must be 64 hexadecimal characters", 10)
    }
    key = decoded
}

let list: DemoScreenList
do {
    list = try DemoScreenList.read(Data(contentsOf: URL(fileURLWithPath: specPath)))
} catch {
    fail("cannot read the screen list: \(error)", 12)
}

do {
    let manifest = try MainActor.assumeIsolated {
        try DemoScreens.make(list, key: key, blobRoot: URL(fileURLWithPath: blobRoot, isDirectory: true),
                             pngFolder: options["--png-dir"].map { URL(fileURLWithPath: $0, isDirectory: true) })
    }
    try manifest.json().write(to: URL(fileURLWithPath: manifestPath), options: .atomic)
    FileHandle.standardError.write(Data("demo-screens: drew and sealed \(manifest.screens.count) screenshots\n".utf8))
} catch {
    fail("drawing or sealing failed: \(error)", 13)
}
