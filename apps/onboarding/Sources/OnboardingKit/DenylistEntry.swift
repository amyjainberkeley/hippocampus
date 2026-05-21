import Foundation

public struct DenylistEntry: Sendable, Equatable, Identifiable {
    public enum EntryType: String, Sendable, Equatable, CaseIterable {
        case bundleId
        case windowTitle
        case urlPattern
    }

    public enum Source: Sendable, Equatable {
        case csoRatified
        case userAdded
    }

    public var id: String { "\(type.rawValue):\(value)" }
    public let type: EntryType
    public let value: String
    public let source: Source

    public init(type: EntryType, value: String, source: Source) {
        self.type = type
        self.value = value
        self.source = source
    }
}
