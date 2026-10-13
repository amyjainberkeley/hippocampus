// SPDX-License-Identifier: TBD-private
import Foundation

@MainActor
public protocol CaptureSettingApplying: AnyObject {
    var captureEnabled: Bool { get }
    func applyCaptureEnabled(_ enabled: Bool) async throws
}

@MainActor
public final class CapturePreferenceController: ObservableObject {
    @Published public private(set) var captureEnabled: Bool
    @Published public private(set) var isApplying = false
    @Published public private(set) var errorMessage: String?

    private let applier: any CaptureSettingApplying

    public static let couldNotChange = "Couldn’t change that. Try again."

    public init(applier: any CaptureSettingApplying) {
        self.applier = applier
        self.captureEnabled = applier.captureEnabled
    }

    public func setCaptureEnabled(_ enabled: Bool) async {
        guard !isApplying else { return }
        isApplying = true
        errorMessage = nil
        do {
            try await applier.applyCaptureEnabled(enabled)
        } catch {
            // The status row above says where things stand; this says only
            // that the switch did not take. No raw error text (spec-copy S2).
            errorMessage = Self.couldNotChange
        }
        captureEnabled = applier.captureEnabled
        isApplying = false
    }
}
