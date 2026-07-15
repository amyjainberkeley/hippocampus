import SwiftUI
import OnboardingKit

/// V2-P10 — user-curated allowlist slide. Two-layer per ADR-0017 §3.2:
/// the CSO baseline is shown read-only; the user-mutable layer below
/// lets the user opt in detected running apps or hand-type bundle ids.
/// Per-app deep-hook opt-in (Messages V2-P7 / Mail V2-P8b) triggers
/// the Full Disk Access deep-link per ADR-0032 §3(b).
struct AllowlistSlide: View {
    @EnvironmentObject var editorVM: AllowlistEditorViewModel
    @State private var customBundleId: String = ""
    @State private var customRationale: String = ""

    var body: some View {
        SlideContainer {
            VStack(alignment: .leading, spacing: OnboardingDesign.Space.lg) {
                SectionChip(text: "Trusted apps")

                OnboardingDesign.TypeRamp.title("Which apps should Hippocampus remember?")

                OnboardingDesign.TypeRamp.body("Hippocampus only captures from apps you explicitly trust. The first set below is the always-on baseline that ships with the app; you can opt in additional apps yourself.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520, alignment: .leading)

                ScrollView {
                    VStack(alignment: .leading, spacing: OnboardingDesign.Space.md) {
                        baselineSection
                        userSection
                        expertSection
                    }
                    .padding(.vertical, OnboardingDesign.Space.sm)
                }
            }
        }
        .task {
            await editorVM.load()
        }
    }

    private var baselineSection: some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.sm) {
            sectionHeader(
                title: "Built-in trusted apps (\(baselineRows.count))",
                subtitle: "These bundles ship in the signed app and have been reviewed by the security team. Read-only."
            )
            VStack(alignment: .leading, spacing: OnboardingDesign.Space.xs) {
                ForEach(baselineRows) { row in
                    rowSummaryView(row: row)
                }
            }
            .glassCard(padding: OnboardingDesign.Space.md)
        }
    }

    private var userSection: some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.sm) {
            sectionHeader(
                title: "Your additions (\(userRows.count))",
                subtitle: "Running apps you can add to the allowlist. The cascade still gates each event the same way — passwords, secure-input, and unknown surfaces stay redacted."
            )
            if userRows.isEmpty {
                OnboardingDesign.TypeRamp.caption("No additions yet. Toggle a running app below or use the expert UI to add a bundle by id.")
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, OnboardingDesign.Space.sm)
            } else {
                VStack(spacing: OnboardingDesign.Space.sm - 2) {
                    ForEach(userRows) { row in
                        userRowEditor(row: row)
                    }
                }
            }
            if editorVM.fullDiskAccessStatus == .requested {
                fdaHint
            }
        }
    }

    private var expertSection: some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.sm) {
            sectionHeader(
                title: "Expert: add a bundle by id",
                subtitle: "If the app you want isn't running right now, enter its bundle identifier (e.g. `com.spotify.client`)."
            )
            HStack(spacing: OnboardingDesign.Space.sm) {
                TextField("com.example.app", text: $customBundleId)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Button("Add") {
                    Task {
                        let trimmed = customBundleId
                        let rationale = customRationale.isEmpty ? nil : customRationale
                        _ = await editorVM.addCustomBundle(
                            bundleId: trimmed,
                            rationale: rationale
                        )
                        customBundleId = ""
                        customRationale = ""
                    }
                }
                .onboardingSecondary()
                .disabled(customBundleId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            TextField("Why? (optional note)", text: $customRationale)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 380)
            if let err = editorVM.lastError {
                OnboardingDesign.TypeRamp.caption(errorString(err))
                    .foregroundStyle(OnboardingDesign.Palette.danger)
            }
        }
        .glassCard(padding: OnboardingDesign.Space.md)
    }

    private var fdaHint: some View {
        IconTextRow(
            icon: "exclamationmark.shield",
            title: "Full Disk Access requested",
            detail: "Deep-hook plugins (Messages, Mail) need this. Confirm the grant in System Settings → Privacy & Security → Full Disk Access, then return here.",
            iconColor: OnboardingDesign.Palette.attention
        )
        .padding(OnboardingDesign.Space.md)
        .background(
            RoundedRectangle(cornerRadius: OnboardingDesign.Radius.control, style: .continuous)
                .fill(OnboardingDesign.Palette.attention.opacity(0.10))
        )
    }

    // MARK: - Helpers

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.xs / 2) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            OnboardingDesign.TypeRamp.footnote(subtitle)
                .foregroundStyle(.secondary)
        }
    }

    private func rowSummaryView(row: EditorRow) -> some View {
        IconTextRow(
            icon: "checkmark.circle.fill",
            title: row.displayName,
            detail: row.bundleId,
            iconColor: OnboardingDesign.Palette.success
        )
    }

    @ViewBuilder
    private func userRowEditor(row: EditorRow) -> some View {
        HStack(spacing: OnboardingDesign.Space.sm + 2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                    .font(.system(size: 13, weight: .medium))
                OnboardingDesign.TypeRamp.mono(row.bundleId)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Picker("", selection: postureBinding(for: row)) {
                Text("Off").tag(AllowlistTogglePosture.off)
                Text("Capture").tag(AllowlistTogglePosture.captureOnly)
                if row.supportsDeepHook {
                    Text("Capture + Deep hook").tag(AllowlistTogglePosture.captureAndDeepHook)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            .labelsHidden()
            .accessibilityLabel("Capture posture for \(row.displayName)")
            Button {
                Task { await editorVM.removeUserEntry(bundleId: row.bundleId) }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove from user allowlist")
            .accessibilityLabel("Remove \(row.displayName) from allowlist")
        }
        .glassCard(padding: OnboardingDesign.Space.sm)
    }

    private func postureBinding(for row: EditorRow) -> Binding<AllowlistTogglePosture> {
        Binding<AllowlistTogglePosture>(
            get: {
                editorVM.rows.first(where: { $0.bundleId == row.bundleId })?.posture
                    ?? .off
            },
            set: { newValue in
                Task {
                    await editorVM.setPosture(for: row.bundleId, to: newValue)
                }
            }
        )
    }

    private var baselineRows: [EditorRow] {
        editorVM.rows.filter { $0.isBaselineEntry }
    }

    private var userRows: [EditorRow] {
        editorVM.rows.filter { !$0.isBaselineEntry }
    }

    private func errorString(_ err: AllowlistEditorError) -> String {
        switch err {
        case .emptyBundleId:
            return "Bundle id cannot be empty."
        case .duplicateOfBaseline(let id):
            return "\(id) is already in the built-in trusted set."
        case .duplicateOfUserLayer(let id):
            return "\(id) is already in your additions."
        }
    }
}
