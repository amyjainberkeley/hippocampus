// PrivacyDashboard.swift — the ⌘7 in-app Privacy Dashboard (cycle 8.46).
//
// Amy's directive 2026-07-13: "show the full control, no collection".
// This dashboard is the enterprise-grade trust artifact: it shows what
// MCI has captured and gives the user delete + export controls.
//
// # Read-only + protected-set discipline
//
// Every read path goes through `BrainReader` (read-only by construction;
// see `FFIBrainReader.swift`). Delete actions ship UI-only in this PR —
// the mutation FFI is deferred to cycle 8.47 (requires ADR + CSO
// sign-off). Confirming a delete surfaces a "Coming soon" banner rather
// than writing to the brain.
//
// The pure filter / summary / confirmation logic lives in
// `RecallUIKit/PrivacyDashboardModel.swift` so it has a headless test
// surface (`PrivacyDashboardTests`).

import AppKit
import RecallUIKit
import SwiftUI

struct PrivacyDashboard: View {
    let reader: BrainReader

    @State private var summary: SummaryStats? = nil
    @State private var events: [Hit] = []
    @State private var observedApps: [ObservedApp] = []
    @State private var filter: PrivacyDashboardFilter = .empty
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var confirmation: DestructiveConfirmationBox? = nil
    @State private var banner: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PrivacySummaryCard(summary: summary, isLoading: isLoading)
                FilterBar(filter: $filter, observedApps: observedApps)
                EventList(events: filter.apply(to: events), isLoading: isLoading)
                DestructiveActions(
                    onExport: { runExport() },
                    onDeleteLast24h: {
                        confirmation = DestructiveConfirmationBox(kind: .deleteLast24h)
                    },
                    onDeleteEverything: {
                        confirmation = DestructiveConfirmationBox(kind: .deleteEverything)
                    }
                )
                if let banner {
                    Text(banner)
                        .font(.callout)
                        .foregroundStyle(Color.brandMint)
                        .padding(8)
                        .background(Color.brandMintSubtle)
                        .cornerRadius(6)
                }
                if let err = errorMessage {
                    Text(err).font(.callout).foregroundStyle(Color.brandError)
                }
            }
            .padding(20)
        }
        .background(Color.brandBgPrimary)
        .task { await reloadAll() }
        .sheet(item: $confirmation) { box in
            ConfirmDeleteSheet(kind: box.kind) { confirmed in
                confirmation = nil
                if confirmed {
                    // Mutation FFI is deferred to cycle 8.47 — see the
                    // file-header note. Surface the intent without writing.
                    banner =
                        "Coming soon (cycle 8.47) — delete requires a "
                        + "protected-set mutation FFI + CSO sign-off."
                }
            }
        }
    }

    @MainActor
    private func reloadAll() async {
        isLoading = true
        errorMessage = nil
        do {
            async let s = reader.summaryStats()
            async let e = reader.recentEvents(limit: 200)
            async let a = reader.listObservedApps(limit: 32, timeFromUs: nil)
            summary = try await s
            events = try await e
            observedApps = try await a
        } catch {
            errorMessage = "Couldn't load dashboard: \(error)"
        }
        isLoading = false
    }

    @MainActor
    private func runExport() {
        let iso = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dl = NSSearchPathForDirectoriesInDomains(
            .downloadsDirectory, .userDomainMask, true
        ).first ?? NSTemporaryDirectory()
        let out = (dl as NSString).appendingPathComponent(
            "hippocampus-export-\(iso).json"
        )
        let payload = ExportPayload(
            generatedAt: iso, summary: summary,
            events: events, observedApps: observedApps
        )
        do {
            let data = try JSONEncoder.pretty.encode(payload)
            try data.write(to: URL(fileURLWithPath: out))
            banner =
                "Exported \(events.count) events to \(out). "
                + "WARNING: unencrypted — move to encrypted storage if sensitive."
        } catch {
            errorMessage = "Export failed: \(error)"
        }
    }
}

// MARK: - Summary card

struct PrivacySummaryCard: View {
    let summary: SummaryStats?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Color.brandMint)
                Text("Your brain")
                    .font(.title2.bold())
                    .foregroundStyle(Color.brandFgPrimary)
                Spacer()
            }
            Text(PrivacyDashboardSummary.line(summary: summary, isLoading: isLoading))
                .font(.body)
                .foregroundStyle(Color.brandFgSecondary)
            Text("All local. End-to-end encrypted. Nothing uploaded.")
                .font(.callout)
                .foregroundStyle(Color.brandMintDim)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brandCardBg)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.brandCardBorder, lineWidth: 1)
        )
        .cornerRadius(8)
    }
}

// MARK: - Filter bar

struct FilterBar: View {
    @Binding var filter: PrivacyDashboardFilter
    let observedApps: [ObservedApp]

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Button("All apps") { filter.appBundleId = nil }
                Divider()
                ForEach(observedApps) { app in
                    Button("\(app.appBundleId) (\(app.count))") {
                        filter.appBundleId = app.appBundleId
                    }
                }
            } label: {
                Label(filter.appBundleId ?? "All apps", systemImage: "app.badge")
                    .font(.callout)
            }
            Menu {
                Button("All time") { filter.sinceHours = nil }
                Button("Last hour") { filter.sinceHours = 1 }
                Button("Last 24 hours") { filter.sinceHours = 24 }
                Button("Last 7 days") { filter.sinceHours = 24 * 7 }
            } label: {
                Label(sinceLabel, systemImage: "clock").font(.callout)
            }
            Spacer()
        }
    }

    private var sinceLabel: String {
        switch filter.sinceHours {
        case .some(1): return "Last hour"
        case .some(24): return "Last 24h"
        case .some(let h) where h == 24 * 7: return "Last 7 days"
        case .some(let h): return "Last \(h)h"
        case .none: return "All time"
        }
    }
}

// MARK: - Event list + row

struct EventList: View {
    let events: [Hit]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent captures (\(events.count))")
                .font(.headline)
                .foregroundStyle(Color.brandFgPrimary)
            if isLoading && events.isEmpty {
                Text("Loading…").foregroundStyle(Color.brandFgMuted)
            } else if events.isEmpty {
                Text("Nothing captured in the current filter.")
                    .foregroundStyle(Color.brandFgMuted)
            } else {
                ForEach(events) { EventRow(hit: $0) }
            }
        }
    }
}

struct EventRow: View {
    let hit: Hit

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "app.dashed")
                .foregroundStyle(Color.brandMintDim)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(hit.appBundleId ?? "(no app)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.brandFgPrimary)
                    Text("·").foregroundStyle(Color.brandFgMuted)
                    Text(Formatters.relativeTime(usSinceEpoch: hit.tsUs))
                        .font(.callout)
                        .foregroundStyle(Color.brandFgMuted)
                }
                Text(Formatters.snippet(
                    Formatters.stripContextHeader(hit.ocrTextSnippet), maxLen: 100
                ))
                .font(.callout)
                .foregroundStyle(Color.brandFgSecondary)
                .lineLimit(2)
            }
            Spacer()
            Menu {
                Button("Delete this event") {}
                Button("Delete this hour") {}
                Button("Delete this day") {}
                Divider()
                Button("Report as sensitive") {}
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Color.brandFgMuted)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(10)
        .background(Color.brandBgSecondary)
        .cornerRadius(6)
    }
}

// MARK: - Destructive actions + confirmation sheet

struct DestructiveActions: View {
    let onExport: () -> Void
    let onDeleteLast24h: () -> Void
    let onDeleteEverything: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your controls")
                .font(.headline)
                .foregroundStyle(Color.brandFgPrimary)
            Text(
                "Exported files are unencrypted. Move them to encrypted "
                + "storage if the contents are sensitive."
            )
            .font(.caption)
            .foregroundStyle(Color.brandWarning)
            HStack(spacing: 10) {
                Button("Export my data as JSON") { onExport() }
                    .buttonStyle(.bordered)
                    .tint(Color.brandMint)
                Button("Delete last 24 hours") { onDeleteLast24h() }
                    .buttonStyle(.bordered)
                    .tint(Color.brandWarning)
                Button("Delete everything") { onDeleteEverything() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandError)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brandBgSecondary)
        .cornerRadius(8)
    }
}

/// SwiftUI `.sheet(item:)` requires `Identifiable`; wrap the kit's
/// `DestructivePrivacyAction` (pure test surface) with an id.
struct DestructiveConfirmationBox: Identifiable {
    let kind: DestructivePrivacyAction
    var id: String { kind.rawValue }
}

/// Display metadata for the confirmation sheet — kept here so the
/// RecallUIKit `DestructivePrivacyAction` stays a pure logic + gate.
private extension DestructivePrivacyAction {
    var title: String {
        switch self {
        case .deleteLast24h: return "Delete the last 24 hours?"
        case .deleteEverything: return "Delete your entire brain?"
        }
    }

    var explanation: String {
        switch self {
        case .deleteLast24h:
            return
                "Every event captured in the last 24 hours will be removed "
                + "from the brain. This cannot be undone."
        case .deleteEverything:
            return
                "Every event, every episode, every brief will be removed "
                + "from the brain. This cannot be undone."
        }
    }
}

struct ConfirmDeleteSheet: View {
    let kind: DestructivePrivacyAction
    let onFinish: (Bool) -> Void

    @State private var typed: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind.title)
                .font(.title3.bold())
                .foregroundStyle(Color.brandFgPrimary)
            Text(kind.explanation).foregroundStyle(Color.brandFgSecondary)
            Text("Type \"\(kind.requiredPhrase)\" to confirm:")
                .font(.callout)
                .foregroundStyle(Color.brandFgMuted)
            TextField(kind.requiredPhrase, text: $typed)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { onFinish(false) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Confirm") { onFinish(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandError)
                    .disabled(!kind.matches(typed))
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Color.brandBgPrimary)
    }
}

// MARK: - Export payload

struct ExportPayload: Encodable {
    let generatedAt: String
    let summary: SummaryStats?
    let events: [Hit]
    let observedApps: [ObservedApp]
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
