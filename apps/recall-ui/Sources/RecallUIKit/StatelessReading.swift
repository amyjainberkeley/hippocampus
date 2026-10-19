#if DEBUG
import CMciBrainFFI
import Foundation

/// The Rust reader's reading of text that was never stored
/// (`mci_brain_ffi_reading`): `main`, `rest` and a caption made from the
/// title. Nothing is read from memory and no handle is opened. Debug builds
/// only: the window's renders use it so their made-up moments read exactly as
/// the reader reads stored text.
public enum StatelessReading {
    public struct Result: Decodable, Sendable, Equatable {
        public let main: String
        public let rest: String
        public let caption: String?
    }

    public static func read(stored: String, source: String, app: String?, title: String?,
                            url: String? = nil) -> Result? {
        var input: [String: String] = ["stored": stored, "source": source]
        input["app"] = app
        input["title"] = title
        input["url"] = url
        guard let data = try? JSONSerialization.data(withJSONObject: input),
              let json = String(data: data, encoding: .utf8),
              let raw = json.withCString({ mci_brain_ffi_reading($0) }) else { return nil }
        defer { mci_brain_ffi_string_free(raw) }
        return try? JSONDecoder().decode(Result.self, from: Data(String(cString: raw).utf8))
    }
}
#endif
