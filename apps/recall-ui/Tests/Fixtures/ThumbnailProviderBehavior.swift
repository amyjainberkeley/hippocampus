import AppKit
import Foundation
import MCIKeyframeCodec
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
struct ThumbnailProviderBehavior {
    static func main() async throws {
        if let mode = CommandLine.arguments.firstIndex(of: "--open-in-memory") {
            await openInMemory(Array(CommandLine.arguments.dropFirst(mode + 1)))
            return
        }
        try proveDevelopmentKeyRequiresExplicitGate()
        try proveDevelopmentKeyCanUseSupervisorFileReference()
        await proveStoredBriefDoesNotDependOnOptionalModel()
        proveAppDisplayNames()
        precondition(RecallTab.from(deepLinkValue: "now") == .now)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hippocampus-thumbnail-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = Data((0 ..< 32).map(UInt8.init))
        let sealed = try KeyframeBlobCodec.seal(
            plaintext: try imageData(),
            keyMaterial: key
        )
        let blobURL = root
            .appendingPathComponent(sealed.lowercaseHexDigest)
            .appendingPathExtension("bin")
        try sealed.bytes.write(to: blobURL, options: .atomic)

        let loads = LockedCounter()
        let provider = ThumbnailDataProvider(blobRoot: root) {
            loads.increment()
            return key
        }

        let thumbnail = await provider.thumbnailData(for: blobURL, maxPixelSize: 24)
        precondition(thumbnail != nil, "valid authenticated blob must render")
        precondition(loads.read() == 1, "Keychain material must resolve once per session")

        _ = await provider.thumbnailData(for: blobURL, maxPixelSize: 24)
        precondition(loads.read() == 1, "subsequent reads must reuse resolved key material")

        var tampered = sealed.bytes
        tampered[tampered.count - 1] ^= 0xff
        try tampered.write(to: blobURL, options: .atomic)
        let tamperedThumbnail = await provider.thumbnailData(for: blobURL, maxPixelSize: 24)
        precondition(
            tamperedThumbnail == nil,
            "digest mismatch must fail closed"
        )

        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("\(sealed.lowercaseHexDigest).bin")
        try sealed.bytes.write(to: outside, options: .atomic)
        defer { try? FileManager.default.removeItem(at: outside) }
        let outsideThumbnail = await provider.thumbnailData(for: outside, maxPixelSize: 24)
        precondition(
            outsideThumbnail == nil,
            "paths outside the blob root must fail closed"
        )

        try FileManager.default.removeItem(at: blobURL)
        try FileManager.default.createSymbolicLink(at: blobURL, withDestinationURL: outside)
        let symlinkThumbnail = await provider.thumbnailData(for: blobURL, maxPixelSize: 24)
        precondition(
            symlinkThumbnail == nil,
            "symlink blobs must fail closed"
        )
    }

    /// `--open-in-memory <blob root> <key hex> <blob>`: open one synthetic
    /// encrypted screenshot the ways the window does (list thumbnail, detail
    /// picture, the saved image, and each again from memory), write nothing,
    /// and print for each result its size and a slice of its bytes in hex.
    /// `HistoryScreenshotTests` runs this with a private HOME and TMPDIR and
    /// then looks for those bytes in every file there.
    private static func openInMemory(_ arguments: [String]) async {
        guard arguments.count == 3,
              let key = hexBytes(arguments[1]), key.count == 32
        else {
            print("usage: --open-in-memory <blob root> <key hex> <blob>")
            exit(64)
        }
        let provider = ThumbnailDataProvider(blobRoot: URL(fileURLWithPath: arguments[0], isDirectory: true)) { key }
        let blob = URL(fileURLWithPath: arguments[2])
        var results: [(String, Data?)] = []
        for round in 1...2 {
            results.append(("list-\(round)", await provider.thumbnailData(for: blob, maxPixelSize: 160)))
            results.append(("detail-\(round)", await provider.thumbnailData(for: blob, maxPixelSize: 640)))
            results.append(("saved-\(round)", await provider.screenshotData(for: blob)))
        }
        for (name, data) in results {
            guard let data, data.count >= 96 else {
                print("\(name) missing")
                exit(1)
            }
            let middle = data.count / 2
            let slice = data[data.startIndex + middle ..< data.startIndex + middle + 48]
            print("\(name) \(data.count) \(slice.map { String(format: "%02x", $0) }.joined())")
        }
    }

    private static func hexBytes(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func proveDevelopmentKeyRequiresExplicitGate() throws {
        let raw = String(repeating: "aB", count: 32)
        let disabled = try DevelopmentDatabaseKeyMaterial.hex(from: [
            "MCI_DB_KEY_HEX": raw,
        ])
        let enabled = try DevelopmentDatabaseKeyMaterial.hex(from: [
            "MCI_DEVELOPMENT_FILE_KEY": "1",
            "MCI_DB_KEY_HEX": raw,
        ])
        precondition(disabled == nil)
        precondition(enabled == raw.lowercased())
    }

    private static func proveDevelopmentKeyCanUseSupervisorFileReference() throws {
        let keyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hippocampus-recall-key-\(UUID().uuidString)")
        let raw = String(repeating: "cD", count: 32)
        try Data(raw.utf8).write(to: keyURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: keyURL) }

        let resolved = try DevelopmentDatabaseKeyMaterial.hex(from: [
            "MCI_DEVELOPMENT_FILE_KEY": "1",
            "MCI_DB_KEY_FILE": keyURL.path,
        ])

        precondition(resolved == raw.lowercased())
    }

    @MainActor
    private static func proveStoredBriefDoesNotDependOnOptionalModel() async {
        let viewModel = BriefViewModel(
            reader: StubBrainReader()
        )

        await viewModel.reload()

        guard case .brief = viewModel.scene else {
            preconditionFailure("stored extractive brief must render without an optional model")
        }
    }

    private static func proveAppDisplayNames() {
        precondition(Formatters.appDisplayName("com.apple.Safari") == "Safari")
        precondition(Formatters.appDisplayName("com.microsoft.VSCode") == "VS Code")
        precondition(Formatters.appDisplayName("com.tinyspeck.slackmacgap") == "Slack")
        precondition(Formatters.appDisplayName("com.mci.demo.seed.github") == "GitHub")
        precondition(Formatters.appDisplayName("com.example.my-app") == "My App")
        precondition(Formatters.appDisplayName(nil) == "Unknown app")
    }

    private static func imageData() throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 20,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
            let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }
}
