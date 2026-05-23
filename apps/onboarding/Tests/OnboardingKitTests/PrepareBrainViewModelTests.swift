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
        XCTAssertEqual(vm.modelSizeDescription, "~950 MB")
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
}
