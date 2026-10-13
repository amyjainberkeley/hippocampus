import AppKit
import RecallUIKit
import SwiftUI

/// The only UI path from an encrypted keyframe blob to visible pixels.
struct EvidenceThumbnail: View {
    let url: URL?
    let size: CGSize
    let maxPixelSize: Int
    var placeholderSymbol = "photo"
    var contentMode: ContentMode = .fit
    var showsStatus = false
    var fullResolution = false
    var provider: any ThumbnailDataProviding = ThumbnailDataProvider.shared

    @State private var image: NSImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .accessibilityHidden(true)
            } else {
                ZStack {
                    Color.brandCardBg
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: placeholderSymbol)
                                .font(.system(size: min(size.height * 0.3, 20)))
                            if showsStatus {
                                Text(url == nil ? UserFacingCopy.noScreenshot : UserFacingCopy.screenshotMissing)
                                    .font(.caption)
                                if url != nil {
                                    Text("The saved image could not be opened.")
                                        .font(.caption2)
                                }
                            }
                        }
                        .foregroundStyle(Color.brandFgMuted)
                    }
                }
                .accessibilityLabel(isLoading ? UserFacingCopy.momentTextLoading : (url == nil ? UserFacingCopy.noScreenshot : UserFacingCopy.screenshotMissing))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: MCI.Radius.xs, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MCI.Radius.xs, style: .continuous)
                .stroke(Color.brandCardBorder, lineWidth: 0.5)
        }
        .task(id: url) {
            image = nil
            isLoading = url != nil
            defer { if !Task.isCancelled { isLoading = false } }
            guard let url else { return }
            let data = if fullResolution {
                await provider.screenshotData(for: url)
            } else {
                await provider.thumbnailData(for: url, maxPixelSize: maxPixelSize)
            }
            guard !Task.isCancelled, let data else { return }
            image = NSImage(data: data)
        }
    }
}
