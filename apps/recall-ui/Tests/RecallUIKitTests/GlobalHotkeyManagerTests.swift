// GlobalHotkeyManagerTests.swift — verify the manager's register /
// rebind / unregister state machine using a mock registrar. The
// Carbon C-API isn't exercised in unit tests (needs a run loop +
// app activation state); a separate manual smoke test covers the
// production registrar on a real login session.

import XCTest
@testable import RecallUIKit

/// Mock registrar that records calls and lets the test manually fire
/// the callback — same protocol-seam pattern as the ⌘K Action Panel
/// tests (PR #74).
final class MockHotkeyRegistrar: GlobalHotkeyRegistrar, @unchecked Sendable {
    var registeredSpec: HotkeySpec?
    var unregisterCallCount: Int = 0
    var stubbedResult: HotkeyRegistrationResult = .ok
    private var onFire: (@Sendable () -> Void)?

    func register(
        _ spec: HotkeySpec,
        onFire: @escaping @Sendable () -> Void
    ) -> HotkeyRegistrationResult {
        self.registeredSpec = spec
        self.onFire = onFire
        return stubbedResult
    }

    func unregister() {
        unregisterCallCount += 1
        registeredSpec = nil
        onFire = nil
    }

    func fire() { onFire?() }
}

@MainActor
final class GlobalHotkeyManagerTests: XCTestCase {
    func testDefaultSpecIsShiftCommandSpace() {
        XCTAssertEqual(HotkeySpec.spotlightLikeDefault.keyCode, 49)
        XCTAssertTrue(
            HotkeySpec.spotlightLikeDefault.modifiers.contains(.command)
        )
        XCTAssertTrue(
            HotkeySpec.spotlightLikeDefault.modifiers.contains(.shift)
        )
        XCTAssertFalse(
            HotkeySpec.spotlightLikeDefault.modifiers.contains(.option)
        )
        XCTAssertEqual(HotkeySpec.spotlightLikeDefault.displayLabel, "⇧⌘Space")
    }

    func testRegisterDefaultRoutesThroughToRegistrar() {
        let mock = MockHotkeyRegistrar()
        let mgr = GlobalHotkeyManager(registrar: mock)
        let result = mgr.registerDefault {}
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(mock.registeredSpec, .spotlightLikeDefault)
        XCTAssertEqual(mgr.currentSpec, .spotlightLikeDefault)
        XCTAssertEqual(mgr.displayLabel, "⇧⌘Space")
    }

    func testFireInvokesCallback() async {
        let mock = MockHotkeyRegistrar()
        let mgr = GlobalHotkeyManager(registrar: mock)
        var fireCount = 0
        _ = mgr.registerDefault { fireCount += 1 }
        mock.fire()
        // Callback hops through @MainActor Task — await a tick.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(fireCount, 1)
    }

    func testDoubleRegisterSameSpecShortCircuits() {
        let mock = MockHotkeyRegistrar()
        let mgr = GlobalHotkeyManager(registrar: mock)
        _ = mgr.registerDefault {}
        let second = mgr.registerDefault {}
        XCTAssertEqual(second, .alreadyRegistered)
        // Only one call through to the underlying registrar.
        XCTAssertEqual(mock.unregisterCallCount, 0)
    }

    func testRebindingReleasesOldSpecFirst() {
        let mock = MockHotkeyRegistrar()
        let mgr = GlobalHotkeyManager(registrar: mock)
        _ = mgr.registerDefault {}
        let alt = HotkeySpec(
            keyCode: 49,
            modifiers: [.command, .option],
            displayLabel: "⌥⌘Space"
        )
        let result = mgr.register(spec: alt) {}
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(mock.registeredSpec, alt)
        XCTAssertEqual(mgr.currentSpec, alt)
        XCTAssertEqual(mock.unregisterCallCount, 1)
    }

    func testFailedRegistrationDoesNotSetCurrentSpec() {
        let mock = MockHotkeyRegistrar()
        mock.stubbedResult = .osError(-9878)
        let mgr = GlobalHotkeyManager(registrar: mock)
        let result = mgr.registerDefault {}
        XCTAssertEqual(result, .osError(-9878))
        XCTAssertNil(mgr.currentSpec)
        XCTAssertEqual(mgr.lastResult, .osError(-9878))
    }

    func testUnregisterClearsState() {
        let mock = MockHotkeyRegistrar()
        let mgr = GlobalHotkeyManager(registrar: mock)
        _ = mgr.registerDefault {}
        mgr.unregister()
        XCTAssertNil(mgr.currentSpec)
        XCTAssertNil(mgr.displayLabel)
        XCTAssertEqual(mock.unregisterCallCount, 1)
    }

    func testCarbonModifierRawValuesMatchCarbonConstants() {
        // Pin the raw values so a refactor doesn't accidentally
        // remap them — Carbon RegisterEventHotKey takes these
        // constants directly, so drift would silently break the
        // production binding.
        XCTAssertEqual(HotkeyModifiers.command.rawValue, 256)
        XCTAssertEqual(HotkeyModifiers.shift.rawValue, 512)
        XCTAssertEqual(HotkeyModifiers.option.rawValue, 2048)
        XCTAssertEqual(HotkeyModifiers.control.rawValue, 4096)
    }
}
