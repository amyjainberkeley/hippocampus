import SwiftUI
import HippocampusKit

struct CaptureHealthView: View {
    @ObservedObject var supervisor: ProcessSupervisor
    let onReviewCapture: () -> Void
    @State private var actionError: String?

    var body: some View {
        let status = supervisor.menuBarStatus
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(status.displayText).font(.headline)
            } icon: {
                Circle().fill(status.indicatorColor).frame(width: 7, height: 7)
            }
            Text(status.detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let receipt = supervisor.captureReceipt {
                if receipt.storedFrameCount == 0 && status != .noMemory {
                    Text("No saved memory in the last report")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(receipt.storedCountsText).font(.caption)
                Text(receipt.lastSavedText()).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Saved frames and screenshots: unverified")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let action = status.action {
                Button { perform(action) } label: {
                    Label(action.title, systemImage: action.symbol)
                }
                .disabled(supervisor.state == .starting)
            }
            if let actionError {
                Text(actionError).font(.caption).foregroundStyle(.red)
            }
        }
        .task { supervisor.refreshCaptureStatus() }
    }

    private func perform(_ action: CaptureStatusAction) {
        actionError = nil
        switch action {
        case .resume:
            UserPauseController.shared.setPaused(false)
            supervisor.setPaused(false)
        case .start:
            if supervisor.captureEnabled {
                supervisor.start()
            } else {
                Task { @MainActor in
                    do { try await supervisor.applyCaptureEnabled(true) }
                    catch { actionError = error.localizedDescription }
                }
            }
        case .openPermission(let permission):
            if let url = URL(string: permission.settingsPaneURLString) {
                NSWorkspace.shared.open(url)
            }
        case .reviewCapture:
            onReviewCapture()
        case .openLogs:
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/MCI"))
        }
    }
}
