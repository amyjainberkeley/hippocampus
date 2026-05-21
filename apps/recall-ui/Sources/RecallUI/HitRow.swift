import RecallUIKit
import SwiftUI

struct HitRow: View {
    let hit: Hit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Formatters.relativeTime(usSinceEpoch: hit.tsUs))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.brandMint)
                    .help(Formatters.tsString(usSinceEpoch: hit.tsUs))
                Text(Formatters.contextLine(hit))
                    .font(.system(.body, design: .default).weight(.semibold))
                    .foregroundStyle(Color.brandFgPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Formatters.sourceTag(hit.source))
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.brandMintDim, lineWidth: 0.5)
                    )
                    .foregroundStyle(Color.brandMintDim)
                if !Formatters.scoreString(hit.score).isEmpty {
                    Text(Formatters.scoreString(hit.score))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.brandFgMuted)
                }
            }
            Text(Formatters.snippet(hit.ocrTextSnippet))
                .font(.system(.body, design: .default))
                .foregroundStyle(Color.brandFgSecondary)
                .lineLimit(3)
        }
        .padding(.vertical, 6)
    }
}
