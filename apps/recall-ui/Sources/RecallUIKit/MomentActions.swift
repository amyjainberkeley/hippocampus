import Foundation

/// What a moment's actions act on, wherever they are offered: History's
/// detail and its rows' menu, and the lenses over History (SPEC 3.4).
public enum MomentActions {
    /// What Copy Text copies from a row's menu: what the person was reading,
    /// as the detail shows it, never the stored header; the row's excerpt
    /// when the reading can't be had.
    public static func text(of hit: Hit, reader: BrainReader?) async -> String {
        if let reader, let reading = try? await reader.eventReading(eventId: hit.id, query: nil),
           reading.matches(hit) {
            let text = reading.text(includingRest: false)
            if !text.isEmpty { return text }
        }
        return ReadableText.guarded(hit.ocrTextSnippet)
    }

    /// The page Open Link opens: a web address only, never a file or an app's
    /// own scheme.
    public static func link(of hit: Hit) -> URL? {
        guard let value = hit.url, let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// The address as the detail shows it: no scheme, no query, no fragment
    /// ("devnotes.example/rounding").
    public static func shownLink(_ value: String) -> String {
        var shown = value
        if let range = shown.range(of: "://") { shown = String(shown[range.upperBound...]) }
        if let cut = shown.firstIndex(where: { $0 == "?" || $0 == "#" }) { shown = String(shown[..<cut]) }
        while shown.hasSuffix("/") { shown.removeLast() }
        return shown.isEmpty ? value : shown
    }
}
