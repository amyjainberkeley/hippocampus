import AppKit
import RecallUIKit
import SwiftUI

struct DetailPaneView: View {
    let hit: Hit
    /// Optional reader injected by the parent so the related-hits flyout
    /// (cycle 8.37 PR-3) can resolve `hit.linkedEventIds` into full
    /// sibling `Hit` rows. `nil` on preview / legacy call sites — the
    /// flyout button is hidden in that case.
    var reader: BrainReader? = nil
    /// Bubble a selected sibling up to the parent VM so click-through
    /// on a flyout row can push it into the search / timeline selection.
    var onSelectRelated: ((Hit) -> Void)? = nil

    @State private var flyoutScope: RelatedHitsScope? = nil

    /// `text_snippet` with the FTS-only context header prefix
    /// (`[app=… | title=… | url=… | ts=…]\n`) stripped for display.
    /// The stored field is unchanged — see `Formatters.stripContextHeader`.
    private var displayBody: String {
        Formatters.stripContextHeader(hit.ocrTextSnippet)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider().background(Color.brandCardBorder)
                if !hit.entities.isEmpty {
                    entityStrip
                }
                if let urlStr = hit.url, !urlStr.isEmpty {
                    urlSection(urlStr)
                }
                ocrSection
            }
            .padding(16)
        }
        .background(Color.brandBgSecondary)
        .focusable()
        .onCopyCommand {
            [NSItemProvider(object: displayBody as NSString)]
        }
        .onKeyPress(.init("o"), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            if let u = hit.url, let url = URL(string: u) {
                NSWorkspace.shared.open(url)
                return .handled
            }
            return .ignored
        }
        .registerActionPanelCommands([
            .init(
                id: "hit.copySnippet",
                title: "Copy Hit Snippet",
                shortcut: "⌘C",
                category: .hit
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(displayBody, forType: .string)
            },
            .init(
                id: "hit.openInApp",
                title: "Open in App",
                shortcut: "⌘O",
                category: .hit,
                isEnabled: { hit.url.flatMap(URL.init(string:)) != nil }
            ) {
                if let u = hit.url, let url = URL(string: u) {
                    NSWorkspace.shared.open(url)
                }
            },
            .init(
                id: "hit.showRelated",
                title: "Show Related Hits",
                shortcut: "⌘R",
                category: .hit,
                isEnabled: { !hit.linkedEventIds.isEmpty }
            ) {
                flyoutScope = .all(hitId: hit.id)
            },
        ])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.appBundleId ?? "(no app)")
                    .font(.system(.title3, design: .default).weight(.semibold))
                    .foregroundStyle(Color.brandFgPrimary)
                Spacer()
                if reader != nil, !hit.linkedEventIds.isEmpty {
                    relatedBadge
                }
                Text(Formatters.sourceTag(hit.source))
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.brandMintDim, lineWidth: 0.5)
                    )
                    .foregroundStyle(Color.brandMintDim)
            }
            if let title = hit.windowTitle, !title.isEmpty {
                Text(title)
                    .font(.system(.body, design: .default))
                    .foregroundStyle(Color.brandFgSecondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(Formatters.relativeTime(usSinceEpoch: hit.tsUs))
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(Color.brandMint)
                    .help(Formatters.tsString(usSinceEpoch: hit.tsUs))
                if let s = hit.score {
                    Text(Formatters.scoreString(s))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.brandFgMuted)
                }
            }
            HStack(spacing: 8) {
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(displayBody, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.brandMint)

                if let urlStr = hit.url, URL(string: urlStr) != nil {
                    Button("Open URL") {
                        if let url = URL(string: urlStr) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.brandMint)
                }
            }
        }
    }

    /// "🔗 N related" pill next to the source tag. Click opens the
    /// cross-app dot-connect flyout scoped to every id in
    /// `hit.linkedEventIds`. Hidden when `reader` is nil (preview /
    /// legacy call sites) or the hit has no linked siblings.
    private var relatedBadge: some View {
        Button {
            flyoutScope = .all(hitId: hit.eventId)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.system(size: 9))
                Text("\(hit.linkedEventIds.count) related")
                    .font(.system(.caption2, design: .monospaced))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.brandMintSubtle)
            )
            .foregroundStyle(Color.brandMint)
        }
        .buttonStyle(.plain)
        .help("Show cross-app siblings of this event")
        .popover(
            isPresented: Binding(
                get: {
                    if case .all = flyoutScope { return true }
                    return false
                },
                set: { on in if !on { flyoutScope = nil } }
            ),
            arrowEdge: .top
        ) {
            flyoutBody(scope: .all(hitId: hit.eventId))
        }
    }

    /// Horizontal chip strip listing every resolver-allowlist entity the
    /// event mentions. A chip is BOTH click-to-open and long-hover
    /// (~500 ms) to open the flyout scoped to that entity. This is the
    /// per-entity leg of the dot-connect surface (§3.3 of the audit).
    private var entityStrip: some View {
        // Use a lightweight flow layout — up to ~6 chips typical.
        HStack(spacing: 6) {
            ForEach(Array(hit.entities.prefix(6).enumerated()), id: \.offset) { _, name in
                EntityChipTrigger(
                    name: name,
                    isFlyoutActive: {
                        if case .entity(_, let n) = flyoutScope { return n == name }
                        return false
                    },
                    onOpen: {
                        if reader != nil {
                            flyoutScope = .entity(hitId: hit.eventId, name: name)
                        }
                    },
                    onDismiss: { flyoutScope = nil },
                    popover: {
                        flyoutBody(scope: .entity(hitId: hit.eventId, name: name))
                    }
                )
            }
            if hit.entities.count > 6 {
                Text("+\(hit.entities.count - 6)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.brandFgMuted)
            }
            Spacer()
        }
    }

    /// The flyout body factored out so both the badge popover and the
    /// per-chip popovers share the same construction (and both consult
    /// `reader` guarded).
    @ViewBuilder
    private func flyoutBody(scope: RelatedHitsScope) -> some View {
        if let reader = reader {
            RelatedHitsFlyout(
                hit: hit,
                scope: scope,
                reader: reader,
                onSelect: onSelectRelated,
                onDismiss: { flyoutScope = nil }
            )
        } else {
            // Should be unreachable — badge / chip hidden when reader nil.
            EmptyView()
        }
    }

    private func urlSection(_ urlStr: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "link")
                .foregroundStyle(Color.brandMintDim)
                .font(.caption)
            if let url = URL(string: urlStr) {
                Link(urlStr, destination: url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.brandMint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(urlStr)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.brandFgSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var ocrSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Formatters.sourceLabel(url: hit.url, textSnippet: hit.ocrTextSnippet))
                .font(.system(.caption, design: .default).weight(.semibold))
                .foregroundStyle(Color.brandFgMuted)
            if SyntaxHighlighter.looksLikeCode(displayBody) {
                highlightedCode
            } else {
                linkedText
            }
        }
    }

    private var highlightedCode: some View {
        let tokens = SyntaxHighlighter.tokenize(displayBody)
        return tokens.reduce(Text("")) { result, token in
            result + Text(token.text).foregroundColor(Color.syntaxColor(for: token.type))
        }
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.brandBgPrimary)
        )
    }

    private var linkedText: some View {
        let text = displayBody
        let links = LinkDetector.detect(in: text)
        let built: Text = {
            guard !links.isEmpty else {
                return Text(text).foregroundColor(.brandFgPrimary)
            }
            var result = Text("")
            var pos = text.startIndex
            for link in links {
                if pos < link.range.lowerBound {
                    result = result + Text(text[pos..<link.range.lowerBound])
                        .foregroundColor(.brandFgPrimary)
                }
                result = result + Text(link.url)
                    .foregroundColor(.brandMint)
                    .underline()
                pos = link.range.upperBound
            }
            if pos < text.endIndex {
                result = result + Text(text[pos...])
                    .foregroundColor(.brandFgPrimary)
            }
            return result
        }()
        return built
            .font(.system(.body, design: .default))
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.brandBgPrimary)
            )
    }
}

/// One clickable / hoverable entity chip used inside `DetailPaneView`'s
/// entity strip. Encapsulates the ~500 ms long-hover timer that opens
/// the related-hits flyout without also firing on a mouse fly-by. Kept
/// as a nested private-ish helper so `DetailPaneView` stays readable
/// and the popover state machine is one place. Click opens the same
/// flyout immediately (bypasses the timer).
private struct EntityChipTrigger<PopoverContent: View>: View {
    let name: String
    /// Poll from the parent's `flyoutScope` so we can drive the
    /// `.popover(isPresented:)` binding without duplicating truth.
    let isFlyoutActive: () -> Bool
    /// Fire the "open flyout for this entity" transition in the parent.
    let onOpen: () -> Void
    /// Clear the parent's `flyoutScope` — invoked when the popover
    /// closes (click-outside / ESC).
    let onDismiss: () -> Void
    /// The popover body. Constructed lazily so we don't build it on
    /// every hover-tick.
    @ViewBuilder let popover: () -> PopoverContent

    /// Long-hover threshold — ~500 ms per the task spec so a fly-by
    /// mouse motion does not trigger the popover.
    private static var hoverOpenDelay: Duration { .milliseconds(500) }

    @State private var hoverTask: Task<Void, Never>? = nil

    var body: some View {
        Text(name)
            .font(.system(.caption, design: .default))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.brandMintSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.brandMintDim, lineWidth: 0.5)
            )
            .foregroundStyle(Color.brandMint)
            .contentShape(Rectangle())
            .onTapGesture { onOpen() }
            .onHover { entered in
                hoverTask?.cancel()
                guard entered else { return }
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: Self.hoverOpenDelay)
                    if !Task.isCancelled { onOpen() }
                }
            }
            .popover(
                isPresented: Binding(
                    get: isFlyoutActive,
                    // Set(false) fires when the popover closes (click-outside /
                    // ESC). Set(true) is a no-op — parent controls opening
                    // via `onOpen` (tap / long-hover).
                    set: { on in if !on { onDismiss() } }
                ),
                arrowEdge: .bottom,
                content: popover
            )
    }
}
