// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation

/// Browsers are read like every other window (RULINGS G8). A browser window
/// is skipped when it shows that it is private, or that it is a sign-in or
/// bank site, in ways Hippocampus can read without asking anyone:
///
/// - its title (`SensitiveCaptureDenylist.windowTitleIsDenied`): Firefox
///   ends a private window's title with "— Private Browsing"; Chrome and Edge
///   on macOS title a window with its page alone, so only their new private
///   tab pages ("New Incognito Tab", "New InPrivate tab") carry a marker;
/// - its top bar, read with the rest of the window and checked before
///   anything is stored (`topBarFinding`): Chrome's "Incognito", Edge's
///   "InPrivate", a "Private" badge, and the site's address;
/// - the browser itself, only when this Mac already allows Hippocampus to
///   ask it (`BrowserWindowPrivacyProbe`). No prompt is ever shown.
///
/// A window that shows none of these is read.
public enum BrowserPixelCapturePolicy {
    public static let browserBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
    ]

    public static func isBrowser(_ bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return browserBundleIds.contains(bundleId)
    }

    /// Words in a window title that mark a private window, in any app:
    /// Firefox's "— Private Browsing", Chrome's "New Incognito Tab", Edge's
    /// "New InPrivate tab".
    static let privateTitleMarkers = ["incognito", "private browsing", "private window", "inprivate"]

    public static func titleIsPrivate(_ title: String) -> Bool {
        let folded = title.lowercased()
        return privateTitleMarkers.contains { folded.contains($0) }
    }

    /// A title only a private window has: a new private tab, or Firefox's
    /// private suffix. Such a window is remembered as private; a page that
    /// merely mentions the words is skipped for that read only.
    public static func titleMarksPrivateWindow(_ title: String) -> Bool {
        let folded = title.lowercased().trimmingCharacters(in: .whitespaces)
        return ["new incognito tab", "new inprivate tab", "private browsing"].contains(folded)
            || folded.hasSuffix("— private browsing") || folded.hasSuffix(" - private browsing")
    }

    /// The band at the top of a window where browsers draw tabs, the address
    /// bar, the bookmarks bar and the private badge: at most this many points,
    /// and at most this share of the window's height.
    static let topBarPoints: CGFloat = 120
    static let topBarShare: CGFloat = 0.3

    /// What a browser window's top bar shows that keeps it from being read.
    public enum TopBarFinding: Sendable, Equatable {
        /// A private badge ("Incognito", "InPrivate", "Private"): the window
        /// is private for its whole life.
        case privateWindow
        /// Private words in a longer line, such as a tab's title: this read
        /// is skipped, and the window is not remembered.
        case privateWords
        /// The page open now is a site that is never read.
        case deniedSite
    }

    /// What the lines read in a browser window's top bar show: a private
    /// window, the address of a site that is never read, or nothing. `lines`
    /// and `window` share the frame's normalized space (bottom-left origin);
    /// `pixelSize` is the frame's size. Only lines whose centre lies in the
    /// window's top bar count, so text on the page never decides it.
    public static func topBarFinding(
        _ lines: [OCRLine], window: CGRect, pixelSize: CGSize, pixelsPerPoint: CGFloat,
        denylist: any DenylistProbe
    ) -> TopBarFinding? {
        let bar = topBarLines(lines, window: window, pixelSize: pixelSize, pixelsPerPoint: pixelsPerPoint)
        if bar.contains(where: isPrivateBadge) { return .privateWindow }
        if bar.contains(where: isPrivateMarker) { return .privateWords }
        if bar.contains(where: { namesDeniedSite($0, denylist: denylist) }) { return .deniedSite }
        return nil
    }

    static func topBarLines(
        _ lines: [OCRLine], window: CGRect, pixelSize: CGSize, pixelsPerPoint: CGFloat
    ) -> [String] {
        guard !window.isNull, window.width > 0, window.height > 0 else { return [] }
        var band = topBarShare * window.height
        if pixelSize.height > 0, pixelsPerPoint > 0 {
            band = min(band, topBarPoints * pixelsPerPoint / pixelSize.height)
        }
        let bottom = window.maxY - band
        return lines.compactMap { line in
            let box = line.boundingBox
            guard box.width.isFinite, box.height.isFinite else { return nil }
            let centre = CGPoint(x: box.midX, y: box.midY)
            guard centre.x >= window.minX, centre.x <= window.maxX,
                  centre.y >= bottom, centre.y <= window.maxY
            else { return nil }
            return line.text
        }
    }

    /// Whole words only: "Incognito" or "InPrivate" anywhere in the line,
    /// "Private Browsing" or "Private window", or a badge that reads
    /// "Private" alone (a count of windows may follow it).
    static func isPrivateMarker(_ text: String) -> Bool {
        let tokens = words(text)
        if tokens.contains("incognito") || tokens.contains("inprivate") { return true }
        for (word, next) in zip(tokens, tokens.dropFirst())
        where word == "private" && (next == "browsing" || next == "window") {
            return true
        }
        return isPrivateBadge(text)
    }

    /// A line that is a private badge and nothing else: Chrome's
    /// "Incognito", Edge's "InPrivate", a "Private" badge, "Private
    /// Browsing" or "Private window". A count of windows may follow it.
    static func isPrivateBadge(_ text: String) -> Bool {
        let named = words(text).filter { !$0.allSatisfy(\.isNumber) }
        return [["incognito"], ["inprivate"], ["private"], ["private", "browsing"], ["private", "window"]]
            .contains(named)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// Whether the line holds a web address whose site is never read: the
    /// built-in sign-in and bank sites, and the person's own URL rules.
    static func namesDeniedSite(_ text: String, denylist: any DenylistProbe) -> Bool {
        for word in text.split(whereSeparator: \.isWhitespace) {
            var address = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()[]<>,;"))
            for scheme in ["https://", "http://"] where address.lowercased().hasPrefix(scheme) {
                address = String(address.dropFirst(scheme.count))
            }
            let host = address.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            guard looksLikeHost(host) else { continue }
            if denylist.urlIsDenied("https://" + address) || denylist.urlIsDenied("http://" + address) {
                return true
            }
        }
        return false
    }

    static func looksLikeHost(_ host: String) -> Bool {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last, last.count >= 2,
              last.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

/// Browser windows seen to be private, by window number. A private window
/// stays private for its whole life, so once its top bar or title has shown
/// it, it is skipped even when another window later hides that top bar.
public final class PrivateBrowserWindows: @unchecked Sendable {
    public static let shared = PrivateBrowserWindows()

    static let capacity = 256
    private let lock = NSLock()
    private var order: [CGWindowID] = []
    private var known: Set<CGWindowID> = []

    init() {}

    public func remember(_ windowId: CGWindowID) {
        lock.withLock {
            guard known.insert(windowId).inserted else { return }
            order.append(windowId)
            if order.count > Self.capacity { known.remove(order.removeFirst()) }
        }
    }

    public func contains(_ windowId: CGWindowID) -> Bool {
        lock.withLock { known.contains(windowId) }
    }
}
