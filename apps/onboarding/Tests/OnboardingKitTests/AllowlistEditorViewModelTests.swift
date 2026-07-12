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

    // MARK: - PR-3 regression: baseline row displayName resolution

    /// Regression test for PR-3 bug (b): before the fix,
    /// `AllowlistEditorViewModel.load()` set baseline
    /// `EditorRow.displayName = entry.bundleId`, so the user saw
    /// `com.apple.MobileSMS` instead of `Messages`. The fix pipes the
    /// bundle id through `BundleDisplayNameResolver`, which resolves
    /// via NSWorkspace → static table → camel-case prettifier.
    ///
    /// This test uses `com.apple.MobileSMS` — it lives in the static
    /// fallback table AND has a prettify fallback (`Mobile SMS`), so
    /// the assertion is tolerant to whichever branch the test host
    /// resolves through. What we care about is: it's NOT the raw
    /// bundle id anymore.
    func testBaselineRowDisplayNameIsHumanReadable() async {
        let baseline = [
            AllowlistEntry(bundleId: "com.apple.MobileSMS",
                           rationale: "Messages"),
        ]
        let (vm, _, _) = makeVM(baselineEntries: baseline)
        await vm.load()
        let messages = vm.rows.first { $0.bundleId == "com.apple.MobileSMS" }
        XCTAssertNotNil(messages)
        XCTAssertNotEqual(
            messages?.displayName,
            "com.apple.MobileSMS",
            "Baseline row must not show a raw bundle id"
        )
        // Accept either the NSWorkspace-resolved name (`Messages` on a
        // real Mac), the static-table entry (`Messages`), or the
        // camel-case prettify fallback (`Mobile SMS`).
        let acceptable: Set<String> = ["Messages", "Mobile SMS"]
        XCTAssertTrue(
            acceptable.contains(messages?.displayName ?? ""),
            "Unexpected displayName: \(messages?.displayName ?? "nil")"
        )
    }

    /// The prettify fallback path — an obviously-not-installed bundle
    /// id must still get a humanized name (never the raw id). This
    /// exercises the last rung of `BundleDisplayNameResolver`'s
    /// resolution ladder.
    func testBaselineRowDisplayNamePrettifiesUnknownBundle() async {
        let baseline = [
            AllowlistEntry(bundleId: "com.example.MobileSMS.doesNotExist",
                           rationale: "test"),
        ]
        let (vm, _, _) = makeVM(baselineEntries: baseline)
        await vm.load()
        let row = vm.rows.first {
            $0.bundleId == "com.example.MobileSMS.doesNotExist"
        }
        XCTAssertNotNil(row)
        XCTAssertNotEqual(row?.displayName,
                          "com.example.MobileSMS.doesNotExist")
        // Prettified last component: `doesNotExist` → `Does Not Exist`.
        XCTAssertEqual(row?.displayName, "Does Not Exist")
    }

    /// The camel-case splitter must handle runs of capitals correctly
    /// (`MobileSMS` → `Mobile SMS`, not `Mobile S M S`).
    func testBundleDisplayNameResolverSplitsCamelCase() {
        XCTAssertEqual(
            BundleDisplayNameResolver.splitCamelCase("MobileSMS"),
            "Mobile SMS"
        )
        XCTAssertEqual(
            BundleDisplayNameResolver.splitCamelCase("URLSession"),
            "URL Session"
        )
        XCTAssertEqual(
            BundleDisplayNameResolver.splitCamelCase("Safari"),
            "Safari"
        )
    }

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
