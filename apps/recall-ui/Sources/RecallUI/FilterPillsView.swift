import RecallUIKit
import SwiftUI

/// Filter pills strip rendered above the search results list.
///
/// Two horizontal rows:
///   1. Date-range pills — Today / Yesterday / Last 7 days / Custom…
///      The "Custom…" pill opens a calendar popover with two date pickers.
///   2. Per-app pills — top 5 observed apps as pills + "More apps…"
///      overflow with the remainder of `observedApps`, plus the
///      single boolean "Has URL" pill on the right.
///
/// The view is content-free: it never sees OCR text or window titles —
/// it only renders the FilterState model and the observedApps roster.
struct FilterPillsView: View {
    @Binding var filters: FilterState
    let observedApps: [ObservedApp]
    let onChanged: () -> Void

    /// Number of app bundle ids shown inline as pills before overflow.
    private static let inlineAppLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            dateRangeRow
            appAndPredicateRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Date range row

    private var dateRangeRow: some View {
        HStack(spacing: 6) {
            ForEach(DateRangePreset.presetPills, id: \.self) { preset in
                dateRangePill(preset)
            }
            customDateRangePill
            Spacer()
        }
    }

    private func dateRangePill(_ preset: DateRangePreset) -> some View {
        let active = filters.dateRange == preset
        return Button {
            filters.setDateRange(active ? .none : preset)
            onChanged()
        } label: {
            pillLabel(preset.label, active: active)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filter.dateRange.\(preset.label)")
    }

    @State private var showCustomRange = false
    @State private var customFrom: Date = Calendar.current.startOfDay(for: Date())
    @State private var customTo: Date = Date()

    private var customDateRangePill: some View {
        let isCustom: Bool = {
            if case .custom = filters.dateRange { return true }
            return false
        }()
        return Button {
            if isCustom {
                filters.setDateRange(.none)
                onChanged()
            } else {
                showCustomRange.toggle()
            }
        } label: {
            pillLabel(isCustom ? customRangeLabel : "Custom…", active: isCustom)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filter.dateRange.custom")
        .popover(isPresented: $showCustomRange) {
            customRangePopover
                .padding(16)
                .frame(minWidth: 320)
        }
    }

    private var customRangeLabel: String {
        guard case .custom(let from, let to) = filters.dateRange else { return "Custom…" }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return "\(df.string(from: from)) – \(df.string(from: to))"
    }

    private var customRangePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom date range")
                .font(.headline)
                .foregroundStyle(Color.brandFgPrimary)
            DatePicker(
                "From",
                selection: $customFrom,
                in: ...customTo,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            DatePicker(
                "To",
                selection: $customTo,
                in: customFrom...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            HStack {
                Button("Cancel") {
                    showCustomRange = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.brandFgSecondary)
                Spacer()
                Button("Apply") {
                    filters.setDateRange(.custom(from: customFrom, to: customTo))
                    showCustomRange = false
                    onChanged()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brandMint)
            }
        }
    }

    // MARK: - Per-app row + Has URL

    private var appAndPredicateRow: some View {
        HStack(spacing: 6) {
            ForEach(inlineApps) { app in
                appPill(app)
            }
            if !overflowApps.isEmpty {
                overflowAppsMenu
            }
            // Always-active selected apps that aren't in top-N still
            // render as pills so the user sees their selection.
            ForEach(extraSelectedApps, id: \.self) { id in
                appPill(ObservedApp(appBundleId: id, count: 0))
            }
            Spacer(minLength: 8)
            hasUrlPill
        }
    }

    /// Top-N observed apps, capped at `inlineAppLimit`.
    private var inlineApps: [ObservedApp] {
        Array(observedApps.prefix(Self.inlineAppLimit))
    }

    /// Apps beyond the inline cap — surfaced via the overflow menu.
    private var overflowApps: [ObservedApp] {
        Array(observedApps.dropFirst(Self.inlineAppLimit))
    }

    /// Bundle ids the user picked that didn't show up in
    /// `observedApps` (e.g. they were selected before the brain finished
    /// counting, or the count rolled off the top-N window). Render them
    /// as pills so toggling them off stays reachable.
    private var extraSelectedApps: [String] {
        let known = Set(observedApps.map(\.appBundleId))
        return filters.appBundleIds.subtracting(known).sorted()
    }

    private func appPill(_ app: ObservedApp) -> some View {
        let active = filters.appBundleIds.contains(app.appBundleId)
        return Button {
            filters.toggleApp(app.appBundleId)
            onChanged()
        } label: {
            HStack(spacing: 4) {
                Text(displayName(for: app.appBundleId))
                if app.count > 0 {
                    Text("\(app.count)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.brandFgMuted)
                }
            }
            .font(.system(.caption, design: .default))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(active ? Color.brandMintSubtle : Color.brandBgElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        active ? Color.brandMint : Color.brandCardBorder,
                        lineWidth: 0.5
                    )
            )
            .foregroundStyle(active ? Color.brandMint : Color.brandFgSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filter.app.\(app.appBundleId)")
    }

    private var overflowAppsMenu: some View {
        Menu {
            ForEach(overflowApps) { app in
                Button {
                    filters.toggleApp(app.appBundleId)
                    onChanged()
                } label: {
                    HStack {
                        if filters.appBundleIds.contains(app.appBundleId) {
                            Image(systemName: "checkmark")
                        }
                        Text(displayName(for: app.appBundleId))
                        Spacer()
                        Text("\(app.count)").foregroundStyle(Color.brandFgMuted)
                    }
                }
            }
        } label: {
            pillLabel("More apps… (\(overflowApps.count))", active: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("filter.app.overflow")
    }

    private var hasUrlPill: some View {
        Button {
            filters.toggleHasUrl()
            onChanged()
        } label: {
            pillLabel("Has URL", active: filters.hasUrl)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filter.hasUrl")
    }

    // MARK: - Shared

    private func pillLabel(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(.caption, design: .default))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(active ? Color.brandMintSubtle : Color.brandBgElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        active ? Color.brandMint : Color.brandCardBorder,
                        lineWidth: 0.5
                    )
            )
            .foregroundStyle(active ? Color.brandMint : Color.brandFgSecondary)
    }

    /// Strip a known `com.apple.X` / `com.microsoft.X` prefix so pills
    /// stay readable. Falls back to the raw bundle id.
    private func displayName(for bundleId: String) -> String {
        if let last = bundleId.split(separator: ".").last, !last.isEmpty {
            return String(last)
        }
        return bundleId
    }
}
