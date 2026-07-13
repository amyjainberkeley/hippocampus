import RecallUIKit
import SwiftUI

extension Color {
    init(hex: UInt, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    static let brandBgPrimary = Color(hex: 0x0D0D0D)
    static let brandBgSecondary = Color(hex: 0x1A1A1A)
    static let brandBgElevated = Color(hex: 0x262626)

    static let brandFgPrimary = Color(hex: 0xE0E0E0)
    static let brandFgSecondary = Color(hex: 0x999999)
    static let brandFgMuted = Color(hex: 0x666666)

    static let brandMint = Color(hex: 0x7AFFC1)
    static let brandMintDim = Color(hex: 0x3D8060)
    static let brandMintSubtle = Color(hex: 0x1A3D2E)

    static let brandError = Color(hex: 0xFF6B6B)
    static let brandWarning = Color(hex: 0xFFD93D)

    static let brandCardBg = Color(hex: 0x1A1A1A)
    static let brandCardBorder = Color(hex: 0x333333)
    static let brandInputBorder = Color(hex: 0x404040)

    static func syntaxColor(for type: SyntaxTokenType) -> Color {
        switch type {
        case .keyword: return .brandMint
        case .string: return .brandWarning
        case .comment: return .brandFgMuted
        case .number: return Color(hex: 0xB8D4FF)
        case .plain: return .brandFgPrimary
        }
    }
}

// Bridge legacy `brandXxx` names to the `MCI.Color.*` semantic tokens
// (cycle 8.48 MCIDesignSystem PR). During the incremental refactor,
// views MAY reference either surface — new code should prefer
// `MCI.Color.foreground` etc.; the aliases below let a diff stay
// small on any given view PR.
//
// The mapping is deliberately conservative: it does NOT lift the
// legacy dark-only palette onto MCI's new light+dark aware tokens
// automatically, because BrandTheme's constants are hex-literal (dark
// mode only). A follow-up cycle can flip individual `Color.brandXxx`
// references to the light-adaptive tokens once each view is verified
// visually. Track that in `docs/design/design-system.md` §Migration.
public extension Color {
    // Convenience: names that mirror MCI.Color for grep-ability. They
    // resolve to the same dark-mode-first constants that BrandTheme
    // has always produced, so no visual delta lands with this PR.
    static var mciAccent: Color { .brandMint }
    static var mciAccentDim: Color { .brandMintDim }
    static var mciAccentSubtle: Color { .brandMintSubtle }
    static var mciBackground: Color { .brandBgPrimary }
    static var mciSurface: Color { .brandBgSecondary }
    static var mciSurfaceElevated: Color { .brandBgElevated }
    static var mciForeground: Color { .brandFgPrimary }
    static var mciForegroundSecondary: Color { .brandFgSecondary }
    static var mciForegroundMuted: Color { .brandFgMuted }
    static var mciBorder: Color { .brandCardBorder }
    static var mciBorderStrong: Color { .brandInputBorder }
    static var mciError: Color { .brandError }
    static var mciWarning: Color { .brandWarning }
}

struct ShimmerView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.brandBgElevated)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.06), location: 0.5),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.4)
                    .offset(x: geo.size.width * phase)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1.4
                }
            }
    }
}

struct ShimmerLoadingView: View {
    let isLoading: Bool
    @State private var showShimmer = false

    var body: some View {
        Group {
            if showShimmer {
                VStack(spacing: 12) {
                    ForEach(0..<5, id: \.self) { _ in
                        ShimmerView()
                            .frame(height: 48)
                    }
                }
                .padding()
                .transition(.opacity)
            }
        }
        .task(id: isLoading) {
            showShimmer = false
            if isLoading {
                try? await Task.sleep(for: .milliseconds(200))
                if !Task.isCancelled {
                    withAnimation(.easeIn(duration: 0.2)) {
                        showShimmer = true
                    }
                }
            }
        }
    }
}
