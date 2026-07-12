import SwiftUI
import OnboardingKit

/// Pre-flight overview of the four TCC surfaces the user will encounter
/// during onboarding. Rendered at the top of `PermissionsSlide` so the
/// user sees ALL upcoming asks *before* the first OS dialog fires.
///
/// Fixes the "Rewind bad pattern" (audit gap G1): previously the user
/// hit surprise Automation TCC on the Browser Extension slide + surprise
/// FDA on Allowlist after Permissions told them permissions were done.
///
/// No mutation buttons here. This slide *previews*; grants happen in
/// the per-permission sections below it and in the later slides.
struct TCCPreflightOverview: View {
    let screenRecordingStatus: TCCStatus
    let accessibilityStatus: TCCStatus
    let automationStatus: TCCStatus
    let fullDiskAccessStatus: FullDiskAccessStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("You'll be asked for 4 macOS permissions")
                    .font(.system(size: 14, weight: .semibold))
                Text("Everything Hippocampus captures stays on your Mac. Here's what each permission does and where you'll see the system dialog.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            rows
        }
        .padding(14)
        .background(OnboardingTheme.accentBlue.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 520)
    }

    @ViewBuilder
    private var rows: some View {
        row(icon: "rectangle.inset.filled.and.person.filled",
            name: "Screen Recording · Required",
            rationale: "Sees what's on your screen so we can search it later. All processing stays on your Mac.",
            pill: Pill.from(screenRecordingStatus))
        row(icon: "accessibility",
            name: "Accessibility · Recommended",
            rationale: "Detects password fields so we know NOT to capture them.",
            pill: Pill.from(accessibilityStatus))
        row(icon: "applescript",
            name: "Automation (Safari) · If applicable",
            rationale: "Only if you use Safari — lets us open Settings → Extensions with one click. Fires on the Browser step.",
            pill: Pill.from(automationStatus))
        row(icon: "externaldrive",
            name: "Full Disk Access · If applicable",
            rationale: "Only if you opt into Messages / Mail deep-hooks. Fires when you toggle one on the Allowlist step.",
            pill: Pill.from(fullDiskAccessStatus))
    }

    private func row(icon: String, name: String, rationale: String, pill: Pill) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(OnboardingTheme.accentBlue)
                .font(.system(size: 14))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 12, weight: .semibold))
                Text(rationale)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Text(pill.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(pill.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(pill.color.opacity(0.12), in: Capsule())
        }
    }

    enum Pill {
        case notRequested, requested, granted, denied
        var label: String {
            switch self {
            case .notRequested: "Not requested"
            case .requested: "Requested"
            case .granted: "Granted"
            case .denied: "Denied"
            }
        }
        var color: Color {
            switch self {
            case .granted: .green
            case .denied: .red
            case .notRequested, .requested: .secondary
            }
        }
        static func from(_ s: TCCStatus) -> Pill {
            switch s {
            case .granted: .granted
            case .denied: .denied
            case .notRequested: .notRequested
            }
        }
        static func from(_ s: FullDiskAccessStatus) -> Pill {
            switch s {
            case .granted: .granted
            case .declined: .denied
            case .requested: .requested
            case .notRequested: .notRequested
            }
        }
    }
}
