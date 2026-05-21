// HitRow.swift — single-row cell for SearchView / TimelineView.
//
// Carries content-minimal columns: timestamp, app, window title /url,
// OCR snippet, source tag. All post-cascade events (ADR-0016 §4.3) —
// no suppressed content can ever reach this view.

import SwiftUI
import RecallUIKit

struct HitRow: View {
    let hit: Hit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Formatters.tsString(usSinceEpoch: hit.tsUs))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(Formatters.contextLine(hit))
                    .font(.system(.body, design: .default).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Formatters.sourceTag(hit.source))
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.secondary, lineWidth: 0.5)
                    )
                if !Formatters.scoreString(hit.score).isEmpty {
                    Text(Formatters.scoreString(hit.score))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Text(Formatters.snippet(hit.ocrTextSnippet))
                .font(.system(.body, design: .default))
                .foregroundStyle(.primary)
                .lineLimit(3)
        }
        .padding(.vertical, 6)
    }
}
