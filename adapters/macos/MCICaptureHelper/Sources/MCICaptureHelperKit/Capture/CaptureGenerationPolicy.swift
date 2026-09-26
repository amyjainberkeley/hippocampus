// SPDX-License-Identifier: TBD-private

/// Pure admission rule for focused-window capture callbacks.
///
/// A callback is trusted only when the stream that produced its pixels, the
/// currently installed stream, and the latest focused-window observation all
/// name the same non-zero generation. This rejects callbacks already queued by
/// a replaced stream without relying on callback timing.
public enum CaptureGenerationPolicy {
    public static func shouldAdmit(
        streamGeneration: UInt64?,
        installedGeneration: UInt64,
        observedGeneration: UInt64?
    ) -> Bool {
        guard let streamGeneration,
              let observedGeneration,
              streamGeneration != 0
        else {
            return false
        }
        return streamGeneration == installedGeneration
            && streamGeneration == observedGeneration
    }
}
