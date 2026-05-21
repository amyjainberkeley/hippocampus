import Foundation

public actor DiskRetentionStore: RetentionStore {
    private struct Persisted: Codable {
        var mode: String
        var days: Int?
        var updated_at: String
    }

    private let fileURL: URL
    private var cached: (policy: RetentionPolicy, days: Int?)?

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MCI")
        self.fileURL = dir.appendingPathComponent("retention.json")
    }

    public func currentPolicy() -> RetentionPolicy {
        loadIfNeeded()
        return cached?.policy ?? .forever
    }

    public func currentCustomDays() -> Int? {
        loadIfNeeded()
        return cached?.days
    }

    public func setPolicy(_ policy: RetentionPolicy, customDays: Int?) {
        cached = (policy, customDays)
        writeToDisk(policy: policy, days: customDays)
    }

    private func loadIfNeeded() {
        if cached != nil { return }
        guard let data = try? Data(contentsOf: fileURL),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data),
              let policy = RetentionPolicy(rawValue: persisted.mode) else {
            cached = (.forever, nil)
            return
        }
        cached = (policy, persisted.days)
    }

    private func writeToDisk(policy: RetentionPolicy, days: Int?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let persisted = Persisted(
            mode: policy.rawValue,
            days: days,
            updated_at: ISO8601DateFormatter().string(from: Date())
        )
        guard let data = try? encoder.encode(persisted) else { return }

        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = dir.appendingPathComponent("retention.json.\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
