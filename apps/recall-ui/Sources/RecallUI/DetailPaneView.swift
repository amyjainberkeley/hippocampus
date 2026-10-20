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
    var screenshotEventIDs: [UInt64] = []
    /// History's row of one window: the newest screenshot of its moments,
    /// shown when this moment has none of its own.
    var rowScreenshot: Hit? = nil
    /// The search's text when the moment was found by one: "Also in this
    /// window" opens by itself when its words are only there (RULINGS T12).
    var query: String? = nil

    @State private var flyoutScope: RelatedHitsScope? = nil
    @State private var showsScreenshot = false
    /// A screenshot that could not be opened: offered again by "Try Again"
    /// while its file is there.
    @State private var unavailableScreenshot: URL?
    @Environment(\.screenshots) private var screenshots
    @Environment(\.displayScale) private var displayScale
    @State private var showsRest = false
    @StateObject private var textModel = EventTextViewModel()

    /// What "Copy Text" copies: what the person was reading, and the rest of
    /// the window when "Also in this window" is open. Never the stored header.
    private var copiedBody: String {
        textModel.copyText(for: hit, includingRest: showsRest)
    }

    private var displayBody: String {
        textModel.copyText(for: hit, includingRest: false)
    }

    private var reading: EventReading? {
        textModel.text(for: hit)
    }

    var body: some View {
        // 8pt-grid rhythm (cycle 8.48 MCIDesignSystem): section spacing
        // + outer padding = MCI.Spacing.l (16pt). Reads as calm; keeps
        // the Stripe-tuned airiness without visual regression.
        ScrollView {
            VStack(alignment: .leading, spacing: MCI.Spacing.l) {
                header
                screenshotSection
                Divider().background(Color.brandCardBorder)
                if !hit.entities.isEmpty {
                    entityStrip
                }
                if let urlStr = hit.url, !urlStr.isEmpty {
                    urlSection(urlStr)
                }
                textSection
            }
            .padding(MCI.Spacing.l)
        }
        .background(.thinMaterial)
        .task(id: hit) {
            showsRest = false
            await textModel.load(hit: hit, reader: reader, query: query)
            guard !Task.isCancelled else { return }
            showsRest = textModel.opensRest(for: hit)
        }
        .onDisappear { textModel.clear() }
        .sheet(isPresented: $showsScreenshot) {
            if let reader {
                // Opens at the moment whose screenshot is shown.
                let shown = screenshot?.id ?? hit.id
                ScreenshotViewer(selection: ScreenshotSelection(
                    eventIDs: screenshotEventIDs.contains(shown) ? screenshotEventIDs : [shown],
                    initialID: shown), reader: reader)
            }
        }
        .focusable()
        .onCopyCommand {
            [NSItemProvider(object: copiedBody as NSString)]
        }
        .onKeyPress(.init("o"), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            if let u = hit.url, let url = URL(string: u) {
                NSWorkspace.shared.open(url)
                return .handled
            }
            return .ignored
        }
        .registerActionPanelCommands(actionPanelCommands)
        .onChange(of: hit) { _, _ in refreshActionPanelCommands() }
        .onChange(of: textModel.state(for: hit)) { _, _ in refreshActionPanelCommands() }
    }

    /// The screenshot shown: this moment's (its own, or the one its window
    /// kept a moment earlier), else the one its History row shows.
    private var screenshot: Hit? {
        if hit.thumbnailURL != nil { return hit }
        return rowScreenshot.flatMap { $0.thumbnailURL != nil ? $0 : nil }
    }

    /// The clock time of the screenshot shown, when an earlier moment of the
    /// same window took it.
    private var screenshotTakenEarlier: String? {
        guard let shot = screenshot else { return nil }
        let taken = shot.thumbnailTsUs ?? shot.tsUs
        guard taken < hit.tsUs, shot.id != hit.id || hit.screenshotIsEarlier else { return nil }
        return Formatters.clockTime(us: Int64(clamping: taken))
    }

    @ViewBuilder
    private var screenshotSection: some View {
        if let shot = screenshot, let url = shot.thumbnailURL, url == unavailableScreenshot {
            unavailableScreenshotSection(url)
        } else if let shot = screenshot, let url = shot.thumbnailURL {
            Button { showsScreenshot = true } label: {
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { geometry in
                        EvidenceThumbnail(url: url, appBundleId: hit.appBundleId, size: geometry.size,
                                          maxPixelSize: MomentPicture.pixels(for: geometry.size, scale: displayScale),
                                          showsStatus: true,
                                          onUnavailable: { unavailableScreenshot = $0 })
                    }
                    .aspectRatio(16 / 10, contentMode: .fit)
                    HStack(spacing: MCI.Spacing.s) {
                        Label("Open screenshot", systemImage: "arrow.up.left.and.arrow.down.right")
                        Spacer(minLength: 0)
                        if let taken = screenshotTakenEarlier {
                            Text(UserFacingCopy.screenshotFrom(taken))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
            .buttonStyle(.plain)
            .disabled(reader == nil)
        } else {
            // Text only: the app, calmly.
            MomentTile(appBundleId: hit.appBundleId, caption: UserFacingCopy.textOnly)
                .frame(height: 64)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(UserFacingCopy.noScreenshot)
        }
    }

    /// A screenshot that did not open: gone from this Mac, or there but not
    /// opened this time (the Keychain was busy), which "Try Again" reads
    /// again.
    @ViewBuilder
    private func unavailableScreenshotSection(_ url: URL) -> some View {
        let missing = !FileManager.default.fileExists(atPath: url.path)
        let caption = missing ? UserFacingCopy.screenshotMissing : UserFacingCopy.screenshotLoadFailed
        VStack(alignment: .leading, spacing: MCI.Spacing.s) {
            MomentTile(appBundleId: hit.appBundleId, caption: caption)
                .frame(height: 64)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(caption)
            if !missing {
                Button(UserFacingCopy.tryAgainAction) {
                    Task {
                        _ = await screenshots.rereadScreenshotData(for: url)
                        unavailableScreenshot = nil
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func refreshActionPanelCommands() {
        for command in actionPanelCommands {
            ActionPanelRegistry.shared.register(command)
        }
    }

    private var actionPanelCommands: [ActionPanelCommand] {
        [
            .init(
                id: "hit.copySnippet",
                title: UserFacingCopy.copyTextAction,
                shortcut: "⌘C",
                category: .hit
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copiedBody, forType: .string)
            },
            .init(
                id: "hit.openInApp",
                title: UserFacingCopy.openInApp,
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
                title: UserFacingCopy.showRelated,
                shortcut: "⌘R",
                category: .hit,
                isEnabled: { !hit.linkedEventIds.isEmpty }
            ) {
                flyoutScope = .all(hitId: hit.id)
            },
        ]
    }

    /// What the moment was about, when it has a caption.
    private var caption: String? {
        hit.caption ?? reading?.caption
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: caption ?? Formatters.appDisplayName(hit.appBundleId))
                    .mciFont(.title2)
                    .foregroundStyle(Color.brandFgPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if reader != nil, !hit.linkedEventIds.isEmpty {
                    relatedBadge
                }
                Text(MemorySourceKind.label(hit.sourceKind))
                    .mciFont(.caption)
                    .padding(.horizontal, MCI.Spacing.s - 2)
                    .padding(.vertical, MCI.Spacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: MCI.Radius.xs)
                            .stroke(Color.brandFgMuted.opacity(0.5), lineWidth: 0.5)
                    )
                    .foregroundStyle(Color.brandFgSecondary)
            }
            if let caption {
                // Under a caption: the app, then what of the window's title
                // the caption does not say.
                Text(verbatim: MomentRowText.origin(hit, caption: caption))
                    .font(.system(.body, design: .default))
                    .foregroundStyle(Color.brandFgSecondary)
                    .lineLimit(2)
            } else if let title = hit.windowTitle, !title.isEmpty {
                Text(title)
                    .font(.system(.body, design: .default))
                    .foregroundStyle(Color.brandFgSecondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(Formatters.dayAndTime(us: hit.tsUs))
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(Color.brandFgSecondary)
            }
            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copiedBody, forType: .string)
                } label: {
                    Label(UserFacingCopy.copyTextAction, systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.brandMint)

                if let urlStr = hit.url, URL(string: urlStr) != nil {
                    Button(UserFacingCopy.openLink) {
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
        .help(UserFacingCopy.showRelatedHelp)
        .accessibilityLabel(UserFacingCopy.showRelatedCount(hit.linkedEventIds.count))
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

    /// What the person was reading, then "Also in this window", closed unless
    /// the search matched only there (RULINGS T12, T17).
    private var textSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UserFacingCopy.momentTextHeading(sourceKind: hit.sourceKind))
                .font(.system(.caption, design: .default).weight(.semibold))
                .foregroundStyle(Color.brandFgMuted)
            switch textModel.state(for: hit) {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(UserFacingCopy.momentTextLoading).font(.caption).foregroundStyle(.secondary)
                }
            case .unavailable, .failed:
                if !displayBody.isEmpty {
                    Text(UserFacingCopy.momentTextExcerpt)
                        .font(.caption).foregroundStyle(.secondary)
                }
            case let .loaded(text):
                if text.isTruncated {
                    Label(UserFacingCopy.momentTextFirstPart, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if displayBody.isEmpty {
                if hasSettled, reading?.rest.isEmpty ?? true {
                    Text(UserFacingCopy.momentTextEmpty).font(.body).foregroundStyle(.secondary)
                }
            } else {
                FormattedReadingView(text: displayBody, reading: reading)
            }
            if let reading, !reading.rest.isEmpty {
                AlsoInThisWindowDisclosure(rest: reading.rest, lineCount: reading.restLineCount,
                                           isExpanded: $showsRest)
            }
        }
    }

    /// The read finished, or could not be made: an empty text is really empty.
    private var hasSettled: Bool {
        switch textModel.state(for: hit) {
        case .idle, .loading: false
        case .unavailable, .failed, .loaded: true
        }
    }
}

/// The rest of a moment's window (tabs, sidebars, menus, status bars) after
/// its text: one closed disclosure, "Also in this window", with its line
/// count (RULINGS T12). Shared by the detail pane and the screenshot viewer.
struct AlsoInThisWindowDisclosure: View {
    let rest: String
    let lineCount: Int
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(rest)
                .font(.body)
                .foregroundStyle(Color.brandFgSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, MCI.Spacing.s)
        } label: {
            HStack(spacing: MCI.Spacing.s) {
                Text(UserFacingCopy.alsoInThisWindow)
                    .foregroundStyle(Color.brandFgPrimary)
                Text(UserFacingCopy.lineCount(lineCount))
                    .foregroundStyle(Color.brandFgMuted)
            }
            .font(.system(.caption, design: .default).weight(.semibold))
        }
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
                RoundedRectangle(cornerRadius: MCI.Radius.m)
                    .fill(Color.brandMintSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MCI.Radius.m)
                    .stroke(Color.brandMintDim, lineWidth: 0.5)
            )
            .foregroundStyle(Color.brandMint)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(name)
            .accessibilityHint(UserFacingCopy.mentions(name))
            .accessibilityAddTraits(.isButton)
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
                    get: { isFlyoutActive() },
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
