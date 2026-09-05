import Foundation

public protocol RetentionFileWriting: Sendable {
    func write(_ data: Data, to fileURL: URL) throws
}

public struct AtomicRetentionFileWriter: RetentionFileWriting {
    public init() {}

    public func write(_ data: Data, to fileURL: URL) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let temporaryURL = directory.appendingPathComponent(
            ".retention.json.\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}

public actor DiskRetentionStore: RetentionStore {
    private struct Persisted: Codable {
        var schema_version: Int?
        var mode: String
        var days: Int?
        var updated_at: String?

        private enum CodingKeys: String, CodingKey {
            case schema_version, mode, days, updated_at
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(schema_version, forKey: .schema_version)
            try container.encode(mode, forKey: .mode)
            try container.encode(days, forKey: .days)
            try container.encode(updated_at, forKey: .updated_at)
        }
    }

    private let fileURL: URL
    private let writer: any RetentionFileWriting
    private var cached: (policy: RetentionPolicy, days: Int?, needsReview: Bool)?

    public init(
        directory: URL? = nil,
        writer: any RetentionFileWriting = AtomicRetentionFileWriter()
    ) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MCI")
        self.fileURL = dir.appendingPathComponent("retention.json")
        self.writer = writer
    }

    public func currentPolicy() -> RetentionPolicy {
        loadIfNeeded()
        return cached?.policy ?? .ninetyDays
    }

    public func currentCustomDays() -> Int? {
        loadIfNeeded()
        return cached?.days
    }

    public func needsReview() -> Bool {
        loadIfNeeded()
        return cached?.needsReview ?? false
    }

    public func setPolicy(_ policy: RetentionPolicy, customDays: Int?) throws {
        let validatedDays = try policy.validatedCustomDays(customDays)
        let data = try encodedPolicy(policy, days: validatedDays)
        try writer.write(data, to: fileURL)
        cached = (policy, validatedDays, false)
    }

    private func loadIfNeeded() {
        if cached != nil { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cached = (.ninetyDays, nil, false)
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data),
              let policy = RetentionPolicy(rawValue: persisted.mode) else {
            cached = (.forever, nil, false)
            return
        }
        do {
            let validatedDays = try policy.validatedCustomDays(persisted.days)
            cached = (policy, validatedDays, policy != .forever && persisted.schema_version != 2)
        } catch {
            cached = (.forever, nil, false)
        }
    }

    private func encodedPolicy(_ policy: RetentionPolicy, days: Int?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let persisted = Persisted(
            schema_version: 2,
            mode: policy.rawValue,
            days: days,
            updated_at: ISO8601DateFormatter().string(from: Date())
        )
        return try encoder.encode(persisted)
    }
}
