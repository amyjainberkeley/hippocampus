// SPDX-License-Identifier: TBD-private

/// Keeps privacy-heartbeat probes separate from content extraction.
///
/// The cascade floor is allowed to re-evaluate mutable privacy signals on a
/// frame the smart filter rejected. An allow verdict on that probe means only
/// that the surface is not currently sensitive; it does not make an idle or
/// otherwise incomplete surface useful OCR input.
public enum OCRDispatchPolicy {
    public static func shouldSubmit(
        outcome: SCStreamPipeline.Outcome?,
        hasInput: Bool
    ) -> Bool {
        guard hasInput else { return false }
        guard case .encoded(_, let forcedByFloor) = outcome else { return false }
        return !forcedByFloor
    }
}
