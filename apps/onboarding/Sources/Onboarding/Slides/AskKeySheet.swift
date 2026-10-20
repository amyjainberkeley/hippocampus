import AppKit
import OnboardingKit
import SwiftUI

/// The key that opens Ask, chosen in setup (SPEC-DELTA 7): a sheet from the
/// Accessibility row's Change… button. Two cards, Shift twice (the default)
/// and Fn (Globe), each with its keycaps. Once Fn is picked, what else uses
/// Fn on this Mac shows under the cards: an app that holds Fn, by name;
/// macOS's own Globe key setting, with the exact step and Open Keyboard
/// Settings; a keyboard without Fn. With an app or macOS using Fn, the
/// default button reads Use Fn, so Fn is only ever taken by the person's
/// own click. Cancel changes nothing.
struct AskKeySheet: View {
    @ObservedObject var model: AskKeyPickerModel
    let cancel: () -> Void
    let confirm: () -> Void
    let openKeyboardSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 520

    var body: some View {
        VStack(spacing: OnboardingDesign.Space.lg + 4) {
            Text(OnboardingCopy.AskKey.title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(OnboardingDesign.Palette.ink)
                .accessibilityAddTraits(.isHeader)

            HStack(alignment: .top, spacing: OnboardingDesign.Space.md) {
                ForEach(SetupAskKey.allCases, id: \.self) { key in
                    KeyCard(key: key, selected: model.selection == key) {
                        model.selection = key
                    }
                }
            }

            if !model.notes.isEmpty {
                FnNotes(notes: model.notes, openKeyboardSettings: openKeyboardSettings)
                    .transition(.opacity)
            }

            HStack(spacing: OnboardingDesign.Space.md) {
                Spacer(minLength: 0)
                Button(OnboardingCopy.AskKey.cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .onboardingSecondary()
                Button(model.confirmLabel, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .onboardingPrimary()
                    .disabled(model.selection == nil)
                    .opacity(model.selection == nil ? PrimaryButtonMotion.disabledOpacity : 1)
            }
        }
        .padding(OnboardingDesign.Space.xl)
        .frame(width: Self.width)
        .background(OnboardingDesign.Palette.windowSolid)
        .animation(OnboardingDesign.Motion.resolve(.easeOut(duration: 0.2), reduceMotion: reduceMotion),
                   value: model.selection)
        .animation(OnboardingDesign.Motion.resolve(.easeOut(duration: 0.2), reduceMotion: reduceMotion),
                   value: model.check)
        // Back from Keyboard settings: the Globe key may be set now.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.recheck()
        }
    }
}

/// One key: its keycaps, its name and how it is pressed. Picked, it takes
/// the accent's border and a check.
private struct KeyCard: View {
    let key: SetupAskKey
    let selected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(spacing: OnboardingDesign.Space.sm + 2) {
                KeycapRow(keycaps: key.hint.keycaps, size: 17)
                    .frame(height: 36)
                Text(key.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OnboardingDesign.Palette.ink)
                Text(key.line)
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingDesign.Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, OnboardingDesign.Space.lg)
            .padding(.top, OnboardingDesign.Space.lg + 2)
            .padding(.bottom, OnboardingDesign.Space.lg)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? OnboardingDesign.Palette.accentSoft : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? OnboardingDesign.Palette.accent : Color.primary.opacity(0.12),
                                  lineWidth: selected ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(OnboardingDesign.Palette.accent)
                    .padding(OnboardingDesign.Space.sm + 2)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(key.label)
        .accessibilityHint(key.line)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// What else uses Fn: an orange triangle beside a warning, a grey circle
/// beside a note. The words keep the text's own colours.
private struct FnNotes: View {
    let notes: [FnKeyNote]
    let openKeyboardSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.md) {
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: OnboardingDesign.Space.sm + 2) {
                    Image(systemName: note.isWarning ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(note.isWarning ? OnboardingDesign.Palette.attention
                                         : OnboardingDesign.Palette.secondaryText)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: OnboardingDesign.Space.xs + 2) {
                        Text(note.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let step = note.step {
                            Text(step)
                                .font(.system(size: 12))
                                .foregroundStyle(OnboardingDesign.Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(OnboardingCopy.AskKey.openKeyboardSettings, action: openKeyboardSettings)
                                .buttonStyle(RowButtonStyle(filled: false))
                                .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding(OnboardingDesign.Space.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}
