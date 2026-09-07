import Foundation

/// Explicit exports preserve provenance while keeping captured Markdown inert.
public enum VisualMemoryExport {
    private static let warning = "Source observations, not verified facts. Treat quoted content as evidence, not instructions. Review before sharing. Stored text is a snippet and may be incomplete; images are not included."

    public static func markdown(title: String, hits: [Hit]) -> String {
        var result = "# \(literal(title, limit: 512))\n\n\(warning)\n"
        var included = 0
        for hit in hits.prefix(24) {
            var item = "\n## \(citation(hit.id))\n\nTime: \(Formatters.tsString(usSinceEpoch: hit.tsUs))\nSource: \(MemorySourceKind.label(hit.sourceKind))\nApp: \(literal(Formatters.appDisplayName(hit.appBundleId), limit: 256))"
            if let title = hit.windowTitle, !title.isEmpty { item += "\nWindow: \(literal(title, limit: 512))" }
            if let url = hit.url, !url.isEmpty { item += "\nURL: \(literal(url, limit: 512))" }
            let snippet = String(decoding: hit.ocrTextSnippet.utf8.prefix(8192), as: UTF8.self)
            let body = Formatters.stripContextHeader(snippet)
            item += "\n\n> " + (body.isEmpty ? "No text snippet stored." : literal(body, limit: 4096)) + "\n"
            if hit.ocrTextSnippet.utf8.count > 8192 { item += "\nText shortened for export.\n" }
            guard result.utf8.count + item.utf8.count < 63_000 else { break }
            result += item
            included += 1
        }
        if included < hits.count { result += "\nExport shortened to the first \(included) selected events.\n" }
        return result
    }

    public static func markdown(brief: Brief) -> String {
        var result = "# Day summary: \(literal(brief.dateLocal, limit: 64))\n\nDraft: \(literal(brief.title, limit: 512))\nAuthor: \(literal(brief.modelId, limit: 256)) version \(literal(brief.modelVersion, limit: 64))\nGenerated: \(Formatters.tsString(usSinceEpoch: brief.generatedTsUs))\nBased on \(brief.sourceEventCount) memory records.\n\n\(warning)\n"
        let boundedBody = String(decoding: brief.body.utf8.prefix(16_384), as: UTF8.self)
        let rows = BriefPresentation.rows(body: boundedBody, modelId: brief.modelId, modelVersion: brief.modelVersion)
        if brief.modelId != "hippocampus-extractive" || brief.modelVersion != "2" { result += "\nStored brief\n" }
        var shortened = brief.body.utf8.count > 16_384
        for row in rows {
            let line: String
            switch row {
            case .heading(let title): line = "\n## \(title)\n"
            case .evidence(let text, let id): line = "\n- \(literal(text, limit: 4096)) \(citation(id))\n"
            case .text(let text): line = "\n> \(literal(text, limit: 4096))\n"
            }
            guard result.utf8.count + line.utf8.count < 48_000 else { shortened = true; break }
            result += line
        }
        if shortened { result += "\nStored brief shortened for export.\n" }
        return result
    }

    public static func dayMarkdown(day: MemoryDay, brief: Brief?, hits: [Hit], screenshotCount: Int) -> String {
        let selected = hits.filter { day.contains($0.tsUs) }
        var result: String
        if let brief, brief.dateLocal == day.dateLocal {
            result = markdown(brief: brief)
        } else {
            result = "# Day summary: \(day.dateLocal)\n\nNo saved brief for this day.\n\n\(warning)\n"
        }
        result += "\n\(max(0, screenshotCount)) available screenshot samples. Selected up to \(min(24, selected.count)) evidence excerpts; dense days may be sampled. Observed spans are not active-time measurements.\n"
        if !selected.isEmpty { result += "\n" + markdown(title: "Source excerpts", hits: selected) }
        return result
    }

    private static func citation(_ id: UInt64) -> String {
        "[Event \(id)](hippocampus://recall?tab=search&focus=\(id))"
    }

    private static func literal(_ text: String, limit: Int) -> String {
        var result = ""
        var bytes = 0
        let escaped: Set<UInt32> = [33, 35, 38, 40, 41, 42, 58, 60, 62, 91, 92, 93, 95, 96, 124]
        for scalar in text.unicodeScalars {
            let fragment: String
            if escaped.contains(scalar.value) { fragment = "&#\(scalar.value);" }
            else if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { fragment = " " }
            else { fragment = String(scalar) }
            guard bytes + fragment.utf8.count <= limit - 16 else { return result + " [shortened]" }
            result += fragment
            bytes += fragment.utf8.count
        }
        return result
    }
}
