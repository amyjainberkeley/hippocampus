// SPDX-License-Identifier: TBD-private
import XCTest
@testable import HippocampusKit

final class MciBootGuardsTests: XCTestCase {
    /// Project constraint (Package.swift: `platforms: [.macOS(.v14)]` + the
    /// Apple-Silicon-only local-AI stack) means every dev + CI machine is
    /// Apple Silicon. If this ever returns false on a dev machine, the
    /// guard is misfiring and the app would fail-fast on boot.
    func test_hostIsAppleSilicon_returns_true_on_supported_host() {
        XCTAssertTrue(MciBootGuards.hostIsAppleSilicon(),
                      "MCI dev + CI hosts are macOS 14+ Apple Silicon per project constraint")
    }
}
