import SwiftUI
import OnboardingKit

struct OnboardingProgressBar: View {
    let currentStep: OnboardingStep

    private var progress: Double {
        Double(currentStep.rawValue) / Double(OnboardingStep.allCases.count - 1)
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(OnboardingTheme.accentBlue)
                        .frame(width: geo.size.width * progress, height: 4)
                        .animation(.easeInOut(duration: 0.3), value: currentStep)
                }
            }
            .frame(height: 4)

            HStack {
                Text(currentStep.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(currentStep.stepLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
    }
}
