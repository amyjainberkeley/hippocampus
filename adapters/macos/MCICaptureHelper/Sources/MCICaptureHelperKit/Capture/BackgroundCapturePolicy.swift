import CoreGraphics
import Foundation

/// One on-screen window as the window server lists it, front to back.
public struct VisibleWindow: Sendable, Equatable {
    public let windowId: CGWindowID
    public let ownerPid: pid_t
    public let bundleId: String?
    public let title: String?
    /// Global coordinates in points, top-left origin (the window server's).
    public let bounds: CGRect
    public let layer: Int

    public init(windowId: CGWindowID, ownerPid: pid_t = 0, bundleId: String?, title: String?, bounds: CGRect, layer: Int) {
        self.windowId = windowId
        self.ownerPid = ownerPid
        self.bundleId = bundleId
        self.title = title
        self.bounds = bounds
        self.layer = layer
    }
}

/// Whole-screen capture rules: which apps never reach the display streams,
/// and which window each recognized line belongs to.
///
/// The focused window keeps its own stream and every check that comes with
/// it. Background reads add the rest of the screen. ADR-0031 scoped capture to
/// the focused window because display text was once filed under the focused
/// app; here every line is attributed to the window it sits in, by geometry,
/// and a line that cannot be attributed to an eligible window is dropped.
public enum BackgroundCapturePolicy {
    /// Not in the pixels at all. Browsers stay with the focused path, where a
    /// window is confirmed non-private before any pixel is read; background
    /// browser windows cannot be confirmed. Notification banners carry
    /// one-time codes. Hippocampus never records itself. The Dock keeps a
    /// display-sized window above every app window (it draws Launchpad and
    /// Mission Control there); left in the pixels it would own every point.
    public static func excludedBundleIds(userEntries: [DenylistEntry]) -> Set<String> {
        var out = SensitiveCaptureDenylist.appBundles
        out.formUnion(BrowserPixelCapturePolicy.excludedBundleIds)
        out.formUnion(["com.apple.notificationcenterui", "ai.hippocampus", "com.apple.dock"])
        out.formUnion(userEntries.filter { $0.kind == .appBundle }.map(\.pattern))
        return out
    }

    static func isExcluded(_ bundleId: String, from excluded: Set<String>) -> Bool {
        excluded.contains(bundleId) || excluded.contains(bundleId.lowercased())
    }

    /// True when a visible window belongs to an excluded app that the stream's
    /// content filter did not remove (the app launched or relaunched after the
    /// filter was built). Its pixels are in the frame, so the frame must not
    /// be read until the filter is rebuilt.
    public static func filterIsStale(
        windows: [VisibleWindow], excludedBundleIds: Set<String>, filteredPids: Set<pid_t>
    ) -> Bool {
        windows.contains { window in
            guard let bundle = window.bundleId, isExcluded(bundle, from: excludedBundleIds) else { return false }
            return !filteredPids.contains(window.ownerPid)
        }
    }

    /// The part of a display to read: every eligible window that overlaps the
    /// changed area, whole (so no line is cut), as a unit rect with a
    /// top-left origin. Falls back to the changed area itself.
    public static func readRegion(
        changed: CGRect,
        displayBounds: CGRect,
        windows: [VisibleWindow],
        excludedBundleIds: Set<String>,
        focusedWindowId: CGWindowID?
    ) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard displayBounds.width > 0, displayBounds.height > 0 else { return full }
        var region: CGRect?
        for window in windows where window.layer == 0 && window.windowId != focusedWindowId {
            if let bundle = window.bundleId, isExcluded(bundle, from: excludedBundleIds) { continue }
            let unit = CGRect(x: (window.bounds.minX - displayBounds.minX) / displayBounds.width,
                              y: (window.bounds.minY - displayBounds.minY) / displayBounds.height,
                              width: window.bounds.width / displayBounds.width,
                              height: window.bounds.height / displayBounds.height).intersection(full)
            guard !unit.isNull, unit.intersects(changed) else { continue }
            region = region.map { $0.union(unit) } ?? unit
        }
        return (region ?? changed).intersection(full)
    }

    /// A top-left unit rect as an OCR region (bottom-left origin), clamped
    /// inside the frame so rounding can never put it outside.
    public static func ocrRegion(_ unit: CGRect) -> CGRect {
        let x0 = min(max(unit.minX, 0), 1), x1 = min(max(unit.maxX, 0), 1)
        let y0 = min(max(1 - unit.maxY, 0), 1), y1 = min(max(1 - unit.minY, 0), 1)
        guard x1 > x0, y1 > y0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The minimum on-screen size worth reading as a window of its own.
    static let minimumWindowSide: CGFloat = 80

    /// Groups `lines` (normalized to the display frame, bottom-left origin) by
    /// the window each line's centre falls in, front to back. Windows of
    /// excluded apps are absent from the pixels, so the topmost window that is
    /// in the pixels owns the point. A line is dropped when that window is the
    /// focused one (its own stream reads it), not an ordinary window, denied by
    /// policy, or when no window owns the point (desktop, menu bar, Dock).
    public static func attribute(
        lines: [OCRLine],
        displayBounds: CGRect,
        windows: [VisibleWindow],
        excludedBundleIds: Set<String>,
        focusedWindowId: CGWindowID?,
        denylist: SensitiveCaptureDenylist
    ) -> [(window: VisibleWindow, lines: [OCRLine])] {
        let inPixels = windows.filter { window in
            guard let bundle = window.bundleId else { return true }
            return !isExcluded(bundle, from: excludedBundleIds)
        }
        var order: [CGWindowID] = []
        var groups: [CGWindowID: (window: VisibleWindow, lines: [OCRLine])] = [:]
        for line in lines {
            let box = line.boundingBox
            guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { continue }
            let point = CGPoint(
                x: displayBounds.minX + box.midX * displayBounds.width,
                y: displayBounds.minY + (1 - box.midY) * displayBounds.height
            )
            guard let owner = inPixels.first(where: { $0.bounds.contains(point) }),
                  isEligible(owner, focusedWindowId: focusedWindowId,
                             excludedBundleIds: excludedBundleIds, denylist: denylist)
            else { continue }
            if groups[owner.windowId] == nil {
                order.append(owner.windowId)
                groups[owner.windowId] = (owner, [])
            }
            groups[owner.windowId]?.lines.append(line)
        }
        return order.compactMap { groups[$0] }
    }

    /// Whether a window drawn in the pixels in front of `window` overlaps it
    /// (`windows` front to back). A covered window's part of the frame holds
    /// other windows' edges, so it takes no pane separators from the frame.
    /// A window missing from the list counts as covered: when unsure, content.
    public static func isCovered(
        _ window: VisibleWindow, windows: [VisibleWindow], excludedBundleIds: Set<String>
    ) -> Bool {
        for other in windows {
            if other.windowId == window.windowId { return false }
            if let bundle = other.bundleId, isExcluded(bundle, from: excludedBundleIds) { continue }
            let overlap = other.bounds.intersection(window.bounds)
            if !overlap.isNull && overlap.width > 0 && overlap.height > 0 { return true }
        }
        return true
    }

    /// What turns on roles for a window read from a display frame
    /// (`displayBounds` in global top-left points): the window in the frame's
    /// normalized bottom-left space, nil when the display has no size. Only a
    /// window with nothing in front of it owns the frame's pane separators.
    /// The reading is partial (it judges no box by neighbours it may not have
    /// seen) when the display shows less than three quarters of the window's
    /// width or height, or a window in front hides a block of it wider and
    /// taller than a quarter of it. A window missing from the list counts as
    /// hidden: when unsure, it is content.
    public static func geometry(
        of window: VisibleWindow, displayBounds: CGRect, pixelsPerPoint: CGFloat,
        windows: [VisibleWindow], excludedBundleIds: Set<String>
    ) -> (geometry: OCRWindowGeometry?, ownsSeparators: Bool) {
        let covered = isCovered(window, windows: windows, excludedBundleIds: excludedBundleIds)
        let rect = OCRWindowGeometry.normalizedRect(of: window.bounds, in: displayBounds)
        guard !rect.isNull else { return (nil, !covered) }
        var partial = !OCRWindowGeometry.seesMost(displayBounds, of: window.bounds)
            || !windows.contains { $0.windowId == window.windowId }
        for other in windows {
            if other.windowId == window.windowId { break }
            if let bundle = other.bundleId, isExcluded(bundle, from: excludedBundleIds) { continue }
            if OCRWindowGeometry.hidesPart(other.bounds.intersection(window.bounds), of: window.bounds) {
                partial = true
            }
        }
        return (OCRWindowGeometry(rect: rect, pixelsPerPoint: pixelsPerPoint, title: window.title,
                                  bundleId: window.bundleId, partial: partial),
                !covered)
    }

    static func isEligible(
        _ window: VisibleWindow, focusedWindowId: CGWindowID?,
        excludedBundleIds: Set<String>, denylist: SensitiveCaptureDenylist
    ) -> Bool {
        guard window.layer == 0,
              window.windowId != focusedWindowId,
              let bundle = window.bundleId, !bundle.isEmpty,
              !isExcluded(bundle, from: excludedBundleIds),
              !denylist.appIsDenied(bundleId: bundle),
              window.bounds.width >= minimumWindowSide, window.bounds.height >= minimumWindowSide
        else { return false }
        if let title = window.title, denylist.windowTitleIsDenied(title) { return false }
        return true
    }
}
