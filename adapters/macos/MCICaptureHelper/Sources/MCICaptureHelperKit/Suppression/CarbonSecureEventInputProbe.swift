// SPDX-License-Identifier: TBD-private
//
// CarbonSecureEventInputProbe — concrete `SecureEventInputProbe`
// backed by the Carbon syscall `IsSecureEventInputEnabled()`.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. This is the ADR-0013 cascade
// §3 probe. The bit is process-wide on macOS — set by any process
// that calls `EnableSecureEventInput()` (Cocoa `NSSecureTextField`
// when focused, Terminal sudo, 1Password vault unlock, pinentry,
// LSCustomReceiverIcon helpers used by password managers). When this
// bit is true the cascade suppresses the WHOLE event — no pixels,
// no metadata cross IPC.
//
// The struct holds no state; every call is a fresh syscall. ADR-0013
// §3 specifies "re-poll on every state transition" — that polling
// rhythm is the caller's responsibility. The probe itself is
// `Sendable` so it can be invoked from any thread.

import Carbon

/// Concrete `SecureEventInputProbe` backed by Carbon.
public struct CarbonSecureEventInputProbe: SecureEventInputProbe {
    public init() {}

    /// One Carbon syscall. Returns true iff ANY process in the current
    /// login session has secure event input enabled.
    public func isSecureEventInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }
}
