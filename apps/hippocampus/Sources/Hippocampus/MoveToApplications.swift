// SPDX-License-Identifier: Apache-2.0
import AppKit
import HippocampusKit
import os

/// Offers to move Hippocampus into Applications when it runs from the disk
/// image or from a copy macOS translocated (launch plan item 3, D6). It runs
/// before anything starts, so no hook, memory server, browser host or login
/// item is ever pointed at a path that won't last. The decision and the move
/// are `ApplicationsFolder` and `ApplicationsFolderMover`, tested in
/// HippocampusKit; this file is the dialogs.
@MainActor
enum MoveToApplicationsPrompt {
    private static let logger = Logger(subsystem: "ai.hippocampus", category: "move-to-applications")

    /// True when this copy should quit now: the copy in Applications opens
    /// once it has, or the person is about to move the app in Finder.
    static func run(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        let location = ApplicationsFolder.current(bundleURL: bundleURL)
        let decision = ApplicationsFolder.decide(
            location,
            home: FileManager.default.homeDirectoryForCurrentUser,
            systemApplicationsWritable: FileManager.default.isWritableFile(atPath: "/Applications")
        )
        logger.info("""
        location: translocated=\(location.isTranslocated, privacy: .public) \
        diskImage=\(location.onDiskImage, privacy: .public) readOnly=\(location.onReadOnlyVolume, privacy: .public)
        """)
        switch decision {
        case .stay:
            return false
        case .moveInFinder(let original, let alreadyInApplications):
            return askToMoveInFinder(original: original, alreadyInApplications: alreadyInApplications)
        case .offerMove(let destination):
            return offerMove(location: location, destination: destination)
        }
    }

    /// Only a move in Finder ends translocation. Show the app there and
    /// quit, so the person opens the moved copy and not this one.
    private static func askToMoveInFinder(original: URL?, alreadyInApplications: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = ApplicationsFolderCopy.finderTitle
        alert.informativeText = ApplicationsFolderCopy.finderMessage(alreadyInApplications: alreadyInApplications)
        if original != nil { alert.addButton(withTitle: ApplicationsFolderCopy.showInFinder) }
        alert.addButton(withTitle: original != nil ? ApplicationsFolderCopy.notNow : ApplicationsFolderCopy.ok)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard let original, response == .alertFirstButtonReturn else { return false }
        logger.info("move: showing the original in Finder")
        NSWorkspace.shared.activateFileViewerSelecting([original])
        return true
    }

    private static func offerMove(location: ApplicationsFolder.Location, destination: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = ApplicationsFolderCopy.moveTitle
        alert.informativeText = ApplicationsFolderCopy.moveMessage
        alert.addButton(withTitle: ApplicationsFolderCopy.moveButton)
        alert.addButton(withTitle: ApplicationsFolderCopy.notNow)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            logger.info("move: not now")
            return false
        }
        switch moveShowingProgress(from: location.bundleURL, to: destination) {
        case .success(let moved):
            logger.info("move: copied; opening the copy once this one quits")
            do {
                try MovedCopyLauncher.launch(bundle: moved, ejecting: location.onDiskImage ? location.volumeURL : nil)
            } catch {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: moved, configuration: configuration)
            }
            return true
        case .failure(let failure):
            logger.error("move: failed (\(String(describing: failure), privacy: .public))")
            let notMoved = NSAlert()
            notMoved.messageText = ApplicationsFolderCopy.notMovedTitle
            notMoved.informativeText = ApplicationsFolderCopy.notMovedMessage(failure)
            notMoved.addButton(withTitle: ApplicationsFolderCopy.ok)
            notMoved.runModal()
            // Two copies must not run at once; the open one stays.
            return failure == .destinationIsOpen
        }
    }

    /// The copy takes a few seconds from a disk image. A small window says
    /// so, and nothing else in the app acts until it is done.
    private static func moveShowingProgress(
        from source: URL, to destination: URL
    ) -> Result<URL, ApplicationsFolderMover.Failure> {
        let panel = progressPanel()
        let outcome = OSAllocatedUnfairLock<Result<URL, ApplicationsFolderMover.Failure>?>(initialState: nil)
        let mover = ApplicationsFolderMover.forApp(running: source)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, ApplicationsFolderMover.Failure>
            do throws(ApplicationsFolderMover.Failure) {
                result = .success(try mover.move(from: source, to: destination))
            } catch {
                result = .failure(error)
            }
            outcome.withLock { $0 = result }
        }
        panel.center()
        let session = NSApp.beginModalSession(for: panel)
        defer {
            NSApp.endModalSession(session)
            panel.orderOut(nil)
        }
        while true {
            if let result = outcome.withLock({ $0 }) { return result }
            _ = NSApp.runModalSession(session)
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    private static func progressPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 96),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: ApplicationsFolderCopy.moving)
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.usesThreadedAnimation = true
        bar.startAnimation(nil)
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 300).isActive = true
        panel.contentView = stack
        return panel
    }
}

extension ApplicationsFolderMover {
    /// The app's mover: Hippocampus already open from the destination counts
    /// as open, the copy must meet the running app's code signature, and an
    /// older copy goes to the Trash, where the person can get it back.
    static func forApp(running bundle: URL) -> ApplicationsFolderMover {
        let identifier = Bundle.main.bundleIdentifier ?? ""
        return ApplicationsFolderMover(
            isOpen: { url in
                NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                    .contains { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
            },
            isIntact: { copy in BundleSignature.copy(copy, matches: bundle) },
            trash: { url in
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                return (resulting as URL?) ?? url
            }
        )
    }
}
