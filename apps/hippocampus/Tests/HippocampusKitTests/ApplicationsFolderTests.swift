// SPDX-License-Identifier: Apache-2.0
import Darwin
@testable import HippocampusKit
import XCTest

/// Move to Applications (launch plan item 3, D6): where the app runs from,
/// what the launch decides, and the move itself, on synthetic bundles in a
/// temporary folder. Nothing here opens an app, mounts a disk image or
/// touches the Trash.
final class ApplicationsFolderTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("applications-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Undo the read-only folders a test may leave, then remove it all.
        if let items = FileManager.default.enumerator(atPath: scratch.path) {
            for case let item as String in items {
                chmod(scratch.appendingPathComponent(item).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Where it runs from

    func testTheRandomizedPathMacOSRunsATranslocatedAppFromIsRecognised() {
        let translocated = [
            "/private/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/T/AppTranslocation/"
                + "6A8B2C1E-5F3D-4E7A-9B0C-1D2E3F4A5B6C/d/Hippocampus.app",
            "/var/folders/ab/cdef/T/AppTranslocation/0F0F/d/Hippocampus.app",
        ]
        for path in translocated {
            XCTAssertTrue(ApplicationsFolder.isTranslocatedPath(URL(fileURLWithPath: path)), path)
        }
        let notTranslocated = [
            "/Applications/Hippocampus.app",
            "/Volumes/Hippocampus/Hippocampus.app",
            "/Users/someone/Downloads/Hippocampus.app",
            "/Users/someone/AppTranslocation/Hippocampus.app",
            "/private/var/folders/zz/T/Hippocampus.app",
        ]
        for path in notTranslocated {
            XCTAssertFalse(ApplicationsFolder.isTranslocatedPath(URL(fileURLWithPath: path)), path)
        }
    }

    func testANullfsMountIsTranslocatedWhateverItsPath() {
        let elsewhere = URL(fileURLWithPath: "/private/var/folders/zz/x/T/Other/Hippocampus.app")
        XCTAssertTrue(ApplicationsFolder.isTranslocated(elsewhere, fileSystemType: "nullfs"))
        XCTAssertFalse(ApplicationsFolder.isTranslocated(elsewhere, fileSystemType: "apfs"))
        XCTAssertFalse(ApplicationsFolder.isTranslocated(URL(fileURLWithPath: "/Volumes/Hippocampus/Hippocampus.app"),
                                                         fileSystemType: "hfs"))
        XCTAssertTrue(ApplicationsFolder.isTranslocated(
            URL(fileURLWithPath: "/private/var/folders/zz/x/T/AppTranslocation/1/d/Hippocampus.app"), fileSystemType: nil
        ))
    }

    func testOnlyTheTwoApplicationsFoldersCount() {
        let inside = [
            "/Applications/Hippocampus.app",
            "/Applications/Utilities/Hippocampus.app",
            "/System/Volumes/Data/Applications/Hippocampus.app",
            "/Users/someone/Applications/Hippocampus.app",
        ]
        for path in inside {
            XCTAssertTrue(ApplicationsFolder.isInApplicationsFolder(URL(fileURLWithPath: path), home: home), path)
        }
        let outside = [
            "/Volumes/Hippocampus/Hippocampus.app",
            "/Volumes/Hippocampus/Applications/Hippocampus.app",
            "/Applications Old/Hippocampus.app",
            "/Applications",
            "/Users/someone/Downloads/Hippocampus.app",
            "/Users/other/Applications/Hippocampus.app",
        ]
        for path in outside {
            XCTAssertFalse(ApplicationsFolder.isInApplicationsFolder(URL(fileURLWithPath: path), home: home), path)
        }
    }

    // MARK: What the launch decides

    func testFromTheDiskImageItOffersToCopyItselfIntoApplications() {
        let dmg = location("/Volumes/Hippocampus/Hippocampus.app", onDiskImage: true, readOnly: true)
        XCTAssertEqual(
            ApplicationsFolder.decide(dmg, home: home, systemApplicationsWritable: true),
            .offerMove(destination: URL(fileURLWithPath: "/Applications/Hippocampus.app", isDirectory: true))
        )
    }

    func testWithoutWriteAccessToApplicationsItUsesThePersonsOwn() {
        let dmg = location("/Volumes/Hippocampus/Hippocampus.app", onDiskImage: true, readOnly: true)
        XCTAssertEqual(
            ApplicationsFolder.decide(dmg, home: home, systemApplicationsWritable: false),
            .offerMove(destination: URL(fileURLWithPath: "/Users/someone/Applications/Hippocampus.app", isDirectory: true))
        )
    }

    func testAnyReadOnlyVolumeCountsAndTheNameTheyGaveItIsKept() {
        let locked = location("/Volumes/Stick/Tools/My Hippocampus.app", readOnly: true)
        XCTAssertEqual(
            ApplicationsFolder.decide(locked, home: home, systemApplicationsWritable: true),
            .offerMove(destination: URL(fileURLWithPath: "/Applications/My Hippocampus.app", isDirectory: true))
        )
    }

    func testAPlaceThatLastsIsLeftAlone() {
        let lasting = [
            location("/Applications/Hippocampus.app"),
            location("/Users/someone/Applications/Hippocampus.app"),
            // A development build, and a copy someone keeps elsewhere.
            location("/Users/someone/src/hippocampus/build/Hippocampus.app"),
            location("/Volumes/External/Hippocampus.app"),
        ]
        for place in lasting {
            XCTAssertEqual(
                ApplicationsFolder.decide(place, home: home, systemApplicationsWritable: true), .stay,
                place.bundleURL.path
            )
        }
    }

    /// Copying a translocated app keeps its quarantine attribute, so macOS
    /// would translocate the copy too: the person moves it in Finder.
    func testATranslocatedCopyAsksForAMoveInFinderAndNeverLoops() {
        let random = "/private/var/folders/zz/x/T/AppTranslocation/1234/d/Hippocampus.app"
        let downloads = URL(fileURLWithPath: "/Users/someone/Downloads/Hippocampus.app", isDirectory: true)
        XCTAssertEqual(
            ApplicationsFolder.decide(
                location(random, translocated: true, original: downloads), home: home, systemApplicationsWritable: true
            ),
            .moveInFinder(original: downloads, alreadyInApplications: false)
        )
        let applications = URL(fileURLWithPath: "/Applications/Hippocampus.app", isDirectory: true)
        XCTAssertEqual(
            ApplicationsFolder.decide(
                location(random, translocated: true, original: applications), home: home, systemApplicationsWritable: true
            ),
            .moveInFinder(original: applications, alreadyInApplications: true)
        )
        XCTAssertEqual(
            ApplicationsFolder.decide(location(random, translocated: true), home: home, systemApplicationsWritable: true),
            .moveInFinder(original: nil, alreadyInApplications: false)
        )
    }

    // MARK: Reading this Mac

    func testAFolderOnThisMacReadsAsAPlaceThatLasts() throws {
        let bundle = try makeBundle(named: "Hippocampus.app")
        let found = ApplicationsFolder.current(bundleURL: bundle)
        XCTAssertFalse(found.isTranslocated)
        XCTAssertNil(found.originalURL)
        XCTAssertFalse(found.onDiskImage)
        XCTAssertFalse(found.onReadOnlyVolume)
        XCTAssertNotNil(found.volumeURL)
        XCTAssertEqual(ApplicationsFolder.decide(found, home: home, systemApplicationsWritable: true), .stay)
    }

    func testTheStartupVolumesAreNotDiskImages() {
        XCTAssertFalse(ApplicationsFolder.isDiskImage(URL(fileURLWithPath: "/")))
        XCTAssertFalse(ApplicationsFolder.isDiskImage(URL(fileURLWithPath: "/System/Volumes/Data")))
    }

    /// The lookup for a translocated app's original is found on this macOS,
    /// and a path macOS didn't translocate has no original.
    func testTheTranslocationLookupIsPresentAndQuietForOrdinaryPaths() throws {
        XCTAssertNotNil(ApplicationsFolder.originalPathFunction())
        XCTAssertNil(ApplicationsFolder.translocationOriginal(of: try makeBundle(named: "Hippocampus.app")))
    }

    // MARK: The move

    func testTheCopyKeepsLinksPermissionsAndTheQuarantineAttribute() throws {
        let source = try makeBundle(named: "Hippocampus.app")
        let quarantine = "0083;6710a4c0;Safari;7C3E1A2B-0000-4000-8000-000000000001"
        try setAttribute("com.apple.quarantine", quarantine, on: source)
        try setAttribute("com.apple.quarantine", quarantine, on: source.appendingPathComponent("Contents/MacOS/Hippocampus"))
        let destination = scratch.appendingPathComponent("Applications/Hippocampus.app")

        let moved = try mover().move(from: source, to: destination)

        XCTAssertEqual(moved, destination)
        let files = FileManager.default
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Contents/Resources/note.txt"), encoding: .utf8), "v2")
        XCTAssertEqual(
            try files.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("Contents/Frameworks/Current").path),
            "Versions/A"
        )
        XCTAssertTrue(files.isExecutableFile(atPath: destination.appendingPathComponent("Contents/MacOS/Hippocampus").path))
        // Gatekeeper still checks the copy: it stays quarantined with every
        // flag the original had. (macOS rewrites a copied folder's attribute,
        // seen here as 0083 becoming 0283; it never drops a flag.)
        for copied in [destination, destination.appendingPathComponent("Contents/MacOS/Hippocampus")] {
            let flags = try XCTUnwrap(quarantineFlags(of: copied), copied.path)
            XCTAssertEqual(flags & 0x0083, 0x0083, copied.path)
            XCTAssertTrue(try attribute("com.apple.quarantine", of: copied).hasSuffix(";7C3E1A2B-0000-4000-8000-000000000001"))
        }
        // The original stays where it was.
        XCTAssertTrue(files.fileExists(atPath: source.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertEqual(try attribute("com.apple.quarantine", of: source), quarantine)
    }

    func testAnOlderCopyGoesToTheTrashAndTheNewOneTakesItsPlace() throws {
        let source = try makeBundle(named: "Hippocampus.app", note: "new")
        let applications = scratch.appendingPathComponent("Applications", isDirectory: true)
        let old = try makeBundle(named: "Hippocampus.app", note: "old", in: applications)
        let trash = scratch.appendingPathComponent("Trash", isDirectory: true)

        _ = try mover(trashFolder: trash).move(from: source, to: old)

        XCTAssertEqual(try note(in: old), "new")
        XCTAssertEqual(try note(in: trash.appendingPathComponent("Hippocampus.app")), "old")
    }

    func testACopyThatDoesNotCheckOutChangesNothing() throws {
        let source = try makeBundle(named: "Hippocampus.app", note: "new")
        let applications = scratch.appendingPathComponent("Applications", isDirectory: true)
        let old = try makeBundle(named: "Hippocampus.app", note: "old", in: applications)
        let trash = scratch.appendingPathComponent("Trash", isDirectory: true)

        XCTAssertThrowsError(try mover(trashFolder: trash, intact: false).move(from: source, to: old)) {
            XCTAssertEqual($0 as? ApplicationsFolderMover.Failure, .copyNotIntact)
        }
        XCTAssertEqual(try note(in: old), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["Hippocampus.app"])
    }

    func testAnOpenCopyInApplicationsIsNeverReplaced() throws {
        let source = try makeBundle(named: "Hippocampus.app", note: "new")
        let applications = scratch.appendingPathComponent("Applications", isDirectory: true)
        let old = try makeBundle(named: "Hippocampus.app", note: "old", in: applications)
        let checked = Counter()

        let open = ApplicationsFolderMover(
            isOpen: { $0.standardizedFileURL == old.standardizedFileURL },
            isIntact: { _ in checked.add(); return true },
            trash: { _ in XCTFail("an open copy is never trashed"); throw CocoaError(.fileWriteNoPermission) }
        )
        XCTAssertThrowsError(try open.move(from: source, to: old)) {
            XCTAssertEqual($0 as? ApplicationsFolderMover.Failure, .destinationIsOpen)
        }
        XCTAssertEqual(try note(in: old), "old")
        XCTAssertEqual(checked.value, 0, "nothing is copied for an open destination")
    }

    func testWhenTheLastStepFailsTheOlderCopyComesBack() throws {
        let source = try makeBundle(named: "Hippocampus.app", note: "new")
        let applications = scratch.appendingPathComponent("Applications", isDirectory: true)
        let old = try makeBundle(named: "Hippocampus.app", note: "old", in: applications)
        let trash = scratch.appendingPathComponent("Trash", isDirectory: true)
        let failing = ApplicationsFolderMover(
            isOpen: { _ in false },
            isIntact: { _ in true },
            trash: Self.trash(into: trash),
            place: { _, _ in throw CocoaError(.fileWriteUnknown) }
        )

        XCTAssertThrowsError(try failing.move(from: source, to: old)) {
            XCTAssertEqual($0 as? ApplicationsFolderMover.Failure, .couldNotCopy)
        }
        XCTAssertEqual(try note(in: old), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
    }

    func testAMissingSourceIsACopyFailure() throws {
        let missing = scratch.appendingPathComponent("Gone/Hippocampus.app")
        let destination = scratch.appendingPathComponent("Applications/Hippocampus.app")
        XCTAssertThrowsError(try mover().move(from: missing, to: destination)) {
            XCTAssertEqual($0 as? ApplicationsFolderMover.Failure, .couldNotCopy)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAFullDiskIsNamedAsSuch() {
        XCTAssertTrue(ApplicationsFolderMover.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
        XCTAssertTrue(ApplicationsFolderMover.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        XCTAssertTrue(ApplicationsFolderMover.isOutOfSpace(NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]
        )))
        XCTAssertFalse(ApplicationsFolderMover.isOutOfSpace(CocoaError(.fileWriteNoPermission)))
    }

    // MARK: Checking the copy, with the Security framework as the judge

    func testACopyOfASignedAppMatchesAndATamperedOrDifferentOneDoesNot() throws {
        let original = try makeSignedBundle(named: "Signed.app", identifier: "ai.hippocampus.test.signed")
        let copy = scratch.appendingPathComponent("Copy/Signed.app")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: copy)
        XCTAssertTrue(BundleSignature.copy(copy, matches: original))

        try Data("changed".utf8).write(to: copy.appendingPathComponent("Contents/Resources/note.txt"))
        XCTAssertFalse(BundleSignature.copy(copy, matches: original), "a changed resource breaks the seal")

        let other = try makeSignedBundle(named: "Other.app", identifier: "ai.hippocampus.test.other")
        XCTAssertFalse(BundleSignature.copy(other, matches: original), "another app is not this app")
        XCTAssertFalse(BundleSignature.copy(scratch.appendingPathComponent("Missing.app"), matches: original))
    }

    func testAnUnsignedBuildHasNoSignatureToMeet() throws {
        let unsigned = try makeBundle(named: "Unsigned.app")
        XCTAssertTrue(BundleSignature.copy(unsigned, matches: unsigned))
    }

    // MARK: Opening the copy

    func testTheCopyOpensOnlyAfterThisOneQuitsAndTheDiskImageIsEjectedFirst() throws {
        let log = scratch.appendingPathComponent("calls.log")
        // Stands in for the copy that is quitting.
        let quitting = try Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.6"])
        let open = try fakeTool("open", log: log, noting: quitting.processIdentifier)
        let hdiutil = try fakeTool("hdiutil", log: log, noting: quitting.processIdentifier)

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = MovedCopyLauncher.arguments(
            bundle: URL(fileURLWithPath: "/Applications/Hippocampus.app", isDirectory: true),
            waitingFor: quitting.processIdentifier,
            ejecting: URL(fileURLWithPath: "/Volumes/Hippocampus", isDirectory: true),
            open: open.path, hdiutil: hdiutil.path
        )
        try launcher.run()
        launcher.waitUntilExit()

        XCTAssertEqual(launcher.terminationStatus, 0)
        // Neither tool ran while the old copy was still open.
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), """
        hdiutil detach /Volumes/Hippocampus -quiet
        open /Applications/Hippocampus.app

        """)
    }

    func testWithoutADiskImageNothingIsEjectedAndTheOpenIsNotQuiet() throws {
        let log = scratch.appendingPathComponent("calls.log")
        let open = try fakeTool("open", log: log)
        let hdiutil = try fakeTool("hdiutil", log: log)
        let arguments = MovedCopyLauncher.arguments(
            bundle: URL(fileURLWithPath: "/Users/someone/Applications/Hippocampus.app"),
            waitingFor: 999_999, ejecting: nil, open: open.path, hdiutil: hdiutil.path
        )
        XCTAssertFalse(arguments.joined(separator: " ").contains(QuietLaunchNote.environmentKey))
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = arguments
        try launcher.run()
        launcher.waitUntilExit()
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "open /Users/someone/Applications/Hippocampus.app\n")
    }

    // MARK: Words

    func testTheWordsAreShortAndPlain() {
        let lines = [
            ApplicationsFolderCopy.moveTitle, ApplicationsFolderCopy.moveMessage, ApplicationsFolderCopy.moveButton,
            ApplicationsFolderCopy.notNow, ApplicationsFolderCopy.moving, ApplicationsFolderCopy.finderTitle,
            ApplicationsFolderCopy.finderMessage(alreadyInApplications: false),
            ApplicationsFolderCopy.finderMessage(alreadyInApplications: true),
            ApplicationsFolderCopy.showInFinder, ApplicationsFolderCopy.notMovedTitle,
        ] + [ApplicationsFolderMover.Failure.destinationIsOpen, .notEnoughSpace, .copyNotIntact, .couldNotCopy]
            .map(ApplicationsFolderCopy.notMovedMessage)
        for line in lines {
            XCTAssertFalse(line.contains("!"), line)
            XCTAssertLessThanOrEqual(line.count, 200, line)
        }
        XCTAssertTrue(ApplicationsFolderCopy.moveMessage.contains("disk image"))
    }

    // MARK: Fixtures

    private func location(
        _ path: String, translocated: Bool = false, original: URL? = nil,
        onDiskImage: Bool = false, readOnly: Bool = false
    ) -> ApplicationsFolder.Location {
        ApplicationsFolder.Location(
            bundleURL: URL(fileURLWithPath: path, isDirectory: true), isTranslocated: translocated,
            originalURL: original, onDiskImage: onDiskImage, onReadOnlyVolume: readOnly
        )
    }

    /// A small app-shaped folder: Info.plist, an executable, a resource and
    /// a framework-style link.
    @discardableResult
    private func makeBundle(named name: String, note: String = "v2", in folder: URL? = nil) throws -> URL {
        let bundle = (folder ?? scratch).appendingPathComponent(name, isDirectory: true)
        let files = FileManager.default
        for path in ["Contents/MacOS", "Contents/Resources", "Contents/Frameworks/Versions/A"] {
            try files.createDirectory(at: bundle.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("<plist/>".utf8).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let executable = bundle.appendingPathComponent("Contents/MacOS/Hippocampus")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data(note.utf8).write(to: bundle.appendingPathComponent("Contents/Resources/note.txt"))
        try files.createSymbolicLink(
            atPath: bundle.appendingPathComponent("Contents/Frameworks/Current").path, withDestinationPath: "Versions/A"
        )
        return bundle
    }

    /// A real app bundle, signed ad hoc with codesign: a copy of /usr/bin/true
    /// as its executable, and a sealed resource.
    private func makeSignedBundle(named name: String, identifier: String) throws -> URL {
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        guard FileManager.default.isExecutableFile(atPath: codesign.path) else {
            throw XCTSkip("codesign is not on this Mac")
        }
        let bundle = scratch.appendingPathComponent(name, isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try files.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleExecutable": "Fixture", "CFBundleIdentifier": identifier,
            "CFBundlePackageType": "APPL", "CFBundleName": "Fixture",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try files.copyItem(atPath: "/usr/bin/true", toPath: bundle.appendingPathComponent("Contents/MacOS/Fixture").path)
        try Data("sealed".utf8).write(to: bundle.appendingPathComponent("Contents/Resources/note.txt"))
        let sign = try Process.run(codesign, arguments: ["--force", "--sign", "-", bundle.path])
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw XCTSkip("codesign could not sign the fixture") }
        return bundle
    }

    private func mover(trashFolder: URL? = nil, intact: Bool = true) -> ApplicationsFolderMover {
        let trash = trashFolder ?? scratch.appendingPathComponent("Trash", isDirectory: true)
        return ApplicationsFolderMover(isOpen: { _ in false }, isIntact: { _ in intact }, trash: Self.trash(into: trash))
    }

    private static func trash(into folder: URL) -> @Sendable (URL) throws -> URL {
        { url in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let trashed = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: trashed)
            return trashed
        }
    }

    /// The flag bits at the start of a quarantine attribute ("0083;…").
    private func quarantineFlags(of url: URL) throws -> UInt16? {
        let value = try attribute("com.apple.quarantine", of: url)
        return value.split(separator: ";").first.flatMap { UInt16($0, radix: 16) }
    }

    private func note(in bundle: URL) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent("Contents/Resources/note.txt"), encoding: .utf8)
    }

    private func setAttribute(_ name: String, _ value: String, on url: URL) throws {
        let bytes = Array(value.utf8)
        guard setxattr(url.path, name, bytes, bytes.count, 0, XATTR_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func attribute(_ name: String, of url: URL) throws -> String {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &bytes, size, 0, XATTR_NOFOLLOW) == size else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A stand-in for open or hdiutil that writes its name and arguments,
    /// and says so when it runs while process `pid` is still running.
    private func fakeTool(_ name: String, log: URL, noting pid: pid_t? = nil) throws -> URL {
        let tool = scratch.appendingPathComponent("bin/\(name)")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        var script = "#!/bin/sh\n"
        if let pid {
            script += "if /bin/kill -0 \(pid) 2>/dev/null; then echo \"\(name) ran while \(pid) was open\" >> '\(log.path)'; fi\n"
        }
        script += "echo \"\(name) $*\" >> '\(log.path)'\n"
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func add() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
