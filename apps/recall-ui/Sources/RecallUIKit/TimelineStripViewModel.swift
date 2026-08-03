// TimelineStripViewModel.swift — V2-P13 (Phase D scaffold). See ADR-0036.
//
// View model for the ⌘8 timeline-strip tab.
//
// Moved here from `Sources/RecallUI/TimelineStripView.swift`. It is a pure
// view model with no SwiftUI in it, and `RecallUIKitTests` depends on
// `RecallUIKit` only, so it was untestable where it was. The other five view
// models already live in this target; this one was the outlier.

import Combine
import Foundation

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
