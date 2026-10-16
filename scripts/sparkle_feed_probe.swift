// SPDX-License-Identifier: Apache-2.0
//
// sparkle_feed_probe.swift — Ask Sparkle itself what an installed app would
// make of a feed. It loads the feed the way the app does (SPUUpdater,
// checkForUpdateInformation) for a stand-in host bundle and prints what
// Sparkle found. It shows no UI and downloads, installs and launches nothing.
//
// Build against the app's own Sparkle (see scripts/test-sparkle-publish.sh):
//   xcrun swiftc -F <Sparkle.xcframework slice> -framework Sparkle \
//       -Xlinker -rpath -Xlinker <slice> sparkle_feed_probe.swift -o probe
// Run with HOME and CFFIXED_USER_HOME pointing at a scratch folder, so
// Sparkle's preferences for the stand-in bundle stay out of your home:
//   probe HOST.app FEED_URL [CHANNEL]
// CHANNEL also accepts items in that Sparkle channel (e.g. "beta").
//
// Output, one fact per line: appcast-items, appcast-signing (0 skipped,
// 1 succeeded, 2 failed), then found/enclosure/description-format/
// minimum-system for a valid update, or no-update/abort with Sparkle's error.
// Exit: 0 update found, 3 no update, 4 aborted, 5 updater did not start,
// 6 timed out, 64-65 usage.
import Foundation
import Sparkle

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: sparkle_feed_probe HOST_BUNDLE FEED_URL [CHANNEL]\n".utf8))
    exit(64)
}

/// Answers every question Sparkle could ask with "no" and shows nothing.
final class QuietUserDriver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation _: @escaping () -> Void) {}
    func showUpdateFound(with _: SUAppcastItem, state _: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.dismiss)
    }

    func showUpdateReleaseNotes(with _: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_: any Error) {}
    func showUpdateNotFoundWithError(_: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdaterError(_: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { cancellation() }
    func showDownloadDidReceiveExpectedContentLength(_: UInt64) {}
    func showDownloadDidReceiveData(ofLength _: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.dismiss) }
    func showInstallingUpdate(withApplicationTerminated _: Bool, retryTerminatingApplication _: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {}
}

final class ProbeDelegate: NSObject, SPUUpdaterDelegate {
    let feed: String
    let channel: String?

    init(feed: String, channel: String?) {
        self.feed = feed
        self.channel = channel
    }

    func feedURLString(for _: SPUUpdater) -> String? { feed }

    func allowedChannels(for _: SPUUpdater) -> Set<String> {
        channel.map { [$0] } ?? []
    }

    func updater(_: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        print("appcast-items: \(appcast.items.count)")
        print("appcast-signing: \(appcast.signingValidationStatus.rawValue)")
    }

    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        print("found: \(item.displayVersionString) build \(item.versionString)")
        print("enclosure: \(item.fileURL?.absoluteString ?? "none")")
        print("description-format: \(item.itemDescriptionFormat ?? "none")")
        print("minimum-system: \(item.minimumSystemVersion ?? "none")")
        exit(0)
    }

    func updaterDidNotFindUpdate(_: SPUUpdater, error: any Error) {
        let nsError = error as NSError
        print("no-update: \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)")
        exit(3)
    }

    func updater(_: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        print("abort: \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)")
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            print("underlying: \(underlying.domain) \(underlying.code) \(underlying.localizedDescription)")
        }
        exit(4)
    }
}

guard let host = Bundle(path: arguments[1]) else {
    print("abort: no bundle at \(arguments[1])")
    exit(65)
}
let userDriver = QuietUserDriver()
let delegate = ProbeDelegate(feed: arguments[2], channel: arguments.count == 4 ? arguments[3] : nil)
let updater = SPUUpdater(hostBundle: host, applicationBundle: host, userDriver: userDriver, delegate: delegate)
do {
    try updater.start()
} catch {
    print("start-failed: \(error.localizedDescription)")
    exit(5)
}
updater.checkForUpdateInformation()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 60))
print("timeout")
exit(6)
