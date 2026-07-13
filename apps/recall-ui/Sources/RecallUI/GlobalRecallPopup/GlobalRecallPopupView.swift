// GlobalRecallPopupView.swift — the Spotlight-like popup UI hosted
// in `GlobalRecallPopupPanel`. Pure SwiftUI; all binding logic lives
// in `GlobalRecallPopupViewModel` (RecallUIKit).
//
// See `GlobalRecallPopupPanel.swift` for the NSPanel plumbing that
// makes the popup float above the frontmost app and dismiss on Esc /
// click-outside / repeat-hotkey.

import AppKit
import RecallUIKit
import SwiftUI

struct GlobalRecallPopupView: View {
    @ObservedObject var viewModel: GlobalRecallPopupViewModel
    /// Called by the view when the user picks a result. The parent
    /// panel dismisses itself and routes the action (external URL vs
    /// DetailPane) — the view doesn't reach into NSApp directly.
    let onInvoke: (PopupHitAction) -> Void
    /// Called on Esc / click-outside / hotkey-toggle to dismiss.
    let onDismiss: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            inputField
            Divider().background(Color.brandCardBorder)
            resultList
        }
        .frame(width: 640)
        .background(Color.brandBgSecondary.opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.brandCardBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 32, x: 0, y: 12)
        .onAppear { isFieldFocused = true }
        .onKeyPress(.escape, phases: .down) { _ in
            onDismiss(); return .handled
        }
        .onKeyPress(.upArrow, phases: .down) { _ in
            viewModel.selectPrev(); return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { _ in
            viewModel.selectNext(); return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            let preferExternal = press.modifiers.contains(.command)
            if let action = viewModel.invokeAction(preferExternal: preferExternal) {
                onInvoke(action)
            }
            return .handled
        }
    }

    private var inputField: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundStyle(Color.brandMint)
                .font(.system(size: 18))
            TextField("Recall anything…", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .foregroundStyle(Color.brandFgPrimary)
                .focused($isFieldFocused)
                .accessibilityLabel("Recall query")
            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Searching")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var resultList: some View {
        if viewModel.results.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.results.enumerated()), id: \.element.eventId) {
                        idx, hit in
                        row(hit: hit, isSelected: idx == viewModel.selectedIndex)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let action = viewModel.invokeAction(preferExternal: false) {
                                    onInvoke(action)
                                }
                            }
                    }
                }
            }
            .frame(maxHeight: 400)
        }
    }

    private var emptyState: some View {
        HStack {
            Text(emptyStateText)
                .foregroundStyle(Color.brandFgMuted)
                .font(.system(size: 13))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var emptyStateText: String {
        if viewModel.query.isEmpty {
            return "Type to search everything you've seen. ⇧⌘Space to toggle."
        }
        if viewModel.isSearching {
            return "Searching…"
        }
        return "No results"
    }

    @ViewBuilder
    private func row(hit: Hit, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: appIcon(for: hit.appBundleId))
                .resizable().interpolation(.high).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Formatters.contextLine(hit))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.brandFgPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(Formatters.relativeTime(usSinceEpoch: hit.tsUs))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.brandMintDim)
                }
                Text(Formatters.snippet(Formatters.stripContextHeader(hit.ocrTextSnippet)))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.brandFgSecondary)
                    .lineLimit(2)
                if !hit.entities.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(hit.entities.prefix(4)), id: \.self) { name in
                            Text(name)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.brandMintSubtle)
                                .foregroundStyle(Color.brandMint)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(isSelected ? Color.brandBgElevated : Color.clear)
    }

    /// Launch-Services icon lookup for a bundle id; generic doc icon
    /// on nil / unresolvable id.
    private func appIcon(for bundleId: String?) -> NSImage {
        if let id = bundleId,
           let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}
