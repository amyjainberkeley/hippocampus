// PrivacyDashboard.swift — the Privacy page (SPEC 3.9): what is kept on
// this Mac, for how long, what the side pictures use, forgetting it, and
// what was forgotten or exported.
//
// Every read path goes through `BrainReader` (read-only by construction;
// see `FFIBrainReader.swift`). Destructive actions route through the
// SEPARATE `PrivacyMutator` protocol, or, for forgetting, through the
// shell's forget coordinator (`EnvironmentValues.forget`), which holds
// remembering while it deletes (SPEC 3.11). A `nil` mutator with no
// coordinator says the action is unavailable instead of failing.
//
// The wipe path is two-step: `prepareWipe()` returns a 60s-TTL token,
// then `wipeBrain(token:)` fires. Any wipe call — success, wrong token,
// expired — consumes the pending token, so a wipe cannot be replayed.
//
// The pure summary, usage, activity and confirmation logic lives in
// `RecallUIKit/PrivacyDashboardModel.swift` (`PrivacyDashboardTests`).

import AppKit
import RecallUIKit
import SwiftUI

struct PrivacyDashboard: View {
    let reader: BrainReader
    /// The mutator that actually performs deletes. When `nil`, forgetting
    /// goes through the shell's coordinator, and without one the page says
    /// it is unavailable (preview / stub surfaces).
    let mutator: PrivacyMutator?
    /// How long moments are kept, and what the side pictures use. Read from
    /// the files Preferences and the agent write; renders pass fixtures.
    var retention: @Sendable () -> RetentionSetting? = { RetentionSetting.read(from: RetentionSetting.defaultURL) }
    var picturesUsage: @Sendable () -> PicturesUsage? = { PicturesUsage.read() }
    /// The audit log's newest lines; renders pass fixtures.
    var activity: @Sendable () -> [AuditEntry] = { AuditLog.shared.readRecent(count: 50) }
    /// Delete Everything through the app, which stops remembering and
    /// erases the memory and its key (storage-security review S3). Nil for
    /// a window opened by hand: it deletes every row instead.
    var erase: (@Sendable () async -> Bool)? = nil
    var now: @Sendable () -> Date = { Date() }
    var calendar: Calendar = .current

    @Environment(\.forget) private var forget
    @Environment(\.locale) private var locale
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview

    @State private var summary: SummaryStats? = nil
    @State private var kept: RetentionSetting?
    @State private var pictures: PicturesUsage?
    @State private var entries: [AuditEntry] = []
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var errorMessage: String? = nil
    @State private var confirmation: DestructiveConfirmationBox? = nil
    @State private var banner: String? = nil

    /// Convenience init for reader-only surfaces (preview / stub tests).
    init(reader: BrainReader, mutator: PrivacyMutator? = nil, erase: (@Sendable () async -> Bool)? = nil) {
        self.reader = reader
        self.mutator = mutator
        self.erase = erase
    }

    init(reader: BrainReader, mutator: PrivacyMutator?, retention: @escaping @Sendable () -> RetentionSetting?,
         picturesUsage: @escaping @Sendable () -> PicturesUsage?, activity: @escaping @Sendable () -> [AuditEntry],
         now: @escaping @Sendable () -> Date, calendar: Calendar) {
        self.reader = reader
        self.mutator = mutator
        self.retention = retention
        self.picturesUsage = picturesUsage
        self.activity = activity
        self.now = now
        self.calendar = calendar
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                keptCard
                actions
                status
                activityList
            }
            // Where every page starts, as Working On lays out (the
            // prototype's Privacy).
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(MCI.Color.background)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: NavigationCopy.privacy)
                .font(MCI.Font.title)
                .foregroundStyle(MCI.Color.foreground)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: LibraryCopy.Privacy.lead)
                .font(.system(size: 13))
                .foregroundStyle(MCI.Color.foregroundSecondary)
        }
    }

    // MARK: What is kept

    private var keptCard: some View {
        OverviewCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                KeptRow(text: PrivacyKept.line(summary, locale: locale)
                    ?? (isLoading ? UserFacingCopy.Overview.loading : PrivacyDashboardSummary.line(summary: nil)))
                if let kept {
                    Divider()
                    KeptRow(text: kept.days.map { LibraryCopy.Privacy.keptFor(days: $0) }
                        ?? LibraryCopy.Privacy.keptUntilForgotten) {
                        openPreferences(.privacy)
                    }
                }
                if let line = pictures?.line {
                    Divider()
                    KeptRow(text: line) { openPreferences(.capture) }
                }
            }
        }
    }

    // MARK: Forgetting

    /// The forget and delete buttons' red, readable on the bordered button's
    /// own fill in light and dark (`PrivacyButtonRed`): in dark mode that
    /// fill is a mid grey the window's error red is too dark for.
    private static let destructive = MCI.Color.hex(light: PrivacyButtonRed.light, dark: PrivacyButtonRed.dark)

    private var actions: some View {
        let busy = isMutating || isSyntheticPreview
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let forget {
                    Button { forget(.recent) } label: {
                        Text(verbatim: LibraryCopy.Privacy.forgetRecent).foregroundStyle(Self.destructive)
                    }
                    .disabled(busy)
                }
                Button { confirmation = DestructiveConfirmationBox(kind: .forgetLast24h) } label: {
                    Text(verbatim: LibraryCopy.Privacy.forgetLast24Hours).foregroundStyle(Self.destructive)
                }
                .disabled(busy)
                Button(LibraryCopy.Privacy.exportEverything) { runExport() }
                    .help(LibraryCopy.Privacy.exportHelp)
                    .disabled(busy)
            }
            Button { confirmation = DestructiveConfirmationBox(kind: .deleteEverything) } label: {
                Text(verbatim: LibraryCopy.Privacy.deleteEverything).foregroundStyle(Self.destructive)
            }
            .disabled(busy)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var status: some View {
        if isMutating {
            HStack(spacing: MCI.Spacing.s) {
                ProgressView().controlSize(.small)
                Text(verbatim: LibraryCopy.Privacy.working).foregroundStyle(MCI.Color.foregroundSecondary)
            }
        }
        if let banner {
            Text(banner)
                .font(MCI.Font.body)
                .foregroundStyle(MCI.Color.foreground)
        }
        if let errorMessage {
            Text(errorMessage)
                .font(MCI.Font.body)
                .foregroundStyle(MCI.Color.error)
        }
    }

    // MARK: Activity

    private var activityList: some View {
        let rows = PrivacyActivity.rows(entries, now: now(), calendar: calendar, locale: locale)
        return VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: LibraryCopy.Privacy.activity)
                .font(MCI.Font.title2)
                .foregroundStyle(MCI.Color.foreground)
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text(verbatim: LibraryCopy.Privacy.activityEmpty)
                    .font(.system(size: 14))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    ForEach(rows.prefix(20)) { row in
                        GridRow {
                            Text(verbatim: row.when)
                                .foregroundStyle(MCI.Color.foregroundSecondary)
                                .monospacedDigit()
                            Text(verbatim: row.what)
                                .foregroundStyle(MCI.Color.foreground)
                        }
                        .font(.system(size: 14))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: Doing it

    private func openPreferences(_ destination: WorkspacePreferencesDestination) {
        guard !isSyntheticPreview else { return }
        Task { _ = await WorkspacePreferencesRouter.shared.open(destination, bundleURL: Bundle.main.bundleURL) }
    }

    /// Forget the last 24 hours, or delete everything, once the typed word
    /// matched. Forgetting goes through the shell's coordinator when there
    /// is one, which holds remembering while it deletes; otherwise through
    /// the mutator, as the wipe always does.
    @MainActor
    private func runDestructive(_ kind: DestructivePrivacyAction) async {
        errorMessage = nil
        banner = nil
        if kind == .forgetLast24h, let forget {
            let endUs = Int64(now().timeIntervalSince1970 * 1_000_000)
            let startUs = max(0, endUs - 24 * 3_600 * 1_000_000)
            forget(.range(startUs...endUs, label: LibraryCopy.Privacy.forgotLastHours(24), confirmed: true))
            return
        }
        if kind == .deleteEverything, let erase {
            // The memory and its key go; the app then opens a fresh window,
            // since this one still has the erased memory open.
            isMutating = true
            defer { isMutating = false }
            if await erase() {
                AuditLog.shared.record(action: .wipeBrain, details: ["key_deleted": "true"])
                banner = UserFacingCopy.erasedEverything
            } else {
                errorMessage = UserFacingCopy.eraseFailedBanner
            }
            return
        }
        guard let mutator else {
            banner = UserFacingCopy.deleteUnavailable
            return
        }
        isMutating = true
        defer { isMutating = false }
        do {
            let result: DeleteResult
            switch kind {
            case .forgetLast24h:
                let current = now().timeIntervalSince1970
                let startUs = UInt64(max(0, current - 24 * 3_600) * 1_000_000)
                let endUs = UInt64(current * 1_000_000)
                result = try await mutator.deleteEventsInRange(startTsUs: startUs, endTsUs: endUs)
                // Every destructive action goes in the audit log, so the
                // person has a plain-text trail. Details are counts and
                // ranges only; NO memory content.
                AuditLog.shared.record(
                    action: .deleteEventsInRange,
                    details: [
                        "count": "\(result.eventsDeleted)",
                        "range_hours": "24",
                        "vacuum_ok": "\(result.vacuumOk)",
                        "blob_cleanup_ok": "\(result.blobCleanupOk)",
                    ]
                )
            case .deleteEverything:
                let token = try await mutator.prepareWipe()
                result = try await mutator.wipeBrain(token: token)
                AuditLog.shared.record(
                    action: .wipeBrain,
                    details: [
                        "count": "\(result.eventsDeleted)",
                        "vacuum_ok": "\(result.vacuumOk)",
                        "blob_cleanup_ok": "\(result.blobCleanupOk)",
                    ]
                )
            }
            banner = DeletionPresentation.successBanner(for: result)
            await reloadAll()
        } catch {
            errorMessage = DeletionPresentation.failureBanner(for: error)
        }
    }

    /// Counts, then the storage measurement (once, on opening the page and
    /// after a change, never on a timer), how long moments are kept, the
    /// side pictures' use and the activity.
    @MainActor
    private func reloadAll() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let retention = retention
        let picturesUsage = picturesUsage
        let activity = activity
        async let files = Task.detached { (retention(), picturesUsage(), activity()) }.value
        do {
            let counts = try await reader.summaryStats()
            summary = counts
            let storage = try? await reader.storageUsage()
            summary = SummaryStats(totalEvents: counts.totalEvents, oldestTsUs: counts.oldestTsUs,
                                   newestTsUs: counts.newestTsUs, diskBytes: counts.diskBytes,
                                   storage: storage ?? counts.storage)
        } catch {
            // Plain English, no raw error.
            errorMessage = UserFacingCopy.dashboardLoadFailedBanner
        }
        let read = await files
        kept = read.0
        pictures = read.1
        entries = read.2
    }

    /// Export Everything (storage-security review S8): a save panel that
    /// says the file isn't encrypted and where it may sync, then every
    /// moment, in full, into a new file only this user can read.
    @MainActor
    private func runExport() {
        let panel = NSSavePanel()
        panel.message = ExportDestination.panelMessage
        panel.nameFieldStringValue = ExportDestination.suggestedName(now: now())
        panel.allowedContentTypes = [.init(filenameExtension: "jsonl") ?? .json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isMutating = true
        Task { @MainActor in
            defer { isMutating = false }
            do {
                let count = try await MemoryExport.run(to: url)
                banner = [UserFacingCopy.exportedMoments(count), ExportDestination.warning(for: url)]
                    .compactMap { $0 }
                    .joined(separator: " ")
                // Only meta (count + destination path); memory content
                // never touches the log.
                AuditLog.shared.record(action: .exportJson,
                                       details: ["events": "\(count)", "path": url.path])
                entries = activity()
            } catch {
                errorMessage = UserFacingCopy.exportFailedBanner
            }
        }
    }
}

/// One row of what is kept, with [Change…] when it can be changed.
private struct KeptRow: View {
    let text: String
    var change: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: text)
                .font(.system(size: 14))
                .foregroundStyle(MCI.Color.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let change {
                Button(LibraryCopy.change, action: change)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, change == nil ? 14 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// SwiftUI `.sheet(item:)` requires `Identifiable`; wrap the kit's
/// `DestructivePrivacyAction` (pure test surface) with an id.
struct DestructiveConfirmationBox: Identifiable {
    let kind: DestructivePrivacyAction
    var id: String { kind.rawValue }
}

/// The words of the typed-word question; the gate itself is the kit's.
private extension DestructivePrivacyAction {
    var title: String {
        switch self {
        case .forgetLast24h: LibraryCopy.Privacy.forgetLast24Title
        case .deleteEverything: UserFacingCopy.deleteEverythingTitle
        }
    }

    var explanation: String {
        switch self {
        case .forgetLast24h: LibraryCopy.Privacy.forgetLast24Body
        case .deleteEverything: UserFacingCopy.deleteEverythingExplanation
        }
    }

    var action: String {
        switch self {
        case .forgetLast24h: LibraryCopy.Privacy.forget
        case .deleteEverything: UserFacingCopy.deleteAction
        }
    }
}

/// Asks for the typed word before forgetting the last 24 hours or deleting
/// everything. Cancel is the default; Return never forgets.
struct ConfirmDeleteSheet: View {
    let kind: DestructivePrivacyAction
    let onFinish: (Bool) -> Void

    @State private var typed: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: kind.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MCI.Color.foreground)
            Text(verbatim: kind.explanation)
                .font(.system(size: 13))
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: LibraryCopy.Privacy.typeToConfirm(kind.requiredPhrase))
                .font(.system(size: 12))
                .foregroundStyle(MCI.Color.foregroundSecondary)
            TextField(kind.requiredPhrase, text: $typed)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(LibraryCopy.Privacy.cancel) { onFinish(false) }
                    .keyboardShortcut(.cancelAction)
                Button(kind.action, role: .destructive) { onFinish(true) }
                    .disabled(!kind.matches(typed))
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(MCI.Color.background)
    }
}
