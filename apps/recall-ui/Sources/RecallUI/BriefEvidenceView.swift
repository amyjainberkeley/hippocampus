import RecallUIKit
import SwiftUI

struct BriefEvidenceView: View {
    let brief: Brief
    let reader: BrainReader
    @State private var selectedSource: ScreenshotSelection?

    private var rows: [BriefPresentation.Row] {
        BriefPresentation.rows(body: brief.body, modelId: brief.modelId, modelVersion: brief.modelVersion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .heading(let title):
                    Text(verbatim: title).font(.headline).padding(.top, 8)
                case .evidence(let text, let eventID):
                    HStack(alignment: .top, spacing: 12) {
                        Text(verbatim: text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            selectedSource = ScreenshotSelection(eventIDs: [eventID], initialID: eventID)
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass").frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help("Open saved source \(eventID)")
                        .accessibilityLabel("Open saved source \(eventID)")
                    }
                case .text(let text):
                    Text(verbatim: text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(item: $selectedSource) { selection in
            ScreenshotViewer(selection: selection, reader: reader)
        }
    }
}
