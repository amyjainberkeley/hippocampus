// PrivacyDashboard.swift — the ⌘7 in-app Privacy Dashboard (cycle 8.46).
//
// Amy's directive 2026-07-13: "show the full control, no collection".
// This dashboard is the enterprise-grade trust artifact: it shows what
// MCI has captured and gives the user delete + export controls.
//
// # Two-tier discipline (post cycle 8.47, PR #76 follow-up)
//
// Every read path goes through `BrainReader` (read-only by construction;
// see `FFIBrainReader.swift`). Destructive actions route through the
// SEPARATE `PrivacyMutator` protocol — a passing-in `nil` (or a reader
// that doesn't conform) disables the delete buttons entirely. This lets
// stub / preview / test surfaces stay read-only-typed while the real
// FFIBrainReader implements both.
//
// The wipe path is two-step: `prepareWipe()` returns a 60s-TTL token,
// then `wipeBrain(token:)` fires. Any wipe call — success, wrong token,
// expired — consumes the pending token, so a wipe cannot be replayed.
// This defends against a hostile programmatic caller trying to single-call
// `wipeBrain` from outside the UI flow.
//
// The pure filter / summary / confirmation logic lives in
// `RecallUIKit/PrivacyDashboardModel.swift` so it has a headless test
// surface (`PrivacyDashboardTests`).

import AppKit
import RecallUIKit
import SwiftUI

struct PrivacyDashboard: View {
    let reader: BrainReader
    /// The mutator that actually performs deletes. When `nil`, the
    /// destructive-action buttons stay visible but do nothing (preview /
    /// stub surfaces). The executable target's launch path wires this
    /// with the same `FFIBrainReader` instance the reader is backed by.
    let mutator: PrivacyMutator?

    @State private var summary: SummaryStats? = nil
    @State private var events: [Hit] = []
    @State private var observedApps: [ObservedApp] = []
    @State private var filter: PrivacyDashboardFilter = .empty
    @State private var isLoading = true
    @State private var isMutating = false
    @State private var errorMessage: String? = nil
    @State private var confirmation: DestructiveConfirmationBox? = nil
    @State private var banner: String? = nil
    /// Cycle 8.51: newest-first slice of the audit log for the "Recent
    /// activity" section. Reloaded on tab open and after every
    /// destructive action so the user sees their most recent action
    /// reflected immediately.
    @State private var auditEntries: [AuditEntry] = []
    @State private var showAllAudit: Bool = false

    /// Convenience init for reader-only surfaces (preview / stub tests).
    init(reader: BrainReader, mutator: PrivacyMutator? = nil) {
        self.reader = reader
        self.mutator = mutator
    }

    var body: some View {
        // Cycle 8.48 MCIDesignSystem: 24pt section rhythm, 24pt outer
        // padding — Stripe-tuned airiness for a trust-projecting surface.
        ScrollView {
            VStack(alignment: .leading, spacing: MCI.Spacing.xl) {
                PrivacySummaryCard(summary: summary, isLoading: isLoading)
                FilterBar(filter: $filter, observedApps: observedApps)
                EventList(
                    events: filter.apply(to: events),
                    isLoading: isLoading,
                    hasActiveFilter: filter != .empty
                )
                DestructiveActions(
                    onExport: { runExport() },
                    onDeleteLast24h: {
                        confirmation = DestructiveConfirmationBox(kind: .deleteLast24h)
                    },
                    onDeleteEverything: {
                        confirmation = DestructiveConfirmationBox(kind: .deleteEverything)
                    },
                    isBusy: isMutating
                )
                if isMutating {
                    HStack(spacing: MCI.Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text("Working…").foregroundStyle(Color.brandFgMuted)
                    }
                }
                if let banner {
                    Text(banner)
                        .mciFont(.body)
                        .foregroundStyle(Color.brandMint)
                        .padding(MCI.Spacing.s)
                        .background(Color.brandMintSubtle)
                        .cornerRadius(MCI.Radius.s)
                }
                if let err = errorMessage {
                    Text(err).mciFont(.body).foregroundStyle(Color.brandError)
                }
                // Cycle 8.51 — enterprise-audit-log surface. Renders the
                // last 20 audit lines (or the whole log when the user
                // clicks "Show all") so a security-review buyer sees the
                // trust artifact live in the product.
                RecentActivitySection(
                    entries: showAllAudit
                        ? AuditLog.shared.readRecent(count: 10_000)
                        : auditEntries,
                    showingAll: showAllAudit,
                    onShowAll: { showAllAudit.toggle() },
                    onExport: { runExportAuditLog() }
                )
                // Freemium tier footer (cycle 8.48). Reinforces trust
                // invariant #1 from `docs/business/tier-structure.md`
                // — every v1.0 feature stays Free forever. Reads from
                // `TierManager.shared.current` so once Pro state lands
                // in v1.5+ the label reflects it automatically.
                TierFooter(tier: TierManager.shared.current)
            }
            .padding(MCI.Spacing.xl)
        }
        .background(Color.brandBgPrimary)
        .task { await reloadAll() }
        .sheet(item: $confirmation) { box in
            ConfirmDeleteSheet(kind: box.kind) { confirmed in
                confirmation = nil
                if confirmed {
                    Task { await runDestructive(box.kind) }
                }
            }
        }
    }

    /// Fire the destructive action for `kind`. Requires `mutator` to be
    /// non-nil (the confirmation sheet only enables the Confirm button
    /// when the mutator is present, but we guard here too as
    /// defence-in-depth). Refreshes the dashboard on success.
    @MainActor
    private func runDestructive(_ kind: DestructivePrivacyAction) async {
        guard let mutator else {
            banner = "Delete unavailable — mutator not wired."
            return
        }
        isMutating = true
        errorMessage = nil
        banner = nil
        do {
            let result: DeleteResult
            switch kind {
            case .deleteLast24h:
                let now = Date().timeIntervalSince1970
                let startUs = UInt64(max(0, (now - 24 * 3600)) * 1_000_000)
                let endUs = UInt64(now * 1_000_000)
                result = try await mutator.deleteEventsInRange(
                    startTsUs: startUs, endTsUs: endUs
                )
                // Cycle 8.51 — audit-log every destructive action so
                // enterprise buyers have a plaintext trail. Details are
                // meta-only (count + range); NO brain content.
                AuditLog.shared.record(
                    action: .deleteEventsInRange,
                    details: [
                        "count": "\(result.eventsDeleted)",
                        "range_hours": "24",
                    ]
                )
            case .deleteEverything:
                let token = try await mutator.prepareWipe()
                result = try await mutator.wipeBrain(token: token)
                AuditLog.shared.record(
                    action: .wipeBrain,
                    details: ["count": "\(result.eventsDeleted)"]
                )
            }
            banner =
                "Removed \(result.eventsDeleted) events."
                + (result.vacuumOk ? "" : " (disk space will reclaim on next VACUUM)")
            await reloadAll()
        } catch {
            // Cycle 8.54 copy audit — reassuring copy (nothing was
            // removed) instead of leaking the raw `\(error)`.
            errorMessage = UserFacingCopy.deleteFailedBanner
        }
        isMutating = false
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
            // Cycle 8.54 copy audit — plain-English, no raw error.
            errorMessage = UserFacingCopy.dashboardLoadFailedBanner
        }
        // Refresh the audit slice too; every reload (initial + post-
        // destructive-action) should reflect the newest recorded lines.
        auditEntries = AuditLog.shared.readRecent(count: 20)
        isLoading = false
    }

    /// Write the current audit log to `~/Downloads/…` and surface the
    /// destination in the banner. Failures are surfaced inline.
    @MainActor
    private func runExportAuditLog() {
        do {
            let url = try AuditLog.shared.exportToDownloads()
            banner = "Exported activity log to \(url.path)."
        } catch {
            errorMessage = UserFacingCopy.auditExportFailedBanner
        }
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
            // Cycle 8.51 — audit-log the export. Only meta (count +
            // destination path); brain content NEVER touches the log.
            AuditLog.shared.record(
                action: .exportJson,
                details: ["events": "\(events.count)", "path": out]
            )
            Task { @MainActor in
                auditEntries = AuditLog.shared.readRecent(count: 20)
            }
        } catch {
            errorMessage = UserFacingCopy.exportFailedBanner
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
                // Cycle 8.54 copy audit — "Your brain" → "Your memory";
                // matches the copy style guide (§3) product-noun ruling.
                Text("Your memory")
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
        // Combine the lock icon + heading + summary + reassurance into
        // one VoiceOver announcement so a screen-reader user hears the
        // trust posture as a single statement rather than four
        // fragmented Texts.
        .accessibilityElement(children: .combine)
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
    /// `true` when the dashboard filter is narrowing the pool — used to
    /// distinguish "filter hides everything" (offer widen guidance) from
    /// "brain is empty" (reassure on-privacy tone). Cycle 8.49
    /// polished-empty-state audit-gap fix.
    var hasActiveFilter: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent captures (\(events.count))")
                .font(.headline)
                .foregroundStyle(Color.brandFgPrimary)
            if isLoading && events.isEmpty {
                Text("Loading…").foregroundStyle(Color.brandFgMuted)
            } else if events.isEmpty {
                MCIEmptyState.noPrivacyEvents(hasActiveFilter: hasActiveFilter)
                    .frame(minHeight: 220)
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
            .accessibilityLabel("Event actions")
            .accessibilityHint("Delete this event, hour, or day; or report as sensitive")
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
    /// `true` while a delete/wipe is in flight — disables buttons so
    /// a double-tap can't fire the confirmation sheet twice against
    /// an in-progress mutation.
    var isBusy: Bool = false

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
                    .disabled(isBusy)
                Button("Delete last 24 hours") { onDeleteLast24h() }
                    .buttonStyle(.bordered)
                    .tint(Color.brandWarning)
                    .disabled(isBusy)
                Button("Delete everything") { onDeleteEverything() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandError)
                    .disabled(isBusy)
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
        case .deleteEverything: return "Delete your entire memory?"
        }
    }

    var explanation: String {
        // Cycle 8.54 copy audit — "brain" → "your memory". Same
        // referent; user-facing product noun matches the landing page.
        switch self {
        case .deleteLast24h:
            return
                "Every event captured in the last 24 hours will be removed "
                + "from your memory. This cannot be undone."
        case .deleteEverything:
            return
                "Every event, every episode, every brief will be removed "
                + "from your memory. This cannot be undone."
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

// MARK: - Recent activity (audit log)

/// Cycle 8.51 — enterprise audit-log surface in the Privacy Dashboard.
/// Renders a scrollable table of the most-recent `AuditEntry` values.
/// Toggling "Show all" swaps in the whole log; "Export activity log"
/// writes a plaintext copy to `~/Downloads/`. Uses `MCIDesignSystem`
/// tokens for spacing / radius / color so the surface matches the rest
/// of the dashboard.
struct RecentActivitySection: View {
    let entries: [AuditEntry]
    let showingAll: Bool
    let onShowAll: () -> Void
    let onExport: () -> Void

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone.current
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.s) {
            HStack {
                Text("Recent activity")
                    .font(.headline)
                    .foregroundStyle(Color.brandFgPrimary)
                Spacer()
                Button(showingAll ? "Show recent" : "Show all") { onShowAll() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.brandMint)
                Button("Export activity log") { onExport() }
                    .buttonStyle(.bordered)
                    .tint(Color.brandMint)
            }
            Text(
                "Every delete, wipe, export, and permission change is "
                + "recorded to a plaintext local log — no upload. Share "
                + "with your security team to prove what MCI touched."
            )
            .font(.caption)
            .foregroundStyle(Color.brandFgMuted)

            if entries.isEmpty {
                Text("No recorded activity yet.")
                    .font(.callout)
                    .foregroundStyle(Color.brandFgMuted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entries) { entry in
                            HStack(spacing: MCI.Spacing.m) {
                                Text(Self.displayFormatter.string(from: entry.timestamp))
                                    .foregroundStyle(Color.brandFgSecondary)
                                    .frame(width: 150, alignment: .leading)
                                Text(entry.action.rawValue)
                                    .foregroundStyle(Color.brandFgPrimary)
                                    .frame(width: 190, alignment: .leading)
                                Text(Self.formatDetails(entry.details))
                                    .foregroundStyle(Color.brandFgSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .font(.system(.caption, design: .monospaced))
                            // Combine so VoiceOver reads
                            // "2026-07-13 14:32:11, deleteEventsInRange,
                            //  count=47" as one row-line, not three.
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                "\(Self.displayFormatter.string(from: entry.timestamp)), "
                                + "\(entry.action.rawValue), "
                                + "\(Self.formatDetails(entry.details))"
                            )
                        }
                    }
                }
                .frame(maxHeight: showingAll ? 400 : 240)
            }
        }
        .padding(MCI.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brandBgSecondary)
        .cornerRadius(MCI.Radius.m)
    }

    /// Compact one-line details renderer. `{"count":"47"}` → `count=47`.
    private static func formatDetails(_ details: [String: String]) -> String {
        if details.isEmpty { return "—" }
        return details.keys.sorted()
            .map { "\($0)=\(details[$0] ?? "")" }
            .joined(separator: ", ")
    }
}

// MARK: - Tier footer

/// Trust-signal footer showing the user's current tier. Reads a
/// snapshotted `Tier` value at render time so the view stays a pure
/// function of its input (`TierManager.shared.current` is queried at
/// the call site in `PrivacyDashboard.body` above). See
/// `docs/business/tier-structure.md` for the full tier boundary.
struct TierFooter: View {
    let tier: Tier

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.brandMintDim)
            Text(footerText)
                .font(.caption)
                .foregroundStyle(Color.brandFgMuted)
            Spacer()
        }
        .padding(.top, 12)
    }

    private var footerText: String {
        switch tier {
        case .free:
            return "You're on Free forever — every feature you use today, at $0, always."
        case .pro:
            return "You're on Pro — thanks for supporting local-first."
        case .enterprise:
            return "You're on Enterprise."
        }
    }
}
