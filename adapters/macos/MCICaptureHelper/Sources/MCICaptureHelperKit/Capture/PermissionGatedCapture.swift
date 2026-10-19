// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Reading that runs beside the focused-window session, such as whole-screen
/// reading (`BackgroundCaptureSession`). It reads only while the session is
/// not paused on a permission: the session starts it once its own stream is
/// up, pauses it when a permission goes off, and starts it again when every
/// permission is back (`SCStreamCaptureSession.attachPermissionGatedCapture`).
/// So "paused on a permission", which the readiness receipt and the helper's
/// `tcc_revoked` line report, holds for the whole helper.
public protocol PermissionGatedCapture: AnyObject, Sendable {
    /// Starts reading; a no-op while it already reads.
    func start()
    /// Stops reading until `start()` again.
    func pause() async
}
