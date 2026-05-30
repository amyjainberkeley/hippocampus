import XCTest
@testable import OnboardingKit

@MainActor
final class PrepareBrainViewModelTests: XCTestCase {

    private func makeVM(
        keyExists: Bool = false,
        modelAvailable: Bool = false
    ) -> PrepareBrainViewModel {
        PrepareBrainViewModel(
            keyGenerator: StubKeyGenerator(exists: keyExists),
            modelDownloader: StubModelDownloader(available: modelAvailable)
        )
    }

    func testInitialState() {
        let vm = makeVM()
        XCTAssertEqual(vm.keyState, .checking)
        XCTAssertEqual(vm.downloadState, .notStarted)
        XCTAssertFalse(vm.modelDownloaded)
    }

    func testGenerateKeyWhenNoneExists() async {
        let vm = makeVM(keyExists: false)
        await vm.generateKey()
        XCTAssertEqual(vm.keyState, .ready)
    }

    func testGenerateKeyWhenAlreadyExists() async {
        let vm = makeVM(keyExists: true)
        await vm.generateKey()
        XCTAssertEqual(vm.keyState, .ready)
    }

    func testCheckModelNotAvailable() async {
        let vm = makeVM(modelAvailable: false)
        await vm.checkModelAvailability()
        XCTAssertEqual(vm.downloadState, .notStarted)
    }

    func testCheckModelAlreadyAvailable() async {
        let vm = makeVM(modelAvailable: true)
        await vm.checkModelAvailability()
        XCTAssertEqual(vm.downloadState, .ready)
        XCTAssertTrue(vm.modelDownloaded)
    }

    func testSkipDownload() {
        let vm = makeVM()
        vm.skipDownload()
        XCTAssertEqual(vm.downloadState, .skipped)
        XCTAssertFalse(vm.modelDownloaded)
    }

    func testModelDisplayName() {
        let vm = makeVM()
        XCTAssertEqual(vm.modelDisplayName, "Qwen3 1.7B")
    }

    func testModelSizeDescription() {
        let vm = makeVM()
        XCTAssertEqual(vm.modelSizeDescription, "~2.5 GB")
    }

    func testStartDownloadUpdatesState() async throws {
        let vm = makeVM()
        vm.startDownload()
        try await Task.sleep(for: .milliseconds(500))
        let state = vm.downloadState
        switch state {
        case .downloading:
            break // expected — in progress
        case .ready:
            break // also fine if stub finished fast
        default:
            XCTFail("Unexpected state: \(state)")
        }
    }

    // MARK: - Re-detection regression (Phase C of the wiring audit)

    /// `checkModelAvailability` MUST reset `.ready → .notStarted` when
    /// the model disappears between probes. Previously, the function
    /// only ever set `.ready` and never recanted, so a model deletion
    /// after a successful install would leave the slide claiming
    /// "Model ready" forever. See docs/research/onboarding-wiring-
    /// audit-2026-05-30.md §4.3.
    func testCheckModelAvailabilityResetsStaleReadyWhenModelGone() async {
        let stub = ToggleableModelDownloader(initiallyAvailable: true)
        let vm = PrepareBrainViewModel(
            keyGenerator: StubKeyGenerator(exists: true),
            modelDownloader: stub
        )

        await vm.checkModelAvailability()
        XCTAssertEqual(vm.downloadState, .ready)

        await stub.setAvailable(false)
        await vm.checkModelAvailability()
        XCTAssertEqual(vm.downloadState, .notStarted)
    }

    /// `checkModelAvailability` MUST NOT flip a user-skipped state
    /// even if the FS probe disagrees.
    func testCheckModelAvailabilityPreservesSkipped() async {
        let stub = ToggleableModelDownloader(initiallyAvailable: false)
        let vm = PrepareBrainViewModel(
            keyGenerator: StubKeyGenerator(exists: true),
            modelDownloader: stub
        )

        vm.skipDownload()
        XCTAssertEqual(vm.downloadState, .skipped)

        await stub.setAvailable(true)
        await vm.checkModelAvailability()
        // The user explicitly said "skip" — don't reverse that just
        // because the model directory now happens to exist.
        XCTAssertEqual(vm.downloadState, .skipped)
    }

    /// `checkModelAvailability` MUST preserve `.failed` so the slide
    /// keeps showing the error + Retry button on slide redisplay.
    func testCheckModelAvailabilityPreservesFailed() async throws {
        let stub = AlwaysFailingModelDownloader()
        let vm = PrepareBrainViewModel(
            keyGenerator: StubKeyGenerator(exists: true),
            modelDownloader: stub
        )

        vm.startDownload()
        // Drain the task. The injected error fires synchronously
        // inside download(); a short sleep is enough.
        try await Task.sleep(for: .milliseconds(100))

        guard case .failed = vm.downloadState else {
            XCTFail("Expected .failed, got \(vm.downloadState)")
            return
        }

        await vm.checkModelAvailability()
        // .failed must survive the probe — re-detection should not
        // silently swallow a surfaced error.
        guard case .failed = vm.downloadState else {
            XCTFail("checkModelAvailability clobbered .failed → \(vm.downloadState)")
            return
        }
    }
}

/// Test-only `ModelDownloader` whose `isAvailable()` answer can flip
/// between probes — exercises the FS-truth-vs-cached-state path. The
/// shipped `StubModelDownloader` only flips to `available = true` once
/// `download()` completes, which can't model "model was installed (or
/// removed) outside the ViewModel between slide-appears."
actor ToggleableModelDownloader: ModelDownloader {
    nonisolated let modelID = "qwen3-1.7b-fp16"
    nonisolated let displayName = "Qwen3 1.7B"
    nonisolated let sizeDescription = "~2.5 GB"

    private var available: Bool

    init(initiallyAvailable: Bool) {
        self.available = initiallyAvailable
    }

    func setAvailable(_ value: Bool) {
        available = value
    }

    func isAvailable() -> Bool { available }

    func download(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        // Tests that need to exercise download() use a different
        // stub; this one only models presence/absence.
    }

    func cancel() {}
}

/// Test-only `ModelDownloader` whose `download()` always throws so
/// `PrepareBrainViewModel` reaches `.failed`.
actor AlwaysFailingModelDownloader: ModelDownloader {
    nonisolated let modelID = "qwen3-1.7b-fp16"
    nonisolated let displayName = "Qwen3 1.7B"
    nonisolated let sizeDescription = "~2.5 GB"

    struct InjectedError: LocalizedError {
        var errorDescription: String? { "injected failure for test" }
    }

    func isAvailable() -> Bool { false }

    func download(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        throw InjectedError()
    }

    func cancel() {}
}
