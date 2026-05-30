import XCTest
@testable import OnboardingKit

@MainActor
final class AllowlistEditorViewModelTests: XCTestCase {

    private func makeVM(
        baselineEntries: [AllowlistEntry] = StubAllowlistStore.defaultEntries,
        userEntries: [UserAllowlistEntry] = [],
        detectedApps: [DetectedApp] = StubRunningAppsDetector.defaultApps,
        fdaStatus: FullDiskAccessStatus = .notRequested
    ) -> (AllowlistEditorViewModel, InMemoryUserAllowlistStore, StubFullDiskAccessPermission) {
        let userStore = InMemoryUserAllowlistStore(entries: userEntries)
        let fda = StubFullDiskAccessPermission(initial: fdaStatus)
        let vm = AllowlistEditorViewModel(
            baselineStore: StubAllowlistStore(entries: baselineEntries),
            userStore: userStore,
            detector: StubRunningAppsDetector(apps: detectedApps),
            fdaPermission: fda,
            dateProvider: { "2026-05-29" }
        )
        return (vm, userStore, fda)
    }

    // MARK: - Load

    func testLoadPopulatesBaselineAndDetectedRows() async {
        let (vm, _, _) = makeVM()
        await vm.load()
        XCTAssertEqual(
            vm.baselineEntries.count,
            StubAllowlistStore.defaultEntries.count
        )
        // Baseline rows are first; detected apps not already in baseline follow.
        let baselineRows = vm.rows.filter { $0.isBaselineEntry }
        XCTAssertEqual(baselineRows.count, StubAllowlistStore.defaultEntries.count)

        let detectedRows = vm.rows.filter { !$0.isBaselineEntry }
        XCTAssertGreaterThan(detectedRows.count, 0)
        XCTAssertTrue(detectedRows.allSatisfy { $0.posture == .off })
    }

    func testLoadRestoresUserPostureFromStore() async {
        let user = [
            UserAllowlistEntry(
                bundleId: "com.spotify.client",
                captureEnabled: true,
                deepHookEnabled: false,
                addedAt: "2026-05-28"
            ),
            UserAllowlistEntry(
                bundleId: "com.apple.MobileSMS",
                captureEnabled: true,
                deepHookEnabled: true,
                addedAt: "2026-05-28"
            ),
        ]
        let (vm, _, _) = makeVM(userEntries: user)
        await vm.load()
        let spotify = vm.rows.first { $0.bundleId == "com.spotify.client" }
        XCTAssertEqual(spotify?.posture, .captureOnly)
        let messages = vm.rows.first { $0.bundleId == "com.apple.MobileSMS" }
        XCTAssertEqual(messages?.posture, .captureAndDeepHook)
    }

    // MARK: - Toggles

    func testSetPostureFromOffToCapturePersists() async {
        let (vm, userStore, _) = makeVM()
        await vm.load()
        await vm.setPosture(for: "com.spotify.client", to: .captureOnly)

        let persisted = await userStore.entriesForTest()
        let spotify = persisted.first { $0.bundleId == "com.spotify.client" }
        XCTAssertEqual(spotify?.captureEnabled, true)
        XCTAssertEqual(spotify?.deepHookEnabled, false)
    }

    func testSetPostureDeepHookTriggersFDARequest() async {
        let (vm, _, fda) = makeVM()
        await vm.load()
        await vm.setPosture(
            for: "com.apple.MobileSMS",
            to: .captureAndDeepHook
        )
        let status = await fda.status()
        XCTAssertEqual(status, .requested)
    }

    func testSetPostureDeepHookSilentlyDowngradesForUnsupportedBundle() async {
        let (vm, _, fda) = makeVM()
        await vm.load()
        // Spotify is NOT in the deepHookableBundles set.
        await vm.setPosture(
            for: "com.spotify.client",
            to: .captureAndDeepHook
        )
        let spotify = vm.rows.first { $0.bundleId == "com.spotify.client" }
        XCTAssertEqual(spotify?.posture, .captureOnly)
        // FDA must NOT have been requested.
        let status = await fda.status()
        XCTAssertEqual(status, .notRequested)
    }

    func testBaselineRowPostureCannotBeChanged() async {
        let (vm, userStore, _) = makeVM()
        await vm.load()
        let baselineBundle = StubAllowlistStore.defaultEntries.first!.bundleId
        await vm.setPosture(for: baselineBundle, to: .off)
        let persisted = await userStore.entriesForTest()
        // Baseline bundle MUST NOT appear in the user-layer (it's already trusted).
        XCTAssertFalse(persisted.contains { $0.bundleId == baselineBundle })
    }

    // MARK: - Custom add

    func testAddCustomBundleSucceedsAndPersists() async {
        let (vm, userStore, _) = makeVM()
        await vm.load()
        let err = await vm.addCustomBundle(
            bundleId: "com.example.special",
            rationale: "Internal tool"
        )
        XCTAssertNil(err)
        let persisted = await userStore.entriesForTest()
        let added = persisted.first { $0.bundleId == "com.example.special" }
        XCTAssertNotNil(added)
        XCTAssertEqual(added?.captureEnabled, true)
        XCTAssertEqual(added?.rationale, "Internal tool")
    }

    func testAddCustomBundleRefusesEmpty() async {
        let (vm, _, _) = makeVM()
        await vm.load()
        let err = await vm.addCustomBundle(bundleId: "   ")
        XCTAssertEqual(err, .emptyBundleId)
        XCTAssertEqual(vm.lastError, .emptyBundleId)
    }

    func testAddCustomBundleRefusesBaselineDuplicate() async {
        let (vm, _, _) = makeVM()
        await vm.load()
        let baselineBundle = StubAllowlistStore.defaultEntries.first!.bundleId
        let err = await vm.addCustomBundle(bundleId: baselineBundle)
        XCTAssertEqual(err, .duplicateOfBaseline(bundleId: baselineBundle))
    }

    func testAddCustomBundleRefusesUserLayerDuplicate() async {
        let (vm, _, _) = makeVM()
        await vm.load()
        _ = await vm.addCustomBundle(bundleId: "com.example.dup")
        let err = await vm.addCustomBundle(bundleId: "com.example.dup")
        XCTAssertEqual(err, .duplicateOfUserLayer(bundleId: "com.example.dup"))
    }

    func testRemoveUserEntryDropsIt() async {
        let (vm, userStore, _) = makeVM()
        await vm.load()
        _ = await vm.addCustomBundle(bundleId: "com.example.toremove")
        await vm.removeUserEntry(bundleId: "com.example.toremove")
        let persisted = await userStore.entriesForTest()
        XCTAssertFalse(persisted.contains { $0.bundleId == "com.example.toremove" })
    }

    func testRemoveUserEntryDoesNotTouchBaseline() async {
        let (vm, _, _) = makeVM()
        await vm.load()
        let baselineBundle = StubAllowlistStore.defaultEntries.first!.bundleId
        await vm.removeUserEntry(bundleId: baselineBundle)
        XCTAssertTrue(vm.rows.contains { $0.bundleId == baselineBundle && $0.isBaselineEntry })
    }

    // MARK: - Reload preserves prior state

    func testReloadAfterPersistRestoresPosture() async {
        let (vm, userStore, _) = makeVM()
        await vm.load()
        await vm.setPosture(for: "com.spotify.client", to: .captureOnly)

        let (vm2, _, _) = makeVM(
            userEntries: await userStore.entriesForTest()
        )
        await vm2.load()
        let spotify = vm2.rows.first { $0.bundleId == "com.spotify.client" }
        XCTAssertEqual(spotify?.posture, .captureOnly)
    }
}
