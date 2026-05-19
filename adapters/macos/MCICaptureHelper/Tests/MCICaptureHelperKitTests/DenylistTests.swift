// SPDX-License-Identifier: TBD-private

import XCTest
@testable import MCICaptureHelperKit

final class DenylistTests: XCTestCase {
    func testAppBundleExactMatch() {
        let d = Denylist(entries: [
            DenylistEntry(kind: .appBundle, pattern: "com.1password.1password7"),
        ])
        XCTAssertTrue(d.appIsDenied(bundleId: "com.1password.1password7"))
        XCTAssertFalse(d.appIsDenied(bundleId: "com.apple.Safari"))
    }

    func testURLPrefixMatch() {
        let d = Denylist(entries: [
            DenylistEntry(kind: .urlPrefix, pattern: "https://accounts.google.com/"),
        ])
        XCTAssertTrue(d.urlIsDenied("https://accounts.google.com/signin"))
        XCTAssertFalse(d.urlIsDenied("https://google.com/search"))
    }

    func testWindowTitleSubstringMatch() {
        let d = Denylist(entries: [
            DenylistEntry(kind: .windowTitleSubstring, pattern: "Unlock Vault"),
        ])
        XCTAssertTrue(d.windowTitleIsDenied("1Password — Unlock Vault"))
        XCTAssertTrue(d.windowTitleIsDenied("Bitwarden — Unlock Vault"))
        XCTAssertFalse(d.windowTitleIsDenied("Safari"))
    }

    func testEmptyDenylistMatchesNothing() {
        let d = Denylist(entries: [])
        XCTAssertFalse(d.appIsDenied(bundleId: "com.x"))
        XCTAssertFalse(d.urlIsDenied("https://example.com/"))
        XCTAssertFalse(d.windowTitleIsDenied("anything"))
    }
}
