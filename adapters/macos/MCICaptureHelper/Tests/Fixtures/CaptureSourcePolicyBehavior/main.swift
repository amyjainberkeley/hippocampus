import CoreGraphics
import Foundation
import MCICaptureHelperKit

private struct FixedFocusedWindowReader: FocusedWindowReader {
    let focused: FocusedWindow?

    func readFocusedWindow() -> FocusedWindow? { focused }
}

private final class SequencedRectReader: AXFocusedWindowRectReader, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CGRect]

    init(_ values: [CGRect]) {
        self.values = values
    }

    func readRect(pid _: pid_t, timeoutMs _: Int) -> CGRect? {
        lock.withLock {
            guard !values.isEmpty else { return nil }
            return values.removeFirst()
        }
    }
}

private struct StablePidSource: FrontmostPidSource {
    func frontmostPidAndBundle() -> (pid_t, String)? {
        (pid_t(41), "com.example.Editor")
    }
}

private struct RectMappedWindowSource: FocusedWindowIDSource {
    let firstRect: CGRect

    func focusedWindowID(pid _: pid_t, axFocusedRect: CGRect) -> CGWindowID? {
        axFocusedRect == firstRect ? 101 : 202
    }
}

private struct SecureInput: SecureEventInputProbe {
    func isSecureEventInputEnabled() -> Bool { false }
}

private struct NonSecureAX: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { false }
}

private struct NoDenylist: DenylistProbe {
    func appIsDenied(bundleId _: String) -> Bool { false }
    func urlIsDenied(_: String) -> Bool { false }
    func windowTitleIsDenied(_: String) -> Bool { false }
}

private struct NoBlackRegion: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}

@main
struct CaptureSourcePolicyBehavior {
    static func main() async {
        #if DEBUG
        let qualificationArguments = [
            "mci-capture-helper",
            "--capture",
            LiveOCRQualification.flag,
        ]
        let qualificationEnvironment = [
            "MCI_DEVELOPMENT_FILE_KEY": "1",
            "MCI_OCR_TRACE": "1",
        ]
        precondition(LiveOCRQualification.isAuthorized(
            arguments: qualificationArguments,
            environment: qualificationEnvironment
        ))
        for omittedArgument in qualificationArguments.dropFirst() {
            precondition(!LiveOCRQualification.isAuthorized(
                arguments: qualificationArguments.filter { $0 != omittedArgument },
                environment: qualificationEnvironment
            ))
        }
        for omittedVariable in qualificationEnvironment.keys {
            precondition(!LiveOCRQualification.isAuthorized(
                arguments: qualificationArguments,
                environment: qualificationEnvironment.filter { $0.key != omittedVariable }
            ))
        }
        #endif

        let focusedRect = CGRect(x: 120, y: 80, width: 900, height: 700)
        let focusedCandidates = [
            CGWindowIdentityCandidate(
                windowId: 10,
                bounds: CGRect(x: 0, y: 0, width: 1400, height: 900)
            ),
            CGWindowIdentityCandidate(windowId: 11, bounds: focusedRect),
        ]
        precondition(
            FocusedWindowIdentityPolicy.selectWindowID(
                axFocusedRect: focusedRect,
                frontToBackCandidates: focusedCandidates
            ) == 11,
            "capture identity must match the AX-focused window geometry, not the first app window"
        )
        precondition(
            FocusedWindowIdentityPolicy.selectWindowID(
                axFocusedRect: focusedRect,
                frontToBackCandidates: [focusedCandidates[0]]
            ) == nil,
            "capture must fail closed when WindowServer cannot match the AX-focused window"
        )
        precondition(
            FocusedWindowIdentityPolicy.selectWindowID(
                axFocusedRect: focusedRect,
                frontToBackCandidates: [
                    focusedCandidates[1],
                    CGWindowIdentityCandidate(windowId: 12, bounds: focusedRect),
                ]
            ) == nil,
            "capture must fail closed when multiple WindowServer surfaces match AX geometry"
        )

        let switchedRect = CGRect(x: 180, y: 100, width: 900, height: 700)
        let racingReader = AXFocusedWindowReader(
            pidSource: StablePidSource(),
            axRectReader: SequencedRectReader([focusedRect, switchedRect]),
            windowIdSource: RectMappedWindowSource(firstRect: focusedRect)
        )
        precondition(
            racingReader.readFocusedWindowIdentity() == nil,
            "a same-application focused-window switch must fail closed during identity confirmation"
        )

        let privateIdentifier = "customer-secret-field"
        let privateTitle = "Meridian renewal password"
        let diagnostic = AXProbeDiagnostic.render(AXProbeObservation(
            focusResult: .success,
            role: "AXTextField",
            subrole: "AXSecureTextField",
            identifier: privateIdentifier,
            title: privateTitle,
            descendantSecure: .positive,
            valueAttributeHidden: .negative,
            identifierRegexMatch: .positive,
            classification: true
        ))
        precondition(!diagnostic.contains(privateIdentifier))
        precondition(!diagnostic.contains(privateTitle))
        precondition(diagnostic.contains("role=present"))
        precondition(diagnostic.contains("title=present"))

        let cascade = SuppressionCascade(
            secureEventInput: SecureInput(),
            axSecureSubrole: NonSecureAX(),
            denylist: NoDenylist(),
            blackedRegion: NoBlackRegion(),
            knownSafeAppBundles: ["com.apple.Safari", "com.apple.Terminal"],
            rawPixelExcludedAppBundles: BrowserPixelCapturePolicy.excludedBundleIds
        )

        precondition(
            cascade.decide(context: WorkflowContext(appBundleId: "com.apple.Safari"))
                == .suppress(reason: .failsafeUnknown)
        )
        precondition(
            cascade.decide(context: WorkflowContext(appBundleId: "com.apple.Terminal"))
                == .allow
        )

        precondition(
            OCRDispatchPolicy.shouldSubmit(
                outcome: .encoded(seq: 1, forcedByFloor: false),
                hasInput: true
            ),
            "a changed, cascade-cleared frame with pixels must reach OCR"
        )
        precondition(
            !OCRDispatchPolicy.shouldSubmit(
                outcome: .encoded(seq: 2, forcedByFloor: true),
                hasInput: true
            ),
            "a floor-only privacy probe must never turn an idle frame into OCR"
        )
        precondition(
            !OCRDispatchPolicy.shouldSubmit(outcome: .filteredOut, hasInput: true),
            "a filtered frame must not reach OCR"
        )
        precondition(
            !OCRDispatchPolicy.shouldSubmit(
                outcome: .encoded(seq: 3, forcedByFloor: false),
                hasInput: false
            ),
            "an allowed frame without pixels must not reach OCR"
        )
        precondition(
            CaptureBaselinePolicy.shouldCommit(
                outcome: .encoded(seq: 4, forcedByFloor: false)
            ),
            "a changed, cascade-cleared frame may become the visual baseline"
        )
        precondition(
            !CaptureBaselinePolicy.shouldCommit(
                outcome: .encoded(seq: 5, forcedByFloor: true)
            ),
            "a floor-only frame must not seed the visual baseline"
        )
        precondition(
            !CaptureBaselinePolicy.shouldCommit(
                outcome: .suppressed(reason: .secureEventInput, forcedByFloor: false)
            ),
            "a privacy-suppressed frame must not seed the visual baseline"
        )
        precondition(
            CaptureBaselinePolicy.shouldRevokeForRetry(
                currentGeneration: 7,
                currentCaptureOrdinal: 11,
                retryGeneration: 7,
                retryCaptureOrdinal: 11
            ),
            "the exact OCR attempt that owns a baseline may reopen it"
        )
        precondition(
            !CaptureBaselinePolicy.shouldRevokeForRetry(
                currentGeneration: 7,
                currentCaptureOrdinal: 12,
                retryGeneration: 7,
                retryCaptureOrdinal: 11
            ),
            "a stale OCR completion must not clear a newer frame's baseline"
        )
        precondition(
            !CaptureBaselinePolicy.shouldRevokeForRetry(
                currentGeneration: 8,
                currentCaptureOrdinal: 11,
                retryGeneration: 7,
                retryCaptureOrdinal: 11
            ),
            "an old focused-window generation must not clear the active baseline"
        )
        let retryRects = CaptureBaselinePolicy.effectiveDirtyRects(
            reported: [],
            frameStatusComplete: true,
            frameWidth: 800,
            frameHeight: 600,
            retryPending: true
        )
        precondition(
            retryRects == [DirtyRect(x: 0, y: 0, width: 800, height: 600)],
            "a verified no-content retry must admit one later static frame"
        )
        precondition(
            CaptureBaselinePolicy.effectiveDirtyRects(
                reported: [],
                frameStatusComplete: true,
                frameWidth: 800,
                frameHeight: 600,
                retryPending: false
            ).isEmpty,
            "ordinary static frames must keep the no-dirty-rect energy gate"
        )
        precondition(
            CaptureBaselinePolicy.effectiveDirtyRects(
                reported: [],
                frameStatusComplete: false,
                frameWidth: 800,
                frameHeight: 600,
                retryPending: true
            ).isEmpty,
            "an incomplete frame must never be promoted into an OCR retry"
        )

        let expectedFocus = FocusedWindow(
            bundleId: "com.example.Editor",
            windowId: 42,
            axRect: .zero
        )
        let focusStore = FocusedWindowStore()
        let focusTracker = FocusTracker(
            store: focusStore,
            reader: FixedFocusedWindowReader(focused: expectedFocus)
        )
        await focusTracker.refreshOnce()
        precondition(
            focusStore.currentSync() == FocusedWindowSnapshot(
                focused: expectedFocus,
                generation: 1
            ),
            "the synchronous startup refresh must publish focus before filter selection"
        )

        let movedSameWindow = FocusedWindow(
            bundleId: expectedFocus.bundleId,
            windowId: expectedFocus.windowId,
            axRect: CGRect(x: 20, y: 30, width: 900, height: 700)
        )
        await focusStore.store(movedSameWindow)
        precondition(
            focusStore.currentSync() == FocusedWindowSnapshot(
                focused: movedSameWindow,
                generation: 1
            ),
            "geometry-only updates must not create a new capture-filter generation"
        )

        let nextFocus = FocusedWindow(
            bundleId: "com.example.Terminal",
            windowId: 84,
            axRect: nil
        )
        await focusStore.store(nextFocus)
        precondition(
            focusStore.currentSync() == FocusedWindowSnapshot(
                focused: nextFocus,
                generation: 2
            ),
            "a new identity must invalidate the prior filter generation"
        )

        precondition(
            CaptureGenerationPolicy.shouldAdmit(
                streamGeneration: 2,
                installedGeneration: 2,
                observedGeneration: 2
            ),
            "the active stream generation must be admitted"
        )
        precondition(
            !CaptureGenerationPolicy.shouldAdmit(
                streamGeneration: 1,
                installedGeneration: 2,
                observedGeneration: 2
            ),
            "a queued callback from the old stream must be rejected after rebind"
        )
        precondition(
            !CaptureGenerationPolicy.shouldAdmit(
                streamGeneration: nil,
                installedGeneration: 2,
                observedGeneration: 2
            ),
            "an unregistered stream must fail closed"
        )

        precondition(
            FocusedContextPolicy.admittedWindowTitle(
                snapshotBundleId: "com.example.OldApp",
                effectiveBundleId: nextFocus.bundleId,
                snapshotFocusGeneration: 1,
                effectiveFocusGeneration: 2,
                windowTitle: "Private old title"
            ) == nil,
            "metadata from another app generation must not be attached to focused pixels"
        )
        precondition(
            FocusedContextPolicy.admittedWindowTitle(
                snapshotBundleId: nextFocus.bundleId,
                effectiveBundleId: nextFocus.bundleId,
                snapshotFocusGeneration: 1,
                effectiveFocusGeneration: 2,
                windowTitle: "Private title from another window"
            ) == nil,
            "metadata from another window of the same app must not be attached"
        )
        precondition(
            FocusedContextPolicy.admittedWindowTitle(
                snapshotBundleId: nextFocus.bundleId,
                effectiveBundleId: nextFocus.bundleId,
                snapshotFocusGeneration: 2,
                effectiveFocusGeneration: 2,
                windowTitle: "Current title"
            ) == "Current title"
        )

        let workflowStore = WorkflowContextSnapshot()
        let workflowContext = WorkflowContext(
            appBundleId: nextFocus.bundleId,
            windowTitle: "Current title"
        )
        await workflowStore.store(workflowContext, focusGeneration: 2)
        precondition(
            workflowStore.currentObservationSync()
                == WorkflowContextObservation(
                    context: workflowContext,
                    focusGeneration: 2
                ),
            "context and focus provenance must be published atomically"
        )

        let retryMonitor = TCCStatusMonitor(
            probe: FixedTCCProbe(statuses: [.screenRecording: .granted]),
            surfaces: [.screenRecording]
        )
        retryMonitor.seedInitialSnapshot()
        precondition(
            retryMonitor.currentStatuses()[.screenRecording] == .granted,
            "the retry fixture must begin from the published grant that triggered resume"
        )
        retryMonitor.requireFreshGrantForRetry(surface: .screenRecording)
        precondition(
            retryMonitor.currentStatuses()[.screenRecording] == .denied,
            "a failed stream resume must require a fresh debounced grant transition"
        )
    }
}

private struct FixedTCCProbe: TCCProbe {
    let statuses: [TCCSurface: TCCStatus]

    func status(for surface: TCCSurface) -> TCCStatus {
        statuses[surface] ?? .unknown
    }
}
