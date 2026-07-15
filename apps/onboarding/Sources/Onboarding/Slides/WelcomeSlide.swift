import SwiftUI
import AppKit
import OnboardingKit

struct WelcomeSlide: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel

    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
                // Rewind-migrator sub-header — renders ONLY when the app
                // was launched via `onboarding://start?migration=rewind`
                // (cycle 8.37 `/rewind` landing lane, PR #30). Copy is
                // held verbatim from the audit doc so a stale deep-link
                // never surprises a non-Rewind user.
                if flowVM.migrationSource == .rewind {
                    rewindSubheader
                }

                // The "moment" — oversized display title over the brand
                // glyph, with the calm fade-and-rise entrance.
                //
                // CSO note (cycle 8.12 / PR #214): the glyph MUST be the
                // commissioned AppIcon, NOT SF Symbol `brain.head.profile`
                // — Apple SF Symbols License §2(b) prohibits SF Symbol use
                // as a logo / app identifier on a notarized public DMG.
                HeroHeader(
                    title: "Welcome to Hippocampus",
                    subtitle: "Your memory, on your machine.",
                    titleStyle: .display
                ) {
                    Image(nsImage: Self.heroIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 76, height: 76)
                }

                VStack(alignment: .leading, spacing: OnboardingDesign.Space.md) {
                    IconTextRow(
                        icon: "lock.fill",
                        title: "Everything stays on this Mac — zero network, fully encrypted."
                    )
                    IconTextRow(
                        icon: "eye.slash.fill",
                        title: "Passwords, secure fields, and DRM content are blocked at capture — not after."
                    )
                    // Cycle 8.54 copy audit — "brain" → "memory".
                    IconTextRow(
                        icon: "key.fill",
                        title: "Your memory is encrypted on disk. Only you hold the key."
                    )
                }
                .frame(maxWidth: 460)
                .glassCard(padding: OnboardingDesign.Space.xl)
                .padding(.top, OnboardingDesign.Space.xs)
            }
        }
    }

    private var rewindSubheader: some View {
        HStack(alignment: .top, spacing: OnboardingDesign.Space.sm) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(OnboardingDesign.Palette.accent)
                .frame(width: 20)
            Text(OnboardingCopy.welcomeRewindSubheader)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding(OnboardingDesign.Space.md)
        .frame(maxWidth: 420)
        .glassCard(padding: OnboardingDesign.Space.md, emphasized: true)
    }

    /// Loaded once. Resolves `AppIcon.icns` from `Hippocampus.app/Contents/Resources/`
    /// via `NSImage(named:)` — for an executable Mach-O inside an .app bundle,
    /// `Bundle.main` is the containing .app, so this lookup finds the shipped asset.
    /// Falls back to a 76×76 transparent image if the resource is missing (e.g. the
    /// onboarding binary was launched outside Hippocampus.app for debugging).
    private static let heroIcon: NSImage = {
        if let icon = NSImage(named: "AppIcon") {
            return icon
        }
        return NSImage(size: NSSize(width: 76, height: 76))
    }()
}
