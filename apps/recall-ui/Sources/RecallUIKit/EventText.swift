import Foundation

/// Stored text for one admitted event, separate from the 280-character list preview.
public struct EventText: Sendable, Equatable, Decodable {
    public static let maxUTF8Bytes = 128 * 1024
    public static let maxAppUTF8Bytes = 1024
    static let maxJSONBytes = (maxUTF8Bytes + maxAppUTF8Bytes) * 6 + 256

    public let eventId: UInt64
    public let tsUs: UInt64
    public let appBundleId: String?
    public let text: String
    public let isTruncated: Bool

    public init(eventId: UInt64, tsUs: UInt64, appBundleId: String?, text: String, isTruncated: Bool) throws {
        guard eventId > 0, eventId <= UInt64(Int64.max), tsUs <= UInt64(Int64.max),
              text.utf8.count <= Self.maxUTF8Bytes,
              (appBundleId?.utf8.count ?? 0) <= Self.maxAppUTF8Bytes else {
            throw BrainReaderError.decodeFailed("Invalid bounded event text")
        }
        self.eventId = eventId
        self.tsUs = tsUs
        self.appBundleId = appBundleId
        self.text = text
        self.isTruncated = isTruncated
    }

    public func matches(_ hit: Hit) -> Bool {
        eventId == hit.id && tsUs == hit.tsUs && appBundleId == hit.appBundleId
    }

    private enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case tsUs = "ts_us"
        case appBundleId = "app_bundle_id"
        case text
        case isTruncated = "truncated"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            eventId: values.decode(UInt64.self, forKey: .eventId),
            tsUs: values.decode(UInt64.self, forKey: .tsUs),
            appBundleId: values.decode(String?.self, forKey: .appBundleId),
            text: values.decode(String.self, forKey: .text),
            isTruncated: values.decode(Bool.self, forKey: .isTruncated)
        )
    }
}
