// SPDX-License-Identifier: TBD-private
//
// CaptureLaunchOptionsTests — OS-FREE proof of ADR-0013 Amendment 1 §4:
// the live-capture path is DEFAULT-OFF and only the explicit,
// non-default `--capture` token can flip it on. This is the test that
// backs the §4 default-OFF assertion in the CSO sign-off block.

import XCTest

@testable import MCICaptureHelperKit

final class CaptureLaunchOptionsTests: XCTestCase {
    func test_default_is_OFF_with_no_args() {
        XCTAssertFalse(CaptureLaunchOptions.parse([]).captureEnabled)
    }

    func test_default_is_OFF_with_only_program_name() {
        XCTAssertFalse(
            CaptureLaunchOptions.parse(["mci-capture-helper"]).captureEnabled
        )
    }

    func test_other_flags_do_not_enable_capture() {
        // Every non-`--capture` flag the helper accepts ⇒ still OFF.
        let argv = [
            "mci-capture-helper",
            "--once",
            "--output", "/tmp/frames.bin",
            "--denylist", "/tmp/denylist.toml",
            "--heartbeat-seconds", "30",
        ]
        XCTAssertFalse(CaptureLaunchOptions.parse(argv).captureEnabled)
    }

    func test_explicit_capture_flag_enables_it() {
        XCTAssertTrue(
            CaptureLaunchOptions.parse(["mci-capture-helper", "--capture"]).captureEnabled
        )
    }

    func test_capture_flag_position_independent() {
        XCTAssertTrue(
            CaptureLaunchOptions.parse(["--capture", "--heartbeat-seconds", "30"]).captureEnabled
        )
        XCTAssertTrue(
            CaptureLaunchOptions.parse(["x", "--output", "/tmp/a", "--capture"]).captureEnabled
        )
    }

    func test_capture_flag_token_is_the_documented_one() {
        XCTAssertEqual(CaptureLaunchOptions.captureFlag, "--capture")
    }
}
