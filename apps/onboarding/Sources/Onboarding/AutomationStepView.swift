import SwiftUI
import OnboardingKit

struct AutomationStepView: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel

    private let browsers: [(name: String, icon: String)] = [
        ("Safari", "safari"),
        ("Chrome", "globe"),
        ("Arc", "globe"),
        ("Brave", "globe"),
        ("Edge", "globe"),
        ("Firefox", "globe"),
    ]

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Automation (per browser)")
                .font(.title)
                .fontWeight(.semibold)

            Text("Automation lets Hippocampus read the URL of the page you're viewing — needed for \"find that article I read last week.\" Each browser needs a separate grant.")
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(browsers, id: \.name) { browser in
                    HStack(spacing: 10) {
                        Image(systemName: browser.icon)
                            .frame(width: 20)
                        Text(browser.name)
                            .font(.body)
                        Spacer()
                        Image(systemName: "circle")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 360)

            Button("Open System Settings") {
                flowVM.automationPermission.requestOrOpenSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("You can skip any browser. Those browsers just won't have URL indexing.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
