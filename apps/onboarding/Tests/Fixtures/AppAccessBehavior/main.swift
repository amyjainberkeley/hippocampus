import Foundation
import OnboardingKit

@main
struct AppAccessBehavior {
    static func main() async {
        await verifySignedBaselineReadsCompleteEntries()
        await verifySignedBaselineFailsClosed()

        let userStore = InMemoryUserAllowlistStore()
        let fda = StubFullDiskAccessPermission()
        let viewModel = await MainActor.run {
            AllowlistEditorViewModel(
                baselineStore: StubAllowlistStore(entries: [
                    AllowlistEntry(
                        bundleId: "com.apple.MobileSMS",
                        rationale: "Messages"
                    ),
                ]),
                userStore: userStore,
                detector: StubRunningAppsDetector(apps: []),
                fdaPermission: fda,
                dateProvider: { "2026-05-29" }
            )
        }

        await viewModel.load()
        guard await MainActor.run(body: {
            viewModel.rows.first?.posture == .captureOnly
        }) else {
            fatalError("baseline capture policy did not remain immutable")
        }

        await viewModel.setPosture(for: "com.apple.MobileSMS", to: .captureAndDeepHook)
        guard await userStore.entriesForTest().first?.deepHookEnabled == true else {
            fatalError("baseline deep-hook opt-in did not create user consent")
        }

        await viewModel.setPosture(for: "com.apple.MobileSMS", to: .captureOnly)
        guard await userStore.entriesForTest().first?.captureEnabled == true,
              await userStore.entriesForTest().first?.deepHookEnabled == false,
              await fda.status() == .requested else {
            fatalError("baseline deep-hook opt-out did not preserve capture or FDA request")
        }
    }

    private static func verifySignedBaselineFailsClosed() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-malformed-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try """
            [[entries]]
            bundle_id = "com.apple.MobileSMS"
            rationale = "Messages"
            cso_ratified_by = "security-team"
            """.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fatalError("could not create malformed baseline fixture: \(error)")
        }

        guard await SignedBaselineAllowlistStore(url: url).entries().isEmpty else {
            fatalError("malformed baseline did not fail closed")
        }
    }

    private static func verifySignedBaselineReadsCompleteEntries() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-valid-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try """
            [[entries]]
            bundle_id = "com.apple.MobileSMS"
            rationale = "Messages"
            cso_ratified_by = "security-team"
            ratified_at = "2026-05-29"
            """.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fatalError("could not create valid baseline fixture: \(error)")
        }

        let entries = await SignedBaselineAllowlistStore(url: url).entries()
        guard entries == [
            AllowlistEntry(bundleId: "com.apple.MobileSMS", rationale: "Messages"),
        ] else {
            fatalError("valid signed baseline was not read")
        }
    }
}
