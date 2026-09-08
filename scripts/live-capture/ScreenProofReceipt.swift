import Foundation

struct ScreenProofSystemWindow {
    let number: Int
    let ownerPid: Int
    let layer: Int
}

struct ScreenProofForeground {
    let fixturePid: Int
    let fixtureWindowNumber: Int
    let systemPidBefore: Int?
    let systemPidAfter: Int?
    let systemFrontmostNormalWindowNumber: Int?
    let windowServerQuerySucceeded: Bool
    let fixtureWindowFound: Bool
    let appActive: Bool
    let windowKey: Bool
    let windowVisible: Bool
    let textFocused: Bool

    init(fixturePid: Int, fixtureWindowNumber: Int, systemPidBefore: Int?, systemPidAfter: Int?,
         windows: [ScreenProofSystemWindow]?, appActive: Bool, windowKey: Bool,
         windowVisible: Bool, textFocused: Bool) {
        self.fixturePid = fixturePid
        self.fixtureWindowNumber = fixtureWindowNumber
        self.systemPidBefore = systemPidBefore
        self.systemPidAfter = systemPidAfter
        self.windowServerQuerySucceeded = windows != nil
        self.fixtureWindowFound = fixtureWindowNumber > 0 && windows?.contains {
            $0.ownerPid == fixturePid && $0.number == fixtureWindowNumber
        } == true
        // WindowServer stacking order is not AX focused-window identity.
        self.systemFrontmostNormalWindowNumber = systemPidBefore != nil && systemPidBefore == systemPidAfter
            ? windows?.first { $0.ownerPid == systemPidAfter && $0.layer == 0 }?.number : nil
        self.appActive = appActive
        self.windowKey = windowKey
        self.windowVisible = windowVisible
        self.textFocused = textFocused
    }

    var eligible: Bool {
        fixturePid > 0 && systemPidBefore == fixturePid && systemPidAfter == fixturePid
            && fixtureWindowFound && systemFrontmostNormalWindowNumber == fixtureWindowNumber
            && appActive && windowKey && windowVisible && textFocused
    }

    var fields: [String: Any] {
        [
            "fixture_pid": fixturePid,
            "fixture_window_number": fixtureWindowNumber,
            "system_frontmost_pid_before": systemPidBefore as Any? ?? NSNull(),
            "system_frontmost_pid_after": systemPidAfter as Any? ?? NSNull(),
            "system_frontmost_pid_stable": systemPidBefore != nil && systemPidBefore == systemPidAfter,
            "system_frontmost_normal_window_number": systemFrontmostNormalWindowNumber as Any? ?? NSNull(),
            "window_server_query_succeeded": windowServerQuerySucceeded,
            "window_server_fixture_window_found": fixtureWindowFound,
            "app_was_active": appActive,
            "window_was_key": windowKey,
            "window_was_visible": windowVisible,
            "text_was_focused": textFocused,
            "exposure_eligible": eligible,
        ]
    }
}

struct ScreenProofObservationBudget {
    enum Action { case sample, wait, finish }
    static let duration: TimeInterval = 120
    let startedAt: TimeInterval
    private var previous: TimeInterval?
    private var previousSlot: Int?
    private var sampleCount = 0
    private(set) var isFinished = false

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
    }

    func permitsGeneration(at time: TimeInterval) -> Bool {
        !isFinished && time.isFinite && time >= startedAt && time - startedAt < Self.duration
    }

    mutating func next(at time: TimeInterval) -> Action {
        guard !isFinished else { return .wait }
        guard permitsGeneration(at: time), time >= (previous ?? startedAt), sampleCount < 120 else {
            isFinished = true
            return .finish
        }
        // Timer jitter must not discard a new elapsed-second slot.
        let slot = Int(time - startedAt)
        if previousSlot == slot { return .wait }
        previous = time
        previousSlot = slot
        sampleCount += 1
        return .sample
    }
}

struct ScreenProofReceipt {
    enum Kind: String, CaseIterable {
        case fixtureReady = "fixture_ready"
        case foregroundObservation = "foreground_observation"
        case phraseGenerated = "phrase_generated"
        case exposureObservation = "exposure_observation"
        case observationFinished = "observation_finished"
    }
    enum Error: Swift.Error { case invalidHash }
    let kind: Kind
    let atUs: UInt64
    let phraseHash: String?
    let foreground: ScreenProofForeground?
    let seconds: Int

    func encodedLine() throws -> Data {
        if let phraseHash {
            guard phraseHash.utf8.count == 64,
                  phraseHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Error.invalidHash
            }
        }
        var fields: [String: Any] = [
            "schema_version": 2,
            "record_type": kind.rawValue,
            "observed_at_us": atUs,
            "phrase_sha256": phraseHash as Any? ?? NSNull(),
            "continuous_seconds": seconds,
            "foreground": foreground?.fields as Any? ?? NSNull(),
        ]
        if kind == .phraseGenerated { fields["generated_at_us"] = atUs }
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) + Data([10])
    }
}
