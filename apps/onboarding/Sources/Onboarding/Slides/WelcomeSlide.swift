import SwiftUI
import AppKit
import OnboardingKit

struct WelcomeSlide: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel

    var body: some View {
        SlideContainer {
            VStack(spacing: 24) {
                // Rewind-migrator sub-header — renders ONLY when the app
                // was launched via `onboarding://start?migration=rewind`
                // (cycle 8.37 `/rewind` landing lane, PR #30). Copy is
                // held verbatim from the audit doc so a stale deep-link
                // never surprises a non-Rewind user.
                if flowVM.migrationSource == .rewind {
                    rewindSubheader
                }

                // Brand hero — the same head+brain glyph the menu-bar uses, at 72pt.
                // CSO note (cycle 8.12 / PR #214): MUST NOT regress to SF Symbol
                // `brain.head.profile` here — Apple SF Symbols License §2(b) prohibits
                // SF Symbol use as a logo / app identifier on a notarized public DMG.
                // Source asset: `assets/branding/AppIcon.svg` (commissioned per PR #205,
                // wired through `AppIcon.icns` in `Hippocampus.app/Contents/Resources/`).
                Image(nsImage: Self.heroIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)

                VStack(spacing: 8) {
                    OnboardingTheme.title("Welcome to Hippocampus")
                    OnboardingTheme.subtitle("Your memory, on your machine.")
                }

                VStack(alignment: .leading, spacing: 14) {
                    bulletPoint(
                        icon: "lock.fill",
                        text: "Everything stays on this Mac — zero network, fully encrypted."
                    )
                    bulletPoint(
                        icon: "eye.slash.fill",
                        text: "Passwords, secure fields, and DRM content are blocked at capture — not after."
                    )
                    // Cycle 8.54 copy audit — "brain" → "memory".
                    bulletPoint(
                        icon: "key.fill",
                        text: "Your memory is encrypted on disk. Only you hold the key."
                    )
                }
                .padding(.top, 8)
            }
        }
    }

    private var rewindSubheader: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(OnboardingTheme.accentBlue)
                .frame(width: 20)
            Text(OnboardingCopy.welcomeRewindSubheader)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding(10)
        .background(OnboardingTheme.accentBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 420)
    }

    private func bulletPoint(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(OnboardingTheme.accentBlue)
            Text(text)
                .font(.system(size: 14))
        }
    }

    /// Loaded once. Resolves `AppIcon.icns` from `Hippocampus.app/Contents/Resources/`
    /// via `NSImage(named:)` — for an executable Mach-O inside an .app bundle,
    /// `Bundle.main` is the containing .app, so this lookup finds the shipped asset.
    /// Falls back to a 72×72 transparent image if the resource is missing (e.g. the
    /// onboarding binary was launched outside Hippocampus.app for debugging).
    private static let heroIcon: NSImage = {
        if let icon = NSImage(named: "AppIcon") {
            return icon
        }
        return NSImage(size: NSSize(width: 72, height: 72))
    }()
}
