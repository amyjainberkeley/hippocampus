import Foundation

public enum StorageMeasurementStatus: String, Codable, Sendable {
    case complete, missing, unreadable, symlink, unsupported, partial, overflow
    case limitReached = "limit_reached"
}

/// Content-free logical bytes. A partial value is only the measured portion.
public struct StorageMeasurement: Codable, Equatable, Sendable {
    public let logicalBytes: UInt64?
    public let status: StorageMeasurementStatus

    public init(logicalBytes: UInt64?, status: StorageMeasurementStatus) {
        self.logicalBytes = logicalBytes
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case logicalBytes = "logical_bytes"
        case status
    }
}

/// Best-effort file sizes, not allocated disk blocks or an atomic snapshot.
public struct StorageUsage: Codable, Equatable, Sendable {
    public let database: StorageMeasurement
    public let wal: StorageMeasurement
    public let shm: StorageMeasurement
    public let managedBlobs: StorageMeasurement
    public let reportedTotalBytes: UInt64?
    public let complete: Bool

    public init(
        database: StorageMeasurement, wal: StorageMeasurement, shm: StorageMeasurement,
        managedBlobs: StorageMeasurement, reportedTotalBytes: UInt64?, complete: Bool
    ) {
        self.database = database
        self.wal = wal
        self.shm = shm
        self.managedBlobs = managedBlobs
        self.reportedTotalBytes = reportedTotalBytes
        self.complete = complete
    }

    private enum CodingKeys: String, CodingKey {
        case database, wal, shm, complete
        case managedBlobs = "managed_blobs"
        case reportedTotalBytes = "reported_total_bytes"
    }
}

public extension StorageUsage {
    /// The database and its two working files as one measurement, the way a
    /// person thinks of them: text. Complete when each is measured or absent,
    /// otherwise it carries the first problem found.
    var textMeasurement: StorageMeasurement {
        let parts = [database, wal, shm]
        var bytes: UInt64 = 0
        for part in parts {
            let (sum, overflow) = bytes.addingReportingOverflow(part.logicalBytes ?? 0)
            if overflow { return StorageMeasurement(logicalBytes: nil, status: .overflow) }
            bytes = sum
        }
        let problem = parts.first { $0.status != .complete && $0.status != .missing }?.status
        return StorageMeasurement(logicalBytes: bytes, status: problem ?? .complete)
    }
}
