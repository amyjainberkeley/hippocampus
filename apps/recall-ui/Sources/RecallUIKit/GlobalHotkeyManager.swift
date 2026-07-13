// GlobalHotkeyManager.swift — system-wide hotkey binding for the
// Spotlight-like recall popup (CEO-directed flagship feature).
//
// # Why Carbon `RegisterEventHotKey` instead of NSEvent/CGEventTap
//
// Three paths exist for global hotkeys on macOS in 2026:
//
// 1. `NSEvent.addGlobalMonitorForEvents` — observes but cannot
//    consume the event; the frontmost app still sees the ⇧⌘Space
//    keystroke and may act on it (Safari intercepts it, for example).
//    Unusable for a Spotlight-like binding.
// 2. `CGEventTap` — can consume, but requires the Accessibility TCC
//    grant (`NSAccessibilityUsageDescription`). Adding a second TCC
//    prompt on first launch is a UX regression we don't need.
// 3. `RegisterEventHotKey` (Carbon HIToolbox) — the API Spotlight,
//    Alfred, Raycast, and Cotypist all use. Documented, stable since
//    macOS 10.7, no entitlement required, cleanly consumes the event
//    so the frontmost app never sees it.
//
// We take path 3. Carbon is soft-deprecated but not going anywhere:
// Apple's own frameworks still call it for hotkey registration and
// there is no SwiftUI or AppKit replacement as of macOS 15.
//
// # Protocol seam for tests
//
// The Carbon C-API can't be exercised from a headless XCTest process
// (it needs a run-loop and an app in the process activation state).
// `GlobalHotkeyRegistrar` is the protocol that abstracts the register/
// unregister/fire path; the production `CarbonHotkeyRegistrar` calls
// the real API, and `MockHotkeyRegistrar` in the tests captures
// registrations and lets the test manually fire the callback.
//
// # Thread safety
//
// Carbon calls back on the main thread's Carbon event loop, which
// bridges to the AppKit main run loop. All manager state is main-
// actor-isolated so the SwiftUI show/hide side-effects run on the
// right actor without dispatch hops.

import Foundation

/// Modifier flags accepted by the hotkey manager. Raw values match
/// Carbon `cmdKey` / `shiftKey` / `optionKey` / `controlKey` exactly
/// so the production registrar can pass them straight through.
public struct HotkeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let command = HotkeyModifiers(rawValue: 256)
    public static let shift = HotkeyModifiers(rawValue: 512)
    public static let option = HotkeyModifiers(rawValue: 2048)
    public static let control = HotkeyModifiers(rawValue: 4096)
}

/// A single hotkey spec — a virtual-key code plus modifier mask. The
/// default (⇧⌘Space) is `.spotlightLikeDefault`.
public struct HotkeySpec: Sendable, Hashable {
    /// Carbon virtual-key code (`kVK_Space` = 49).
    public let keyCode: UInt32
    public let modifiers: HotkeyModifiers
    /// Human-readable description for menu items / help text.
    public let displayLabel: String

    public init(keyCode: UInt32, modifiers: HotkeyModifiers, displayLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayLabel = displayLabel
    }

    /// ⇧⌘Space — differentiates from ⌘Space (Spotlight) + matches
    /// Raycast's default (cycle 8.45 peer study §3).
    public static let spotlightLikeDefault = HotkeySpec(
        keyCode: 49,
        modifiers: [.command, .shift],
        displayLabel: "⇧⌘Space"
    )
}

/// Outcome of an attempted hotkey registration.
public enum HotkeyRegistrationResult: Sendable, Equatable {
    case ok
    case alreadyRegistered
    case osError(Int32)
}

/// Protocol seam so `GlobalHotkeyManager` can be tested without
/// touching the Carbon C-API. Production impl is
/// `CarbonHotkeyRegistrar`; tests use `MockHotkeyRegistrar`.
public protocol GlobalHotkeyRegistrar: AnyObject, Sendable {
    /// Register `spec` and store `onFire` for invocation. Returns
    /// `.alreadyRegistered` if a spec is already active — the caller
    /// must `unregister()` first if it wants to rebind.
    func register(
        _ spec: HotkeySpec,
        onFire: @escaping @Sendable () -> Void
    ) -> HotkeyRegistrationResult

    /// Remove the currently-registered hotkey, if any. Idempotent.
    func unregister()
}

/// Main-actor-facing manager. The one entry point the app calls.
/// Owns one `GlobalHotkeyRegistrar` for the process lifetime.
@MainActor
public final class GlobalHotkeyManager {
    public static let shared = GlobalHotkeyManager(
        registrar: DefaultRegistrarFactory.make()
    )

    private let registrar: GlobalHotkeyRegistrar
    private(set) var currentSpec: HotkeySpec?
    private(set) var lastResult: HotkeyRegistrationResult?

    public init(registrar: GlobalHotkeyRegistrar) {
        self.registrar = registrar
    }

    /// Register the default ⇧⌘Space binding. Idempotent — calling
    /// twice with the same spec is a no-op that returns
    /// `.alreadyRegistered`. `onFire` runs on the main actor.
    @discardableResult
    public func registerDefault(
        onFire: @escaping @MainActor () -> Void
    ) -> HotkeyRegistrationResult {
        register(spec: .spotlightLikeDefault, onFire: onFire)
    }

    @discardableResult
    public func register(
        spec: HotkeySpec,
        onFire: @escaping @MainActor () -> Void
    ) -> HotkeyRegistrationResult {
        if let cur = currentSpec, cur == spec {
            lastResult = .alreadyRegistered
            return .alreadyRegistered
        }
        // Rebind: drop the old registration first so Carbon doesn't
        // return "hot key already exists" for the shared 4-char sig.
        if currentSpec != nil {
            registrar.unregister()
            currentSpec = nil
        }
        let result = registrar.register(spec) {
            // Carbon's callback isn't statically main-actor; hop.
            Task { @MainActor in onFire() }
        }
        if result == .ok {
            currentSpec = spec
        }
        lastResult = result
        return result
    }

    public func unregister() {
        registrar.unregister()
        currentSpec = nil
    }

    /// Human-readable string for menu items / help text. `nil` when
    /// no hotkey is currently bound.
    public var displayLabel: String? { currentSpec?.displayLabel }
}

// ---------------------------------------------------------------------------
// Production registrar — Carbon RegisterEventHotKey.
// ---------------------------------------------------------------------------

/// Factory that returns the production Carbon registrar. Split out
/// so the `.shared` initializer doesn't require calling into Carbon
/// at type-load time (test binaries never construct `.shared`).
enum DefaultRegistrarFactory {
    static func make() -> GlobalHotkeyRegistrar {
        CarbonHotkeyRegistrar()
    }
}

import Carbon.HIToolbox

/// Registers a single hotkey via `RegisterEventHotKey`. The 4-char
/// signature `'MCIH'` (MCI Hotkey) + id 1 uniquely identifies our
/// binding to the Carbon event manager. Do NOT change the signature
/// once shipped — Carbon caches by (sig, id) and stale entries can
/// stick around across app restarts if the process crashes without
/// running `UnregisterEventHotKey`.
final class CarbonHotkeyRegistrar: GlobalHotkeyRegistrar, @unchecked Sendable {
    private let signature: OSType = OSType(bitPattern: 0x4D434948)  // 'MCIH'
    private let hotkeyID: UInt32 = 1

    private var hotkeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onFire: (@Sendable () -> Void)?

    func register(
        _ spec: HotkeySpec,
        onFire: @escaping @Sendable () -> Void
    ) -> HotkeyRegistrationResult {
        if hotkeyRef != nil {
            return .alreadyRegistered
        }
        self.onFire = onFire

        // Install the process-wide dispatch handler once. Carbon
        // routes every hotkey firing through our C trampoline; the
        // trampoline looks up `self` via the user-data pointer and
        // calls `onFire`.
        var handlerSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &handlerSpec,
            selfPtr,
            &handlerRef
        )
        guard installStatus == noErr else {
            return .osError(installStatus)
        }

        var hkID = EventHotKeyID(signature: signature, id: hotkeyID)
        let regStatus = RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers.rawValue,
            hkID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        guard regStatus == noErr else {
            // Clean up the handler so the next attempt starts fresh.
            if let h = handlerRef {
                RemoveEventHandler(h)
                handlerRef = nil
            }
            return .osError(regStatus)
        }
        return .ok
    }

    func unregister() {
        if let hk = hotkeyRef {
            UnregisterEventHotKey(hk)
            hotkeyRef = nil
        }
        if let h = handlerRef {
            RemoveEventHandler(h)
            handlerRef = nil
        }
        onFire = nil
    }

    fileprivate func fire() {
        onFire?()
    }

    deinit {
        // Never leak the Carbon registration — the process could be
        // relaunched and Carbon would reject the next Register call.
        if let hk = hotkeyRef { UnregisterEventHotKey(hk) }
        if let h = handlerRef { RemoveEventHandler(h) }
    }
}

/// C trampoline. Carbon requires a plain-C function pointer; we
/// recover `self` from the user-data slot and dispatch to Swift.
private func hotkeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let registrar = Unmanaged<CarbonHotkeyRegistrar>
        .fromOpaque(userData)
        .takeUnretainedValue()
    registrar.fire()
    return noErr
}
