import SwiftUI

/// Keeps evidence navigation inside the width offered by the workspace.
struct AdaptiveEvidencePanes<Primary: View, Detail: View>: View {
    let showsDetail: Bool
    let backLabel: String
    let onDismissDetail: () -> Void
    private let primary: Primary
    private let detail: Detail
    private let minimumSplitWidth: CGFloat = 720
    @FocusState private var isPrimaryFocused: Bool
    @FocusState private var isBackFocused: Bool
    @State private var primaryFocusRequest = 0

    init(
        showsDetail: Bool,
        backLabel: String,
        onDismissDetail: @escaping () -> Void,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder detail: () -> Detail
    ) {
        self.showsDetail = showsDetail
        self.backLabel = backLabel
        self.onDismissDetail = onDismissDetail
        self.primary = primary()
        self.detail = detail()
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if showsDetail {
                    if geometry.size.width >= minimumSplitWidth {
                        HSplitView {
                            primaryPane.frame(minWidth: 300)
                            detailPane.frame(minWidth: 360)
                        }
                    } else {
                        VStack(spacing: 0) {
                            HStack {
                                Button(action: dismissDetail) {
                                    Label(backLabel, systemImage: "chevron.left")
                                }
                                .buttonStyle(.borderless)
                                .help(backLabel)
                                .focused($isBackFocused)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            Divider()
                            detailPane
                        }
                        .task {
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            isBackFocused = true
                        }
                        .onKeyPress(.escape, phases: .down) { _ in
                            dismissDetail()
                            return .handled
                        }
                    }
                } else {
                    primaryPane
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var primaryPane: some View {
        primary
            .focused($isPrimaryFocused)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .task(id: primaryFocusRequest) {
                guard primaryFocusRequest > 0, !showsDetail else { return }
                // Focus the replacement list only after detail teardown has finished.
                await Task.yield()
                guard !Task.isCancelled, !showsDetail else { return }
                isPrimaryFocused = true
            }
    }

    private var detailPane: some View {
        detail
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .onKeyPress(.escape, phases: .down) { _ in
                dismissDetail()
                return .handled
            }
    }

    private func dismissDetail() {
        onDismissDetail()
        primaryFocusRequest += 1
    }
}

/// A status message can scroll without increasing the window's minimum height.
struct EvidenceStateViewport<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                content
                    .frame(maxWidth: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
