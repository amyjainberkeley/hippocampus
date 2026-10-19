// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a moment's picture shows: its screenshot, or its app's icon.
///
/// Many moments are saved as text only, and a kept screenshot can go missing
/// or fail to open. Neither is ever drawn as a broken image: both show the
/// app's own icon, calmly, and only a detail view says which it was.
public enum MomentPicture: Equatable, Sendable {
    /// The screenshot, opened in memory (JPEG or PNG data).
    case screenshot(Data)
    /// The app's icon in place of a screenshot.
    case appIcon(Reason)

    public enum Reason: Equatable, Sendable {
        /// No screenshot was kept for the moment, only its text.
        case textOnly
        /// A screenshot was kept but could not be opened.
        case unavailable
    }

    /// How many pixels to open a moment's screenshot at for a pane of `size`
    /// points on a display of `scale`: sharp there, in steps of 256 so that
    /// resizing the window does not open it again at every point, and never
    /// past the provider's thumbnail bound (the saved image itself opens in
    /// the screenshot viewer).
    public static func pixels(for size: CGSize, scale: CGFloat) -> Int {
        let longEdge = max(size.width, size.height, 0) * max(scale, 1)
        let needed = longEdge.isFinite ? Int(longEdge.rounded(.up)) : Int.max / 2
        let stepped = (min(needed, ThumbnailDataProvider.maximumThumbnailPixels) + 255) / 256 * 256
        return min(ThumbnailDataProvider.maximumThumbnailPixels, max(512, stepped))
    }

    /// Open the screenshot at `url` through `provider`: the saved image when
    /// `fullResolution`, else at most `maxPixelSize` pixels on its long edge.
    public static func load(
        url: URL?,
        maxPixelSize: Int,
        fullResolution: Bool = false,
        provider: any ThumbnailDataProviding
    ) async -> MomentPicture {
        guard let url else { return .appIcon(.textOnly) }
        let data = if fullResolution {
            await provider.screenshotData(for: url)
        } else {
            await provider.thumbnailData(for: url, maxPixelSize: maxPixelSize)
        }
        guard let data, !data.isEmpty else { return .appIcon(.unavailable) }
        return .screenshot(data)
    }
}
