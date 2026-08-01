// TimelineStripView.swift — V2-P13 (Phase D scaffold). See ADR-0036.
//
// Rewind-style horizontal timeline strip: one card per capture in the
// selected window. Ships the shape (⌘8 tab, VM, resolution toggle,
// empty state, event-card, click-to-DetailPane); live rendering awaits
// V2-P1 M4 lift + real captures. Pinch/zoom, drag-scrub, real
// thumbnail decode are Phase D full impl (cycle 8.55+).

import AppKit
import RecallUIKit
import SwiftUI

/// V2-P13 scaffold. View model for the ⌘8 timeline-strip tab.
@MainActor
public final class TimelineStripViewModel: ObservableObject {
    @Published public private(set) var events: [TimelineEvent] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?
    @Published public var resolution: TimelineResolution = .minute
    @Published public var selectedEventId: UInt64?

    /// Right-edge of the visible window (defaults to "now"). Left edge
    /// is derived by subtracting `resolution.defaultWindowUs`.
    @Published public var anchorTsUs: UInt64

    private let reader: BrainReader

    public init(
        reader: BrainReader,
        anchorTsUs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000_000)
    ) {
        self.reader = reader
        self.anchorTsUs = anchorTsUs
    }

    public var windowStartTsUs: UInt64 {
        anchorTsUs > resolution.defaultWindowUs
            ? anchorTsUs - resolution.defaultWindowUs
            : 0
    }
    public var windowEndTsUs: UInt64 { anchorTsUs }

    public func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            events = try await reader.timelineEvents(
                startTsUs: windowStartTsUs,
                endTsUs: windowEndTsUs,
                resolution: resolution
            )
        } catch {
            events = []
            errorMessage = "\(error)"
        }
    }

    /// ⌘+ zoom-in — narrower window. No-op at the finest step.
    public func zoomIn() {
        switch resolution {
        case .day: resolution = .hour
        case .hour: resolution = .minute
        case .minute: break
        }
    }

    /// ⌘− zoom-out — wider window. No-op at the coarsest step.
    public func zoomOut() {
        switch resolution {
        case .minute: resolution = .hour
        case .hour: resolution = .day
        case .day: break
        }
    }
}

/// V2-P13 scaffold. Horizontal timeline strip tab (⌘8).
public struct TimelineStripView: View {
    @StateObject private var viewModel: TimelineStripViewModel
    private let reader: BrainReader

    public init(reader: BrainReader) {
        self.reader = reader
        self._viewModel = StateObject(
            wrappedValue: TimelineStripViewModel(reader: reader)
        )
    }

    public var body: some View {
        VStack(spacing: MCI.Spacing.m) {
            header
            Divider().background(MCI.Color.border)
            content
        }
        .padding(.top, MCI.Spacing.m)
        .background(MCI.Color.background)
        .task { await viewModel.reload() }
        .onChange(of: viewModel.resolution) { _, _ in
            Task { await viewModel.reload() }
        }
        .onKeyPress(.init("="), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            viewModel.zoomIn()
            return .handled
        }
        .onKeyPress(.init("-"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            viewModel.zoomOut()
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: MCI.Spacing.m) {
            Picker("Resolution", selection: $viewModel.resolution) {
                ForEach(TimelineResolution.allCases, id: \.self) { res in
                    Text(res.displayLabel).tag(res)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            Spacer()

            if !viewModel.events.isEmpty {
                Text("\(viewModel.events.count) events")
                    .font(MCI.Font.caption)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
            }
        }
        .padding(.horizontal, MCI.Spacing.l)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.errorMessage != nil {
            // Cycle 8.54 copy audit — never leak raw `\(error)` (SQLCipher
            // codes, FFI strings). Reassuring body + inherent retry
            // via `.task { await viewModel.reload() }`.
            ContentUnavailableView(
                UserFacingCopy.timelineLoadFailedTitle,
                systemImage: "exclamationmark.triangle.fill",
                description: Text(UserFacingCopy.loadFailedBody)
            )
            .foregroundStyle(MCI.Color.error)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.isLoading && viewModel.events.isEmpty {
            ProgressView().controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.events.isEmpty {
            MCIEmptyState.noTimelineEvents()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            stripView
        }
    }

    private var stripView: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: MCI.Spacing.s) {
                    ForEach(viewModel.events) { ev in
                        TimelineEventCard(
                            event: ev,
                            isSelected: viewModel.selectedEventId == ev.id
                        )
                        .onTapGesture { viewModel.selectedEventId = ev.id }
                    }
                }
                .padding(.horizontal, MCI.Spacing.l)
                .padding(.vertical, MCI.Spacing.s)
            }
            .frame(minHeight: 200)

            if let selectedId = viewModel.selectedEventId,
               let selected = viewModel.events.first(where: { $0.id == selectedId }) {
                Divider().background(MCI.Color.border)
                TimelineDetailPane(event: selected, reader: reader)
                    .frame(minWidth: 320, idealWidth: 380)
            }
        }
    }
}

/// V2-P13 scaffold. One capture card on the timeline strip.
public struct TimelineEventCard: View {
    let event: TimelineEvent
    let isSelected: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.xs) {
            // Keyframe placeholder — real blur-decode lands in Phase D
            // full impl.
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(MCI.Color.surfaceElevated)
                    .frame(height: 60)
                Image(systemName: event.thumbnailPath == nil ? "doc.text" : "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(MCI.Color.foregroundMuted)
            }
            Text(Self.timeLabel(for: event.tsUs))
                .font(MCI.Font.footnote)
                .foregroundStyle(MCI.Color.foregroundSecondary)
            if let app = event.appBundleId {
                Text(Self.shortAppName(app))
                    .font(MCI.Font.caption)
                    .foregroundStyle(MCI.Color.foreground)
                    .lineLimit(1)
            }
        }
        .padding(MCI.Spacing.xs)
        .frame(width: 96)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? MCI.Color.accentSubtle : MCI.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? MCI.Color.accent : MCI.Color.border, lineWidth: 1)
        )
        .help(event.snippet)
    }

    /// Both helpers live in `RecallUIKit.TimelineEventFormatting` so the
    /// test target can reach them. Kept here as thin forwarders so call
    /// sites in this view are unchanged.
    static func timeLabel(for tsUs: UInt64) -> String {
        TimelineEventFormatting.timeLabel(for: tsUs)
    }

    /// `com.apple.Safari` → `Safari`. Falls back to the raw string.
    static func shortAppName(_ bundle: String) -> String {
        TimelineEventFormatting.shortAppName(bundle)
    }
}

/// V2-P13 scaffold. Inline detail for a selected card. Resolves the
/// `TimelineEvent` back to a full `Hit` and hands off to `DetailPaneView`.
struct TimelineDetailPane: View {
    let event: TimelineEvent
    let reader: BrainReader

    @State private var hit: Hit?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let hit = hit {
                DetailPaneView(hit: hit, reader: reader)
            } else if errorMessage != nil {
                // Cycle 8.54 copy audit — reassuring body; raw error
                // stays in `errorMessage` for future logging but is
                // not surfaced to the UI.
                ContentUnavailableView(
                    UserFacingCopy.eventDetailFailedTitle,
                    systemImage: "exclamationmark.triangle",
                    description: Text(UserFacingCopy.loadFailedBody)
                )
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: event.id) {
            do {
                let hits = try await reader.fetchEventsByIds([event.eventId])
                hit = hits.first
                if hit == nil {
                    // Cycle 8.54 copy audit — plain-English (no "brain",
                    // no "suppressed"). "Marked private" is the
                    // user-visible synonym for our internal
                    // "denylist / redaction" suppression path.
                    errorMessage = UserFacingCopy.eventNoLongerAvailable
                }
            } catch {
                errorMessage = "\(error)"
            }
        }
    }
}
