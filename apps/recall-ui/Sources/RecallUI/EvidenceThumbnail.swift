import AppKit
import RecallUIKit
import SwiftUI

/// The only UI path from an encrypted keyframe blob to visible pixels.
struct EvidenceThumbnail: View {
    let url: URL?
    let size: CGSize
    let maxPixelSize: Int
    var placeholderSymbol = "photo"
    var provider: any ThumbnailDataProviding = ThumbnailDataProvider.shared

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .accessibilityHidden(true)
            } else {
                ZStack {
                    Color.brandCardBg
                    Image(systemName: placeholderSymbol)
                        .font(.system(size: min(size.height * 0.3, 16)))
                        .foregroundStyle(Color.brandFgMuted)
                }
                .accessibilityLabel("No preview available")
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
            guard let url else { return }
            let data = await provider.thumbnailData(for: url, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled, let data else { return }
            image = NSImage(data: data)
        }
    }
}
