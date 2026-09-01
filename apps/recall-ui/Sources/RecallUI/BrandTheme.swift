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

    static var brandBgPrimary: Color { MCI.Color.background }
    static var brandBgSecondary: Color { MCI.Color.surface }
    static var brandBgElevated: Color { MCI.Color.surfaceElevated }

    static var brandFgPrimary: Color { MCI.Color.foreground }
    static var brandFgSecondary: Color { MCI.Color.foregroundSecondary }
    static var brandFgMuted: Color { MCI.Color.foregroundMuted }

    static var brandMint: Color { MCI.Color.accent }
    static var brandMintDim: Color { MCI.Color.accentDim }
    static var brandMintSubtle: Color { MCI.Color.accentSubtle }

    static var brandChange: Color { MCI.Color.change }
    static var brandError: Color { MCI.Color.error }
    static var brandWarning: Color { MCI.Color.warning }

    static var brandCardBg: Color { MCI.Color.surface }
    static var brandCardBorder: Color { MCI.Color.border }
    static var brandInputBorder: Color { MCI.Color.borderStrong }

    static func syntaxColor(for type: SyntaxTokenType) -> Color {
        switch type {
        case .keyword: return .brandMint
        case .string: return .brandWarning
        case .comment: return .brandFgMuted
        case .number: return MCI.Color.accentDim
        case .plain: return .brandFgPrimary
        }
    }
}

// Bridge legacy `brandXxx` names to the adaptive `MCI.Color.*`
// semantic tokens. During the incremental refactor, views may reference
// either surface; new code should prefer `MCI.Color.foreground` etc.
public extension Color {
    // Convenience: names that mirror MCI.Color for grep-ability.
    // resolve to the same dark-mode-first constants that BrandTheme
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                if reduceMotion {
                    phase = 0
                } else {
                    withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                        phase = 1.4
                    }
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
                    withAnimation(MCI.Motion.snap) {
                        showShimmer = true
                    }
                }
            }
        }
    }
}
