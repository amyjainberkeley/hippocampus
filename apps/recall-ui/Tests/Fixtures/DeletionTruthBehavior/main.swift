import RecallUIKit

@main
enum DeletionTruthBehavior {
    static func main() {
        let committedWithWarnings = DeleteResult(
            eventsDeleted: 3,
            vacuumOk: false,
            blobCleanupOk: false
        )
        precondition(committedWithWarnings.committed)
        precondition(committedWithWarnings.cleanupPending)
        precondition(
            DeletionPresentation.successBanner(for: committedWithWarnings)
                == "Removed 3 events. Storage cleanup is still pending."
        )

        let blocked = BrainReaderError.mutationBlocked
        precondition(
            DeletionPresentation.failureBanner(for: blocked)
                == UserFacingCopy.deleteBlockedBanner
        )
        precondition(!UserFacingCopy.deleteBlockedBanner.contains("Nothing was removed"))
    }
}
