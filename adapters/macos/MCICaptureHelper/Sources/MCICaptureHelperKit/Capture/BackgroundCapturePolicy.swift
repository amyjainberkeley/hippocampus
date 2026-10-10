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
