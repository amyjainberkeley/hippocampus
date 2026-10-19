import AppKit
import RecallUIKit
import SwiftUI

/// Where the window's screenshots come from: the encrypted store in the app,
/// synthetic encrypted fixtures in the off-screen renderer.
private struct ScreenshotsKey: EnvironmentKey {
    static let defaultValue: any ThumbnailDataProviding = AppScreenshots()
}

extension EnvironmentValues {
    var screenshots: any ThumbnailDataProviding {
        get { self[ScreenshotsKey.self] }
        set { self[ScreenshotsKey.self] = newValue }
    }
}

/// The app's provider, reached only when an image is asked for.
private struct AppScreenshots: ThumbnailDataProviding {
    func thumbnailData(for url: URL, maxPixelSize: Int) async -> Data? {
        await ThumbnailDataProvider.shared.thumbnailData(for: url, maxPixelSize: maxPixelSize)
    }

    func screenshotData(for url: URL) async -> Data? {
        await ThumbnailDataProvider.shared.screenshotData(for: url)
    }

    func rereadScreenshotData(for url: URL) async -> Data? {
        await ThumbnailDataProvider.shared.rereadScreenshotData(for: url)
    }
}

/// The only UI path from an encrypted keyframe blob to visible pixels.
///
/// The screenshot opens when the view appears, off the main thread, through
/// the provider (authenticated, decrypted and downsized in memory; nothing
/// is ever written to disk): at most `maxPixelSize` pixels, or the saved image
/// when `fullResolution`. A moment without a screenshot, one still opening and
/// one that cannot be opened all show the moment's app calmly (`MomentTile`),
/// never a broken image. With `showsStatus` the tile also says which.
struct EvidenceThumbnail: View {
    let url: URL?
    /// The moment's app, shown when there is no screenshot to show.
    var appBundleId: String? = nil
    let size: CGSize
    let maxPixelSize: Int
    var contentMode: ContentMode = .fit
    /// Where a filled picture is anchored when it is cut to the tile: the
    /// top keeps a tall window's heading.
    var alignment: Alignment = .center
    var showsStatus = false
    var fullResolution = false
    /// Nil uses the window's (`\.screenshots`).
    var provider: (any ThumbnailDataProviding)? = nil
    /// Told when the screenshot at `url` cannot be opened, so a detail can
    /// stop offering to open it.
    var onUnavailable: ((URL) -> Void)? = nil

    @Environment(\.screenshots) private var screenshots
    @State private var opened: (url: URL, image: NSImage)?
    @State private var failedURL: URL?

    private var memoKey: String? {
        url.map { "\($0.standardizedFileURL.path)#\(fullResolution ? 0 : maxPixelSize)" }
    }

    /// The image for `url`: opened by this view, or already opened by
    /// another (a row scrolled back, or a moment sharing the screenshot).
    private var image: NSImage? {
        guard let url else { return nil }
        if let opened, opened.url == url { return opened.image }
        return memoKey.flatMap { ScreenshotImageMemo.shared.image(for: $0) }
    }

    private var failed: Bool { url != nil && failedURL == url }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .frame(width: size.width, height: size.height, alignment: alignment)
                    .clipped()
                    .accessibilityHidden(true)
            } else {
                MomentTile(appBundleId: appBundleId, caption: caption, isQuiet: url != nil && !failed)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityText)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: MCI.Radius.xs, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MCI.Radius.xs, style: .continuous)
                .stroke(Color.brandCardBorder, lineWidth: 0.5)
        }
        .task(id: memoKey) { await open() }
    }

    private var caption: String? {
        guard showsStatus else { return nil }
        if url == nil { return UserFacingCopy.textOnly }
        return failed ? UserFacingCopy.screenshotLoadFailed : nil
    }

    private var accessibilityText: String {
        if url == nil { return UserFacingCopy.noScreenshot }
        return failed ? UserFacingCopy.screenshotLoadFailed : UserFacingCopy.momentTextLoading
    }

    private func open() async {
        guard let url, let memoKey else { return }
        let picture = await MomentPicture.load(url: url, maxPixelSize: maxPixelSize,
                                               fullResolution: fullResolution, provider: provider ?? screenshots)
        guard !Task.isCancelled, url == self.url else { return }
        switch picture {
        case let .screenshot(data):
            guard let image = NSImage(data: data) else {
                ScreenshotImageMemo.shared.forget(memoKey)
                failedURL = url
                onUnavailable?(url)
                return
            }
            ScreenshotImageMemo.shared.keep(image, cost: data.count, for: memoKey)
            opened = (url, image)
            failedURL = nil
        case .appIcon:
            // Gone or changed since it was opened: never show it again.
            ScreenshotImageMemo.shared.forget(memoKey)
            opened = nil
            failedURL = url
            onUnavailable?(url)
        }
    }
}

/// Screenshots already opened, as images the window draws at once: a row
/// scrolled back, or another moment showing the same screenshot, never blinks.
/// In memory only, bounded, and emptied when moments are deleted. Each view
/// still asks the provider, which checks the blob, and forgets an image the
/// provider no longer opens.
@MainActor
final class ScreenshotImageMemo {
    static let shared = ScreenshotImageMemo()

    private let images = NSCache<NSString, NSImage>()
    private let deletions: MemoryDeletionSignal
    private var generation: UInt64

    init(deletions: MemoryDeletionSignal = .shared) {
        self.deletions = deletions
        generation = deletions.generation
        images.countLimit = 400
        images.totalCostLimit = 48 * 1024 * 1024
    }

    func image(for key: String) -> NSImage? {
        forgetIfDeleted()
        return images.object(forKey: key as NSString)
    }

    func keep(_ image: NSImage, cost: Int, for key: String) {
        forgetIfDeleted()
        images.setObject(image, forKey: key as NSString, cost: cost)
    }

    func forget(_ key: String) {
        images.removeObject(forKey: key as NSString)
    }

    private func forgetIfDeleted() {
        let current = deletions.generation
        guard current != generation else { return }
        images.removeAllObjects()
        generation = current
    }
}
