// SPDX-License-Identifier: TBD-private
//
// SafariURLProvider — `URLProvider` impl for Safari (bundle id
// `com.apple.Safari`). ADR-0015 §6 P2.3.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. This is the FIRST PR in the
// repo that introduces AppleScript / Apple Events. The ADR-0015 §4
// privacy invariants govern every behaviour in this file:
//
//   1. context-as-content — the produced URL string is user content;
//      this file reads it only into the return value of
//      `activeTabURL(forFrontmost:)`. Callers route it through the
//      ADR-0013 cascade before any storage / IPC sink (cascade
//      wiring is ADR-0015 §6 P2.5, not this PR).
//   2. cascade-before-storage — vacuous this PR (no cascade wiring;
//      provider ships in isolation per ADR-0015 §6).
//   3. no auto-grant Apple Events — NO `tccutil` call, NO programmatic
//      permission API, NO "click here to grant" UX. The OS Automation-
//      pane dialog firing on the first `NSAppleScript` execution IS
//      the consent UX. User mediation only. Denial → return `nil`;
//      no retry-storm (single invocation per cache window).
//   4. real `appBundleId` in tombstone — vacuous this PR (cascade
//      wiring at P2.5).
//
// ## Behaviour summary
//
// - `bundleId != "com.apple.Safari"` → `nil` (this provider does not
//   handle that browser; the composite at P2.4 dispatches by bundle
//   id).
// - Otherwise: run a one-line AppleScript
//   `tell application "Safari" to URL of front document`
//   via `NSAppleScript`. On success with a non-empty string → return
//   the URL. On any error (permission denial, browser not running,
//   no front document, AppleScript syntax / runtime error) → `nil`.
//   On execution exceeding 250 ms → `nil` (the AppleScript may still
//   complete on its dispatch queue; its result is discarded).
//   Never retry within the same call.
// - Cache the last result (success-string or `nil`) for ≤1 s. The
//   ADR-0015 §3 snapshot actor polls at 1 Hz; the cache caps
//   AppleScript invocations to ~1/s in the worst case.

import Foundation

/// Outcome of one `NSAppleScript` invocation. The Real and Stub
/// runners both produce this; `SafariURLProvider` consumes it.
///
/// Three distinct outcomes (not just `String?`) so the cascade can
/// account for `timeout` separately from clean `nil` if future
/// telemetry needs to (today both collapse to `nil` at the
/// `URLProvider` boundary).
public enum AppleScriptOutcome: Sendable, Equatable {
    /// AppleScript executed cleanly and returned a string result.
    case success(String)
    /// AppleScript produced an error (denial, no front document,
    /// syntax, runtime). Single category here so the provider does
    /// not need to disambiguate by error code.
    case scriptError
    /// Execution exceeded the supplied timeout. The underlying
    /// `NSAppleScript` invocation may still be running and its
    /// eventual result is discarded.
    case timeout
}

/// Indirection seam in front of `NSAppleScript` so tests can drive
/// the `SafariURLProvider` decision matrix headlessly without
/// touching Apple Events. Internal: production wiring uses
/// `RealAppleScriptRunner`; tests inject a stub.
internal protocol AppleScriptRunner: Sendable {
    /// Execute `source` and return its outcome. Implementations MUST
    /// respect `timeoutMs` (return `.timeout` rather than blocking
    /// the caller indefinitely).
    func run(_ source: String, timeoutMs: Int) -> AppleScriptOutcome
}

/// Production runner. Executes `NSAppleScript` on a private serial
/// `DispatchQueue`; the calling thread waits on a semaphore bounded
/// by `timeoutMs`. If the semaphore times out, the in-flight
/// AppleScript continues on the dispatch queue and its result is
/// dropped — the caller has already returned `.timeout`.
internal struct RealAppleScriptRunner: AppleScriptRunner {
    private static let queue = DispatchQueue(
        label: "mci.context.applescript.runner",
        qos: .utility
    )

    init() {}

    func run(_ source: String, timeoutMs: Int) -> AppleScriptOutcome {
        let sem = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        Self.queue.async {
            let outcome: AppleScriptOutcome
            if let script = NSAppleScript(source: source) {
                var errInfo: NSDictionary?
                let desc = script.executeAndReturnError(&errInfo)
                if errInfo != nil {
                    outcome = .scriptError
                } else if let s = desc.stringValue, !s.isEmpty {
                    outcome = .success(s)
                } else {
                    outcome = .scriptError
                }
            } else {
                outcome = .scriptError
            }
            box.set(outcome)
            sem.signal()
        }
        let wait = sem.wait(timeout: .now() + .milliseconds(timeoutMs))
        if wait == .timedOut { return .timeout }
        return box.value ?? .scriptError
    }
}

/// Thread-safe single-shot outcome holder used by
/// `RealAppleScriptRunner` to hand the AppleScript result across
/// the dispatch-queue / caller boundary.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: AppleScriptOutcome?
    func set(_ v: AppleScriptOutcome) {
        lock.lock(); _value = v; lock.unlock()
    }
    var value: AppleScriptOutcome? {
        lock.lock(); defer { lock.unlock() }; return _value
    }
}

/// Active-tab URL provider for Safari. ADR-0015 §6 P2.3.
public final class SafariURLProvider: URLProvider, @unchecked Sendable {
    /// `com.apple.Safari` — the only bundle id this provider answers
    /// for. All other ids resolve to `nil` so the composite at P2.4
    /// can dispatch by bundle id without this provider over-
    /// shadowing other browsers.
    public static let bundleId: String = "com.apple.Safari"

    /// AppleScript source. One-line per ADR-0015 §1.3.
    internal static let script: String =
        "tell application \"Safari\" to URL of front document"

    /// Cache TTL. ADR-0015 §3 sets the snapshot poll at 1 Hz; this
    /// TTL caps AppleScript invocations to ~1/s worst case.
    internal static let cacheTTL: TimeInterval = 1.0

    /// Bounded AppleScript execution. NSAppleScript blocks the
    /// dispatching thread; a stuck call should not stall the
    /// snapshot poll forever.
    internal static let timeoutMs: Int = 250

    private let runner: AppleScriptRunner
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var cachedAt: Date?
    private var cachedValue: String?

    /// Production initializer. Wires the real `NSAppleScript`-backed
    /// runner + the system clock.
    public convenience init() {
        self.init(runner: RealAppleScriptRunner(), clock: { Date() })
    }

    /// Test initializer. Internal so tests in the same module can
    /// inject a stub runner + synthetic clock; production callers
    /// use the convenience init above.
    internal init(
        runner: AppleScriptRunner,
        clock: @escaping @Sendable () -> Date
    ) {
        self.runner = runner
        self.clock = clock
    }

    public func activeTabURL(forFrontmost bundleId: String) -> String? {
        guard bundleId == Self.bundleId else { return nil }

        let now = clock()

        lock.lock()
        if let at = cachedAt,
           now.timeIntervalSince(at) <= Self.cacheTTL {
            let cached = cachedValue
            lock.unlock()
            return cached
        }
        lock.unlock()

        let outcome = runner.run(Self.script, timeoutMs: Self.timeoutMs)
        let resolved: String?
        switch outcome {
        case .success(let url):
            resolved = url.isEmpty ? nil : url
        case .scriptError, .timeout:
            resolved = nil
        }

        lock.lock()
        cachedAt = now
        cachedValue = resolved
        lock.unlock()
        return resolved
    }
}
