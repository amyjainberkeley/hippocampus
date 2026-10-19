// SPDX-License-Identifier: Apache-2.0
import Foundation

@MainActor
public protocol CaptureSettingApplying: AnyObject {
    var captureEnabled: Bool { get }
    /// Turn On, as from the status row: it waits out a change under way,
    /// shows Starting…, and if it cannot turn on the status row says why.
    func turnOn()
    func applyCaptureEnabled(_ enabled: Bool) async throws
}

/// Preferences' "Remember my screen" switch. The status row above it is the
/// one voice about remembering (product critique 11): the switch adds no
/// caption of its own.
@MainActor
public final class CapturePreferenceController: ObservableObject {
    @Published public private(set) var captureEnabled: Bool
    @Published public private(set) var isApplying = false

    private let applier: any CaptureSettingApplying

    public init(applier: any CaptureSettingApplying) {
        self.applier = applier
        self.captureEnabled = applier.captureEnabled
    }

    public func setCaptureEnabled(_ enabled: Bool) async {
        guard !isApplying else { return }
        if enabled {
            // The same Turn On as the menu's: a press during a start or a
            // stop waits for it instead of cancelling it, and a turn-on that
            // does not take says why in the status row, not in a caption the
            // next success would leave behind.
            applier.turnOn()
            captureEnabled = applier.captureEnabled
            return
        }
        isApplying = true
        // A turn-off that fails reads "Couldn’t stop", with Quit, in the
        // status row.
        try? await applier.applyCaptureEnabled(false)
        captureEnabled = applier.captureEnabled
        isApplying = false
    }
}
