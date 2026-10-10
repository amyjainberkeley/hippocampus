import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Whole-screen capture: one low-rate stream per display that reads the
/// visible windows the focused-window stream does not, and files each window's
/// text under that window. See `BackgroundCapturePolicy` for attribution.
///
/// Excluded apps (password managers, system authentication, browsers,
/// notification banners, Hippocampus) are removed from the stream's pixels by
/// the content filter. A display is read at most every `minimumReadInterval`,
/// only when its text visibly changed, never while secure text entry is
/// active, and not while the user is idle. No screenshot is kept.
public final class BackgroundCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public static let minimumReadInterval: TimeInterval = 15
    static let frameIntervalSeconds: Int64 = 2
    static let idleAfterSeconds: TimeInterval = 60
    static let maximumLongEdge = 3840
    /// Longer than the stream's queue (three frames, two seconds apart).
    static let filterDrainSeconds: TimeInterval = 8

    private let emitter: CascadeTwiceOCREmitter
    private let excludedBundleIds: Set<String>
    private let denylist: SensitiveCaptureDenylist
    private let focusedWindowId: @Sendable () -> CGWindowID?
    private let secureInput: any SecureEventInputProbe
    private let activity: any UserActivityReading
    private let queue = DispatchQueue(label: "com.hippocampus.capture.background", qos: .utility)

    /// A running display stream: its display, and the processes its content
    /// filter removes from the pixels.
    private struct Entry {
        let id: CGDirectDisplayID
        let bounds: CGRect
        var filteredPids: Set<pid_t>
        var refreshing = false
        /// Frames queued under a previous filter drain before reads resume.
        var holdUntil = Date.distantPast
    }

    private let lock = NSLock()
    private var streams: [CGDirectDisplayID: SCStream] = [:]
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var lastRead: [CGDirectDisplayID: (at: Date, thumbnail: TextChangeThumbnail)] = [:]
    /// The text last sent for each visible window. A display read is due when
    /// anything on it changed, often only the focused window; windows whose
    /// text is unchanged are not sent again.
    private var lastSentText: [CGWindowID: Int] = [:]
    private var watcher: Task<Void, Never>?
    private var stopped = false

    public init(
        emitter: CascadeTwiceOCREmitter,
        userDenylist: [DenylistEntry],
        focusedWindowId: @escaping @Sendable () -> CGWindowID?,
        secureInput: any SecureEventInputProbe = CarbonSecureEventInputProbe(),
        activity: any UserActivityReading = SystemUserActivityReader()
    ) {
        self.emitter = emitter
        self.excludedBundleIds = BackgroundCapturePolicy.excludedBundleIds(userEntries: userDenylist)
        self.denylist = SensitiveCaptureDenylist(entries: userDenylist)
        self.focusedWindowId = focusedWindowId
        self.secureInput = secureInput
        self.activity = activity
    }

    /// Starts a stream per display and keeps the set current as displays come
    /// and go. Failures are reported and retried; the focused stream is never
    /// affected.
    public func start() {
        watcher = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.reconcileDisplays()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    public func stop() async {
        let current: [SCStream] = lock.withLock {
            stopped = true
            defer { streams.removeAll(); entries.removeAll() }
            return Array(streams.values)
        }
        watcher?.cancel()
        for stream in current { try? await stream.stopCapture() }
    }

    private func reconcileDisplays() async {
        guard let content = try? await SCShareableContent.current else { return }
        let wanted = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
        let (running, isStopped): (Set<CGDirectDisplayID>, Bool) = lock.withLock { (Set(streams.keys), stopped) }
        guard !isStopped else { return }
        for id in running.subtracting(wanted.keys) {
            let gone: SCStream? = lock.withLock { streams.removeValue(forKey: id) }
            if let gone { try? await gone.stopCapture() }
        }
        let excludedApps = excludedApplications(in: content)
        for (id, display) in wanted where !running.contains(id) {
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            let stream = SCStream(filter: filter, configuration: Self.configuration(for: display), delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
            } catch {
                FileHandle.standardError.write(Data(
                    "mci-capture-helper: background capture unavailable on a display: \(error.localizedDescription)\n".utf8))
                continue
            }
            let keep = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                streams[id] = stream
                entries[ObjectIdentifier(stream)] = Entry(
                    id: id, bounds: display.frame, filteredPids: Set(excludedApps.map(\.processID)))
                return true
            }
            if !keep { try? await stream.stopCapture() }
        }
    }

    private func excludedApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        content.applications.filter { BackgroundCapturePolicy.isExcluded($0.bundleIdentifier, from: excludedBundleIds) }
    }

    /// Rebuilds a stream's filter so apps launched since it was built are
    /// removed from its pixels. Until it succeeds the stream's frames are not
    /// read.
    private func refreshFilter(displayId: CGDirectDisplayID) async {
        guard let stream = lock.withLock({ streams[displayId] }) else { return }
        defer { lock.withLock { entries[ObjectIdentifier(stream)]?.refreshing = false } }
        guard let content = try? await SCShareableContent.current,
              let display = content.displays.first(where: { $0.displayID == displayId })
        else { return }
        let excludedApps = excludedApplications(in: content)
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        do {
            try await stream.updateContentFilter(filter)
        } catch {
            return
        }
        lock.withLock {
            entries[ObjectIdentifier(stream)]?.filteredPids = Set(excludedApps.map(\.processID))
            entries[ObjectIdentifier(stream)]?.holdUntil = Date().addingTimeInterval(Self.filterDrainSeconds)
        }
    }

    static func configuration(for display: SCDisplay) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        var width = display.width, height = display.height
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            width = mode.pixelWidth
            height = mode.pixelHeight
        }
        let scale = min(1, Double(maximumLongEdge) / Double(max(width, height)))
        config.width = max(1, Int(Double(width) * scale))
        config.height = max(1, Int(Double(height) * scale))
        config.minimumFrameInterval = CMTime(value: frameIntervalSeconds, timescale: 1)
        config.showsCursor = false
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return config
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = (attachments.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)),
              status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let display = lock.withLock({ entries[ObjectIdentifier(stream)] })
        else { return }

        let now = Date()
        guard now >= display.holdUntil else { return }
        if let idle = activity.secondsSinceLastInput(), idle > Self.idleAfterSeconds { return }
        if secureInput.isSecureEventInputEnabled() { return }
        guard let thumbnail = TextChangeThumbnail.make(from: pixelBuffer) else { return }
        let due: Bool = lock.withLock {
            guard let last = lastRead[display.id] else { return true }
            guard now.timeIntervalSince(last.at) >= Self.minimumReadInterval else { return false }
            return (thumbnail.changedPixels(since: last.thumbnail) ?? Int.max) >= TextCatchUpPolicy.changedPixelThreshold
        }
        guard due else { return }

        // The window list is taken with the frame, so attribution uses the
        // geometry the pixels were drawn with.
        let windows = Self.visibleWindows()
        let excluded = excludedBundleIds
        if BackgroundCapturePolicy.filterIsStale(
            windows: windows, excludedBundleIds: excluded, filteredPids: display.filteredPids) {
            let start: Bool = lock.withLock {
                guard let entry = entries[ObjectIdentifier(stream)], !entry.refreshing else { return false }
                entries[ObjectIdentifier(stream)]?.refreshing = true
                return true
            }
            let displayId = display.id
            if start { Task { await self.refreshFilter(displayId: displayId) } }
            return
        }
        lock.withLock { lastRead[display.id] = (now, thumbnail) }
        let focused = focusedWindowId()
        let denylist = denylist
        let bounds = display.bounds
        let tsUs = UInt64(max(0, now.timeIntervalSince1970 * 1_000_000))
        let input = OCREngineInput(pixelBuffer: pixelBuffer, roi: CGRect(x: 0, y: 0, width: 1, height: 1))
        let emitter = emitter
        Task {
            await emitter.processBackground(tsUs: tsUs, input: input) { lines in
                let groups = BackgroundCapturePolicy.attribute(
                    lines: lines, displayBounds: bounds, windows: windows,
                    excludedBundleIds: excluded, focusedWindowId: focused, denylist: denylist
                )
                let changed = self.unsentGroups(groups, visible: windows)
                // Content-free: counts only.
                OCRTrace.emit("background-attribute", "lines=\(lines.count) windows=\(groups.count) "
                    + "kept=\(groups.reduce(0) { $0 + $1.lines.count }) changed_windows=\(changed.count)")
                return changed.map { group in
                    (WorkflowContext(appBundleId: group.window.bundleId, windowTitle: group.window.title,
                                     url: nil, pageText: nil),
                     group.lines)
                }
            }
        }
    }

    /// Groups whose text differs from what was last sent for that window.
    /// Forgets windows that are no longer on screen.
    private func unsentGroups(
        _ groups: [(window: VisibleWindow, lines: [OCRLine])], visible: [VisibleWindow]
    ) -> [(window: VisibleWindow, lines: [OCRLine])] {
        let onScreen = Set(visible.map(\.windowId))
        return lock.withLock {
            lastSentText = lastSentText.filter { onScreen.contains($0.key) }
            return groups.filter { group in
                let digest = group.lines.map(\.text).joined(separator: "\n").hashValue
                guard lastSentText[group.window.windowId] != digest else { return false }
                lastSentText[group.window.windowId] = digest
                return true
            }
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let id: CGDirectDisplayID? = lock.withLock {
            guard let entry = entries.removeValue(forKey: ObjectIdentifier(stream)) else { return nil }
            streams.removeValue(forKey: entry.id)
            return entry.id
        }
        if id != nil {
            // The watcher restarts it within a minute.
            FileHandle.standardError.write(Data("mci-capture-helper: background stream stopped; will retry\n".utf8))
        }
    }

    /// On-screen windows, front to back, with their owners' bundle identifiers.
    static func visibleWindows() -> [VisibleWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var bundles: [pid_t: String?] = [:]
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0 else { return nil }
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            if bundles[pid] == nil {
                bundles[pid] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            }
            return VisibleWindow(
                windowId: number,
                ownerPid: pid,
                bundleId: bundles[pid] ?? nil,
                title: info[kCGWindowName as String] as? String,
                bounds: bounds,
                layer: info[kCGWindowLayer as String] as? Int ?? 0
            )
        }
    }
}
