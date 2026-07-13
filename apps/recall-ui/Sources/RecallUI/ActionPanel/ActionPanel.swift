import AppKit
import RecallUIKit
import SwiftUI

/// ⌘K Action Panel modal — Raycast-style command palette answering
/// "what can I do here?" with inline keyboard-shortcut annotations.
/// Pure logic lives in `RecallUIKit/ActionPanelCore.swift`.
struct ActionPanel: View {
    @ObservedObject var registry: ActionPanelRegistry
    @StateObject private var viewModel = ActionPanelViewModel()
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { registry.hide() }
                .accessibilityLabel("Dismiss command palette")

            VStack(spacing: 0) {
                inputField
                Divider().background(Color.brandCardBorder)
                commandList
            }
            .frame(width: 450)
            .frame(maxHeight: 400)
            .background(Color.brandBgSecondary)
            // Cycle 8.48 MCIDesignSystem: use modal radius + modal shadow
            // preset so all floating panels (this + GlobalRecallPopup)
            // share a single depth language.
            .clipShape(RoundedRectangle(cornerRadius: MCI.Radius.l))
            .mciShadow(.modal)
            .overlay(
                RoundedRectangle(cornerRadius: MCI.Radius.l)
                    .strokeBorder(Color.brandCardBorder, lineWidth: 1)
            )
        }
        .onAppear { viewModel.reset(); isFieldFocused = true }
        .onKeyPress(.escape, phases: .down) { _ in registry.hide(); return .handled }
        .onKeyPress(.upArrow, phases: .down) { _ in viewModel.selectPrev(); return .handled }
        .onKeyPress(.downArrow, phases: .down) { _ in
            viewModel.selectNext(in: viewModel.filtered(from: registry.commands))
            return .handled
        }
    }

    private var inputField: some View {
        HStack(spacing: 10) {
            Image(systemName: "command").foregroundStyle(Color.brandFgMuted)
            TextField("Type a command…", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(Color.brandFgPrimary)
                .focused($isFieldFocused)
                .onSubmit {
                    viewModel.invoke(from: viewModel.filtered(from: registry.commands))
                }
                .accessibilityLabel("Command palette query")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var commandList: some View {
        let list = viewModel.filtered(from: registry.commands)
        if list.isEmpty {
            HStack {
                Text(viewModel.query.isEmpty ? "No commands registered" : "No matches")
                    .foregroundStyle(Color.brandFgMuted)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { idx, cmd in
                        row(cmd: cmd, isSelected: idx == viewModel.selectedIndex)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectedIndex = idx
                                viewModel.invoke(from: list)
                            }
                    }
                }
            }
        }
    }

    private func row(cmd: ActionPanelCommand, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(cmd.title).font(.system(size: 14)).foregroundStyle(Color.brandFgPrimary)
            Text(cmd.category.rawValue)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.brandBgElevated)
                .foregroundStyle(Color.brandFgSecondary)
                .clipShape(Capsule())
            Spacer()
            Text(cmd.shortcut)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.brandFgMuted)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(isSelected ? Color(hex: 0x533AFD, opacity: 0.18) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(cmd.title), \(cmd.category.rawValue), shortcut \(cmd.shortcut)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    /// Attach at the app root so ⌘K anywhere opens the panel.
    func actionPanelHost(registry: ActionPanelRegistry = .shared) -> some View {
        modifier(ActionPanelHost(registry: registry))
    }

    /// Register commands while a view is on-screen; unregister on
    /// disappear so contextual gating works naturally.
    func registerActionPanelCommands(
        _ commands: [ActionPanelCommand],
        registry: ActionPanelRegistry = .shared
    ) -> some View {
        onAppear { for c in commands { registry.register(c) } }
            .onDisappear { for c in commands { registry.unregister(id: c.id) } }
    }
}

struct ActionPanelHost: ViewModifier {
    @ObservedObject var registry: ActionPanelRegistry

    func body(content: Content) -> some View {
        ZStack {
            content.onKeyPress(.init("k"), phases: .down) { press in
                guard press.modifiers == .command else { return .ignored }
                registry.toggle()
                return .handled
            }
            if registry.isVisible {
                ActionPanel(registry: registry).transition(.opacity)
            }
        }
        // Cycle 8.48 MCIDesignSystem: opt into the shared `snap` motion
        // token so every quick reveal in the app times the same.
        .animation(MCI.Motion.snap, value: registry.isVisible)
    }
}
