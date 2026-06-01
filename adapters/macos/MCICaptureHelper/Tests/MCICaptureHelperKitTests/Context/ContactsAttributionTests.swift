// SPDX-License-Identifier: TBD-private
//
// ContactsAttributionTests — Phase 6 PR 5 (SH Fork D1).
//
// Production reads `CNContactStore`; tests inject a stub
// `ContactsAttributionSource` so the cascade-equivalent contract is
// exercisable without a real Contacts framework / TCC prompt.

import XCTest
@testable import MCICaptureHelperKit

final class StubContactsAttributionSource: ContactsAttributionSource, @unchecked Sendable {
    private let lock = NSLock()
    private var resolutions: [String: ContactRef]
    private var _calls: Int = 0
    /// When true, every resolve returns nil — emulates TCC-denied state.
    private var _denyAll: Bool

    init(resolutions: [String: ContactRef] = [:], denyAll: Bool = false) {
        self.resolutions = resolutions
        self._denyAll = denyAll
    }

    func set(participant: String, to ref: ContactRef?) {
        lock.lock(); defer { lock.unlock() }
        if let ref { resolutions[participant] = ref }
        else { resolutions.removeValue(forKey: participant) }
    }

    func denyAll(_ deny: Bool) {
        lock.lock(); defer { lock.unlock() }
        _denyAll = deny
    }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func resolve(participant: String) -> ContactRef? {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        if _denyAll { return nil }
        return resolutions[participant]
    }
}

final class ContactsAttributionTests: XCTestCase {

    // ------------------------------------------------------------------
    // Normalization — strip mailto: + lowercase email, digit-only phone
    // ------------------------------------------------------------------

    func testNormalizeStripsMailtoAndLowercases() {
        XCTAssertEqual(
            ContactsAttribution.normalizeParticipant("mailto:Foo@Example.COM"),
            "foo@example.com"
        )
        XCTAssertEqual(
            ContactsAttribution.normalizeParticipant("  Alice@Example.com  "),
            "alice@example.com"
        )
    }

    func testNormalizeStripsTelAndKeepsDigits() {
        XCTAssertEqual(
            ContactsAttribution.normalizeParticipant("tel:+1-415-555-1234"),
            "14155551234"
        )
        XCTAssertEqual(
            ContactsAttribution.normalizeParticipant("(415) 555-1234"),
            "4155551234"
        )
    }

    func testNormalizeRejectsNonParticipantShapes() {
        XCTAssertEqual(ContactsAttribution.normalizeParticipant(""), "")
        XCTAssertEqual(
            ContactsAttribution.normalizeParticipant("just-a-string"),
            ""
        )
        // Too few digits to be a phone.
        XCTAssertEqual(ContactsAttribution.normalizeParticipant("1234"), "")
        // `@` without a domain dot is not an email.
        XCTAssertEqual(
            ContactsAttribution.normalizeParticipant("foo@bar"),
            ""
        )
    }

    // ------------------------------------------------------------------
    // Stub-based resolution — TCC-granted + TCC-denied + miss
    // ------------------------------------------------------------------

    func testStubResolvesKnownParticipant() {
        let ref = ContactRef(identifier: "ABCD-1234")
        let stub = StubContactsAttributionSource(
            resolutions: ["alice@example.com": ref]
        )
        XCTAssertEqual(stub.resolve(participant: "alice@example.com"), ref)
    }

    func testStubMissReturnsNil() {
        let stub = StubContactsAttributionSource(resolutions: [:])
        XCTAssertNil(stub.resolve(participant: "unknown@example.com"))
    }

    func testStubDenyAllReturnsNilForEveryParticipant() {
        let stub = StubContactsAttributionSource(
            resolutions: ["alice@example.com": ContactRef(identifier: "id-1")],
            denyAll: true
        )
        // Even a known participant returns nil under TCC-deny.
        XCTAssertNil(stub.resolve(participant: "alice@example.com"))
    }

    // ------------------------------------------------------------------
    // Production constructor — no exception in headless CI
    // ------------------------------------------------------------------

    func testProductionConstructorBindsCleanly() {
        let attribution = ContactsAttribution()
        // Before start() / auth callback, resolve returns nil (the
        // safe direction). The query path is internally guarded by
        // authState != .granted; this test pins that contract
        // without prompting the user.
        XCTAssertNil(attribution.resolve(participant: "alice@example.com"))
    }
}
