// SPDX-License-Identifier: TBD-private

import Foundation

/// Browser pages use the structured WebExtension path, which can identify
/// private tabs before extracting page content. Ambient browser pixels require
/// a separate positive, captured-window-bound privacy probe; unsupported
/// browsers and ambiguous windows stay excluded.
public enum BrowserPixelCapturePolicy {
    public static let excludedBundleIds: Set<String> = [
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
}
