import Foundation
import ScreenCaptureKit

enum CaptureRuntimeFailureSite: String, Sendable {
    case streamDelegate = "stream_delegate"
    case startupTeardown = "startup_teardown"
    case rebindTeardown = "rebind_teardown"
    case tccPauseTeardown = "tcc_pause_teardown"
    case tccResumeTeardown = "tcc_resume_teardown"
}

/// A bounded value snapshot. Never retain an Error or inspect its userInfo,
/// underlying errors, description, or any other content-bearing property.
struct CaptureRuntimeDiagnostic: Sendable {
    let failure: CaptureRuntimeFailure
    let site: CaptureRuntimeFailureSite
    private let errorDomain: String
    private let errorCode: Int?

    init(failure: CaptureRuntimeFailure, site: CaptureRuntimeFailureSite, error: Error?) {
        self.failure = failure
        self.site = site
        if let error = error as NSError? {
            // Emit only fixed literals, never the supplied domain string.
            switch error.domain {
            case SCStreamErrorDomain: errorDomain = "SCStreamErrorDomain"
            case NSOSStatusErrorDomain: errorDomain = "NSOSStatusErrorDomain"
            case NSPOSIXErrorDomain: errorDomain = "NSPOSIXErrorDomain"
            case NSCocoaErrorDomain: errorDomain = "NSCocoaErrorDomain"
            default: errorDomain = "other"
            }
            errorCode = error.code
        } else {
            errorDomain = "none"
            errorCode = nil
        }
    }

    var healthLogLine: String {
        let failureToken: String
        switch failure {
        case .streamStoppedUnexpectedly: failureToken = "streamStoppedUnexpectedly"
        case .userStoppedCapture: failureToken = "userStoppedCapture"
        }
        return "mci-capture-helper: helper_health capture_runtime_failed=\(failureToken) "
            + "failure_site=\(site.rawValue) error_domain=\(errorDomain) "
            + "error_code=\(errorCode.map { String($0) } ?? "none")\n"
    }
}
