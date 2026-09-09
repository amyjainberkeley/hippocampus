import CoreGraphics
import Foundation

struct ActivitySessionReader {
    func permitsMeasurement() -> Bool {
        Self.permitsMeasurement(CGSessionCopyCurrentDictionary() as? [String: Any],
                                userID: geteuid(), displayAwake: CGDisplayIsAsleep(CGMainDisplayID()) == 0)
    }

    static func permitsMeasurement(_ session: [String: Any]?, userID: uid_t, displayAwake: Bool) -> Bool {
        guard let session, displayAwake,
              boolean(session[kCGSessionOnConsoleKey as String]) == true,
              boolean(session[kCGSessionLoginDoneKey as String]) == true,
              let owner = session[kCGSessionUserIDKey as String] as? NSNumber,
              CFGetTypeID(owner) != CFBooleanGetTypeID(),
              owner.decimalValue == Decimal(UInt64(userID))
        else { return false }
        // This additional deny signal is supplied by WindowServer but not a
        // public SDK constant. Live lock/unlock qualification remains required.
        if let lock = session["CGSSessionScreenIsLocked"] {
            guard boolean(lock) == false else { return false }
        }
        return true
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
}
