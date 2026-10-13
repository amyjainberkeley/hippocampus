import Foundation

/// Which model writes answers, read from
/// `~/Library/Application Support/MCI/model.json` when it exists:
///
///     {"engine": "auto", "base_url": "http://127.0.0.1:11434/v1", "model": ""}
///
/// `auto`, the default, uses Apple Intelligence when it is on and otherwise a
/// model server on this Mac. `apple` and `local` use only the one. With no
/// `base_url`, Ollama's usual address is tried, then LM Studio's. An empty
/// `model` means the server's best model, found by name. A missing,
/// unreadable or malformed file, or an unknown value, means the default.
public struct EngineSettings: Codable, Sendable, Equatable {
    public enum Engine: String, Codable, Sendable { case auto, apple, local }

    public var engine: Engine
    /// The server's OpenAI address, or nil for the usual ones.
    public var baseURL: String?
    /// The model's name as the server lists it, or empty to pick one.
    public var model: String

    /// Ollama's OpenAI address.
    public static let ollama = "http://127.0.0.1:11434/v1"
    /// LM Studio's OpenAI address.
    public static let lmStudio = "http://127.0.0.1:1234/v1"

    public init(engine: Engine = .auto, baseURL: String? = nil, model: String = "") {
        self.engine = engine
        self.baseURL = baseURL
        self.model = model
    }

    /// The addresses to try, in order.
    public var baseURLs: [String] { baseURL.map { [$0] } ?? [Self.ollama, Self.lmStudio] }

    /// The settings in `home`, or in this user's home folder.
    public static func load(home: String? = nil) -> EngineSettings {
        guard let data = try? Data(contentsOf: file(home: home ?? currentHome())),
              let settings = try? JSONDecoder().decode(EngineSettings.self, from: data)
        else { return EngineSettings() }
        return settings
    }

    static func file(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/MCI/model.json")
    }

    /// `HOME`, which the agent passes, else the account's home folder.
    static func currentHome() -> String {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return home }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    enum CodingKeys: String, CodingKey { case engine, baseURL = "base_url", model }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            ((try? values.decodeIfPresent(String.self, forKey: key)) ?? nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        engine = Engine(rawValue: text(.engine).lowercased()) ?? .auto
        baseURL = text(.baseURL).isEmpty ? nil : text(.baseURL)
        model = text(.model)
    }
}
