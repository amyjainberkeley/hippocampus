import AppKit

@main
@MainActor
struct ScreenProofReceiptTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() throws {
        let own = ScreenProofSystemWindow(number: 42, ownerPid: 100, layer: 0)
        let other = ScreenProofSystemWindow(number: 99, ownerPid: 200, layer: 0)
        func snapshot(before: Int? = 100, after: Int? = 100,
                      windows: [ScreenProofSystemWindow]? = [own, other]) -> ScreenProofForeground {
            ScreenProofForeground(fixturePid: 100, fixtureWindowNumber: 42,
                                  systemPidBefore: before, systemPidAfter: after, windows: windows,
                                  appActive: true, windowKey: true, windowVisible: true, textFocused: true)
        }
        let foreground = snapshot()
        check(foreground.eligible, "Matching system identity and AppKit focus should permit exposure")
        let background = snapshot(before: 200, after: 200)
        check(!background.eligible, "AppKit active must not override a different system PID")
        check(background.systemFrontmostNormalWindowNumber == 99, "Report the actual system app's normal window")
        let switched = snapshot(after: 200)
        check(!switched.eligible && switched.systemFrontmostNormalWindowNumber == nil,
              "A foreground race must not attribute a window to a stale PID")
        check(!snapshot(before: nil, after: nil).eligible, "Missing system PID must not match")
        check(!snapshot(windows: nil).eligible, "Unavailable WindowServer metadata must fail closed")
        check(!snapshot(windows: []).eligible, "An absent fixture window must fail closed")
        let sibling = ScreenProofSystemWindow(number: 43, ownerPid: 100, layer: 0)
        check(!snapshot(windows: [sibling, own]).eligible, "Another frontmost window in the same app must not qualify")
        let panel = ScreenProofSystemWindow(number: 44, ownerPid: 100, layer: 3)
        check(snapshot(windows: [panel, own]).systemFrontmostNormalWindowNumber == 42,
              "A panel must not be mislabeled as the frontmost normal window")

        var exposure = ScreenProofExposure()
        exposure.sample(at: 0, eligible: foreground.eligible)
        exposure.sample(at: 1, eligible: foreground.eligible)
        check(exposure.seconds == 1, "Confirmed foreground samples count")
        exposure.sample(at: 2, eligible: background.eligible)
        check(exposure.seconds == 0, "A system-only foreground loss must reset exposure")

        var budget = ScreenProofObservationBudget(startedAt: 100)
        check(budget.next(at: 100) == .sample, "Observe readiness immediately")
        check(budget.next(at: 100.5) == .wait, "Do not poll faster than once per second")
        for second in 101..<220 {
            check(budget.next(at: Double(second)) == .sample, "Observe within the bounded session")
        }
        check(budget.next(at: 220) == .finish, "Stop at the 120-second deadline")
        check(budget.next(at: 221) == .wait, "Never emit a second terminal observation")
        var invalid = ScreenProofObservationBudget(startedAt: 100)
        check(invalid.next(at: .nan) == .finish, "Invalid clocks must stop observation")
        var regressed = ScreenProofObservationBudget(startedAt: 100)
        check(regressed.next(at: 99) == .finish, "Clock regression must stop observation")
        var jitter = ScreenProofObservationBudget(startedAt: 100)
        check(jitter.next(at: 101.01) == .sample && jitter.next(at: 102.001) == .sample,
              "Small timer jitter must not discard a new elapsed-second slot")
        check(!jitter.permitsGeneration(at: 220), "Expired observation must not permit a new phrase")

        let hash = String(repeating: "a", count: 64)
        for kind in ScreenProofReceipt.Kind.allCases {
            let line = try ScreenProofReceipt(kind: kind, atUs: 123, phraseHash: hash,
                                              foreground: foreground, seconds: 20).encodedLine()
            let json = try JSONSerialization.jsonObject(with: line) as! [String: Any]
            var allowedKeys: Set<String> = ["schema_version", "record_type", "observed_at_us", "phrase_sha256",
                                            "continuous_seconds", "foreground"]
            if kind == .phraseGenerated {
                allowedKeys.insert("generated_at_us")
                check(json["generated_at_us"] as? UInt64 == 123, "Preserve the generation boundary field")
            }
            check(Set(json.keys) == allowedKeys, "Receipt fields must be explicitly allowlisted")
            let fields = json["foreground"] as! [String: Any]
            check(json["phrase_sha256"] as? String == hash, "Preserve only the hash commitment")
            check(fields["fixture_pid"] as? Int == 100 && fields["fixture_window_number"] as? Int == 42,
                  "Serialize the fixture's actual numeric identities")
            check(fields["system_frontmost_pid_after"] as? Int == 100
                  && fields["system_frontmost_normal_window_number"] as? Int == 42,
                  "System identity must remain distinct from AppKit booleans")
            check(Set(fields.keys) == ["fixture_pid", "fixture_window_number", "system_frontmost_pid_before",
                "system_frontmost_pid_after", "system_frontmost_pid_stable", "system_frontmost_normal_window_number",
                "window_server_query_succeeded", "window_server_fixture_window_found", "app_was_active",
                "window_was_key", "window_was_visible", "text_was_focused", "exposure_eligible"],
                  "Foreground receipt must contain only numeric identities and booleans")
            check(line.last == 10 && line.filter { $0 == 10 }.count == 1, "Exactly one JSON line per receipt")
        }
        let missing = try ScreenProofReceipt(kind: .fixtureReady, atUs: 1, phraseHash: nil,
                                            foreground: snapshot(windows: nil), seconds: 0).encodedLine()
        let missingJSON = try JSONSerialization.jsonObject(with: missing) as! [String: Any]
        check(missingJSON["phrase_sha256"] is NSNull, "Readiness must not imply a generated phrase")
        check((missingJSON["foreground"] as! [String: Any])["system_frontmost_normal_window_number"] is NSNull,
              "Unavailable numeric identity must be explicit null")
        do {
            _ = try ScreenProofReceipt(kind: .phraseGenerated, atUs: 1, phraseHash: "SYNTHETIC TEST CONTENT",
                                       foreground: foreground, seconds: 0).encodedLine()
            check(false, "A plaintext value must never be accepted as a hash receipt")
        } catch ScreenProofReceipt.Error.invalidHash {}

        let controls = ScreenProofControls()
        check(controls.generateButton.accessibilityIdentifier() == "screen-proof.generate", "Generate must be addressable without reading text")
        check(controls.textView.accessibilityIdentifier() == "screen-proof.phrase", "Phrase focus must be addressable without copying its value")
        check(controls.exposureLabel.accessibilityIdentifier() == "screen-proof.exposure", "Exposure must have a stable identifier")
        check(controls.textView.window == nil, "Tests must not open a window")
        print("PASS: content-free receipts, system foreground checks, sampling bounds and AX identifiers")
    }
}
