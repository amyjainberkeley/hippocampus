// SPDX-License-Identifier: TBD-private

/// Controls which pipeline outcomes may become the visual deduplication
/// baseline. Floor-only frames exist to re-check privacy; they are not evidence
/// that OCR consumed useful content and must remain retryable.
public enum CaptureBaselinePolicy {
    /// ScreenCaptureKit may report no dirty rectangles after the first frame
    /// of a static window. A verified empty OCR result reopens exactly one
    /// complete frame so OCR can retry without disabling the ordinary
    /// no-change energy gate.
    public static func effectiveDirtyRects(
        reported: [DirtyRect],
        frameStatusComplete: Bool,
        frameWidth: Int,
        frameHeight: Int,
        retryPending: Bool
    ) -> [DirtyRect] {
        guard reported.isEmpty,
              frameStatusComplete,
              retryPending,
              frameWidth > 0,
              frameHeight > 0
        else {
            return reported
        }
        return [DirtyRect(
            x: 0,
            y: 0,
            width: UInt32(clamping: frameWidth),
            height: UInt32(clamping: frameHeight)
        )]
    }

    public static func shouldCommit(outcome: SCStreamPipeline.Outcome?) -> Bool {
        guard case .encoded(_, forcedByFloor: false) = outcome else {
            return false
        }
        return true
    }

    /// An asynchronous OCR failure may reopen only the baseline established by
    /// that exact capture. Generation blocks cross-window rollback; ordinal
    /// blocks an older completion from clearing a newer frame in one window.
    public static func shouldRevokeForRetry(
        currentGeneration: UInt64,
        currentCaptureOrdinal: UInt64,
        retryGeneration: UInt64,
        retryCaptureOrdinal: UInt64
    ) -> Bool {
        currentCaptureOrdinal == retryCaptureOrdinal
            && currentGeneration == retryGeneration
    }
}
