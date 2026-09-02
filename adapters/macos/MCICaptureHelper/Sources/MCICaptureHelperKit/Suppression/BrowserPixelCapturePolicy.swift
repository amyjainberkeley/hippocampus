// SPDX-License-Identifier: TBD-private

import Foundation

/// Browser pages use the structured WebExtension path, which can identify
/// private tabs before extracting page content. Ambient ScreenCaptureKit OCR
/// cannot reliably distinguish a normal browser window from Private Browsing,
/// so browser pixels never enter the OCR or keyframe pipeline.
public enum BrowserPixelCapturePolicy {
    public static let excludedBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
    ]
}
