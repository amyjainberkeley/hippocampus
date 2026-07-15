import SwiftUI
import OnboardingKit

struct TrustSlide: View {
    @EnvironmentObject var trustVM: TrustPanelViewModel
    @State private var showKeyWrapAudit = false

    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
                VStack(spacing: OnboardingDesign.Space.md) {
                    SectionChip(text: "Trust")
                    OnboardingDesign.TypeRamp.title("Built for trust, not promises")
                        .multilineTextAlignment(.center)
                }

                pipelineView

                VStack(alignment: .leading, spacing: OnboardingDesign.Space.md) {
                    IconTextRow(
                        icon: "key.fill",
                        title: "256-bit key sealed on this Mac."
                    )
                    Button("How is the key sealed?") {
                        showKeyWrapAudit = true
                    }
                    .onboardingText(color: OnboardingDesign.Palette.accent)
                    .padding(.leading, 34)
                    .accessibilityIdentifier("TrustSlideInspectKeyWrap")

                    IconTextRow(
                        icon: "shield.checkered",
                        title: "Seven layers of protection filter what reaches your brain."
                    )
                    IconTextRow(
                        icon: "network.slash",
                        title: "Zero network — your data never leaves this Mac."
                    )
                }
                .glassCard(padding: OnboardingDesign.Space.lg)

                cascadePreview
            }
        }
        .sheet(isPresented: $showKeyWrapAudit) {
            KeyWrapAuditView(
                initialReport: currentReport(),
                reverify: { currentReport() },
                onClose: { showKeyWrapAudit = false }
            )
        }
        // Load the CSO baseline denylist so the RetentionSlide "Always
        // blocked" preview reflects the real shipped policy instead of
        // the hardcoded 5-entry fallback in `defaultBlockedList`. Cascade
        // steps render fine either way (they're a static `let`), but any
        // new dynamic surface reading `trustVM.denylistEntries` /
        // `trustVM.allowlistEntries` was silently empty before this call.
        // `TrustPanelViewModel.load()` swallows errors (empty arrays on
        // failure), so the hardcoded fallback in RetentionSlide remains
        // the safety net.
        .task {
            await trustVM.load()
        }
    }

    private func currentReport() -> KeyWrapAuditReport {
        KeyWrapAuditor.inspectFile(at: DefaultKeyWrapLocation.devKeyURL())
    }

    private var pipelineView: some View {
        HStack(spacing: 0) {
            pipelineStep(icon: "eye", label: "Apple Vision\nOCR")
            pipelineArrow
            pipelineStep(icon: "lock.doc", label: "SQLCipher\n256-bit")
            pipelineArrow
            pipelineStep(icon: "magnifyingglass", label: "Local\nSearch")
        }
        .glassCard(padding: OnboardingDesign.Space.lg)
    }

    private func pipelineStep(icon: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(OnboardingDesign.Palette.accent)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var pipelineArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 14))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
    }

    private var cascadePreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Privacy Cascade")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(trustVM.cascadeSteps) { step in
                HStack(spacing: 8) {
                    Text("§\(step.section)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(OnboardingDesign.Palette.accent)
                        .frame(width: 22)
                    Text(step.label)
                        .font(.system(size: 12))
                    Spacer()
                }
            }
        }
        .glassCard(padding: OnboardingDesign.Space.md)
    }
}
