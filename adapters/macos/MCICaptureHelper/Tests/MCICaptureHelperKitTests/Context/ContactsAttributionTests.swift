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
    // Lazy construction and authorization, using no Contacts framework store
    // ------------------------------------------------------------------

    func testConstructionAndUnauthorizedResolutionNeverCreateStore() {
        let factory = ContactsStoreFactorySpy()
        let attribution = ContactsAttribution(storeFactory: factory.makeStore)
        XCTAssertEqual(factory.calls, 0)
        XCTAssertNil(attribution.resolve(participant: "alice@example.com"))
        XCTAssertNil(attribution.resolve(participant: "tel:+1-415-555-1234"))
        XCTAssertNil(attribution.resolve(participant: "not a participant"))
        XCTAssertEqual(factory.calls, 0)
        XCTAssertEqual(factory.store.requests, 0)
        XCTAssertTrue(factory.store.participants.isEmpty)
    }

    func testExplicitStartRequestsAccessAndPendingOrDeniedAccessCannotRead() {
        let factory = ContactsStoreFactorySpy()
        let attribution = ContactsAttribution(storeFactory: factory.makeStore)
        attribution.start()
        XCTAssertEqual(factory.calls, 1)
        XCTAssertEqual(factory.store.requests, 1)
        XCTAssertNil(attribution.resolve(participant: "alice@example.com"))
        XCTAssertTrue(factory.store.participants.isEmpty)
        factory.store.completeAccess(granted: false)
        XCTAssertNil(attribution.resolve(participant: "alice@example.com"))
        XCTAssertTrue(factory.store.participants.isEmpty)
        XCTAssertEqual(factory.calls, 1)
    }

    func testGrantedAccessNormalizesAndCachesOnlyTheOpaqueReference() {
        let factory = ContactsStoreFactorySpy()
        let attribution = ContactsAttribution(storeFactory: factory.makeStore)
        attribution.start()
        factory.store.completeAccess(granted: true)
        let expected = ContactRef(identifier: "synthetic-contact")
        XCTAssertEqual(attribution.resolve(participant: "mailto:Alice@Example.COM"), expected)
        XCTAssertEqual(attribution.resolve(participant: "alice@example.com"), expected)
        XCTAssertEqual(factory.store.participants, ["alice@example.com"])
        XCTAssertEqual(factory.calls, 1)
    }

    func testRepeatedExplicitStartsReuseOneStoreAndPreserveAccessRequests() {
        let factory = ContactsStoreFactorySpy()
        let attribution = ContactsAttribution(storeFactory: factory.makeStore)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in attribution.start() }
        XCTAssertEqual(factory.calls, 1)
        XCTAssertEqual(factory.store.requests, 8)
        XCTAssertTrue(factory.store.participants.isEmpty)
    }
}

private final class ContactsStoreFactorySpy: @unchecked Sendable {
    let store = FakeContactsStore()
    private let lock = NSLock()
    private var creations = 0
    var calls: Int { lock.withLock { creations } }

    func makeStore() -> any ContactsAttributionStore {
        lock.withLock { creations += 1 }
        return store
    }
}

private final class FakeContactsStore: ContactsAttributionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable (Bool) -> Void] = []
    private var observedParticipants: [String] = []
    var requests: Int { lock.withLock { callbacks.count } }
    var participants: [String] { lock.withLock { observedParticipants } }

    func requestAccess(completion: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { callbacks.append(completion) }
    }

    func completeAccess(granted: Bool) {
        let callback = lock.withLock { callbacks.last }
        callback?(granted)
    }

    func resolve(participant: String) -> ContactRef? {
        lock.withLock { observedParticipants.append(participant) }
        return ContactRef(identifier: "synthetic-contact")
    }
}
