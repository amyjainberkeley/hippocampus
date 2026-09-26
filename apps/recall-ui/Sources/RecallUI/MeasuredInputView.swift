import Charts
import RecallUIKit
import SwiftUI

struct MeasuredInputView: View {
    let summary: ActivitySummary
    @State private var selectedState: MeasuredInputState?
    @State private var selectedSeconds: Double?
    @State private var showsIntervals = false
    @State private var selectedApp: String?
    @State private var selectedStretch: ActivitySummary.ForegroundStretch?
    @State private var showsAllApps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your day").font(.title2.weight(.semibold))
            Text("\(time(summary.startUs)) to \(time(summary.endUs))")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 28) {
                Chart(MeasuredInputState.allCases) { state in
                    SectorMark(angle: .value("Seconds", Double(summary.totalUs(for: state)) / 1_000_000),
                               innerRadius: .ratio(0.78), angularInset: 1.5)
                        .foregroundStyle(color(state))
                        .accessibilityLabel(state.label)
                        .accessibilityValue(duration(summary.totalUs(for: state)))
                }
                .chartAngleSelection(value: $selectedSeconds)
                .frame(width: 148, height: 148)
                .overlay {
                    VStack(spacing: 3) {
                        Text(duration(summary.totalUs(for: .inputActive) + summary.totalUs(for: .inputIdle)))
                            .font(.title3.weight(.semibold)).monospacedDigit()
                        Text("Measured").font(.caption).foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
                }
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(MeasuredInputState.allCases) { state in
                        Button {
                            selectedApp = nil
                            selectedStretch = nil
                            selectedState = selectedState == state ? nil : state
                            showsIntervals = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedState == state ? "checkmark.circle.fill" : "circle.fill")
                                    .font(.caption2).foregroundStyle(color(state))
                                Text(state.label).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(duration(summary.totalUs(for: state)))
                                    .foregroundStyle(.primary).monospacedDigit()
                            }
                            .font(.callout)
                        }
                        .buttonStyle(.borderless)
                        .help("Inspect \(state.label.lowercased()) intervals")
                    }
                }
                .frame(maxWidth: 340)
            }
            .onChange(of: selectedSeconds) { _, seconds in
                guard let seconds else { return }
                var end: Double = 0
                for state in MeasuredInputState.allCases {
                    end += Double(summary.totalUs(for: state)) / 1_000_000
                    if seconds < end {
                        selectedState = state
                        selectedApp = nil
                        selectedStretch = nil
                        showsIntervals = true
                        break
                    }
                }
            }
            ForEach(showsAllApps ? summary.appTotals : Array(summary.appTotals.prefix(5))) { app in
                HStack {
                    Button {
                        selectedState = nil
                        selectedStretch = nil
                        selectedApp = selectedApp == app.appBundleId ? nil : app.appBundleId
                        showsIntervals = true
                    } label: {
                        HStack {
                            Label(Formatters.appDisplayName(app.appBundleId), systemImage: "macwindow")
                            Spacer(minLength: 12)
                            Text(duration(app.totalUs)).monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .help("Inspect measured foreground time for \(Formatters.appDisplayName(app.appBundleId))")
                }
            }
            if summary.appTotals.count > 5 {
                Button {
                    showsAllApps.toggle()
                } label: {
                    Label(showsAllApps ? "Fewer apps" : "All apps", systemImage: showsAllApps ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless).font(.caption)
            }
            if let stretch = summary.longestForegroundStretch {
                Button {
                    selectedState = nil
                    selectedApp = nil
                    selectedStretch = stretch
                    showsIntervals = true
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Longest measured stretch").font(.caption).foregroundStyle(.secondary)
                            Text("\(duration(stretch.durationUs)) in \(Formatters.appDisplayName(stretch.appBundleId))")
                                .font(.callout.weight(.medium)).foregroundStyle(.primary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                }
                .buttonStyle(.borderless)
                .help("Consecutive recorded intervals in one foreground app. Gaps end a stretch; this is not a measure of attention.")
            }
            Text("Recent input uses a 60-second threshold. Input state and foreground apps do not establish attention or completed work. Unknown includes gaps in measurement.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Intervals", isExpanded: $showsIntervals) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(summary.intervals.filter { interval in
                            (selectedState == nil || interval.inputState == selectedState)
                                && (selectedApp == nil || interval.appBundleId == selectedApp)
                                && (selectedStretch.map { interval.startUs >= $0.startUs && interval.endUs <= $0.endUs } ?? true)
                        }) { interval in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(time(interval.startUs)) to \(time(interval.endUs)) / \(interval.inputState.label)")
                                Text(interval.isGap ? "No interval recorded" :
                                    interval.inputState == .unknown ? "Recorded as unknown" :
                                    interval.appBundleId.map { "Foreground: \(Formatters.appDisplayName($0))" } ?? "Foreground app unavailable")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption).textSelection(.enabled)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
                .frame(maxHeight: 240)
            }
        }
        .onChange(of: summary.startUs) { _, _ in
            selectedState = nil
            selectedApp = nil
            selectedStretch = nil
            selectedSeconds = nil
            showsIntervals = false
        }
    }

    private func color(_ state: MeasuredInputState) -> Color {
        switch state {
        case .inputActive: return .accentColor
        case .inputIdle: return .orange
        case .unknown: return .secondary
        }
    }

    private func time(_ timestamp: UInt64) -> String {
        Date(timeIntervalSince1970: Double(timestamp) / 1_000_000).formatted(date: .omitted, time: .standard)
    }

    private func duration(_ microseconds: UInt64) -> String {
        let seconds = microseconds / 1_000_000
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}
