// SPDX-License-Identifier: TBD-private
import Foundation

public enum AppGroupIdentity {
    public static let infoPlistKey = "HippocampusAppGroupIdentifier"

    public static var identifier: String? {
        identifier(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    package static func identifier(infoDictionary: [String: Any]) -> String? {
        guard let raw = infoDictionary[infoPlistKey] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
