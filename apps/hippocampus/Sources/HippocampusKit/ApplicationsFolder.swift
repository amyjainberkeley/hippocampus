// SPDX-License-Identifier: Apache-2.0
import Darwin
import DiskArbitration
import Foundation
import Security

/// Where Hippocampus runs from, and what to do when that place won't last
/// (launch plan item 3, D6).
///
/// Opened straight from the disk image, it runs from a volume that goes away
/// when the disk image is ejected. Opened where macOS translocated it, it
/// runs from a temporary read-only copy whose path changes every launch.
/// Either way the Claude Code hook, the memory server registrations, the
/// browser hosts and the login item would point at a path that stops working.
///
/// From a disk image, Hippocampus copies itself into Applications and opens
/// the copy. A translocated copy can't fix itself: only moving the app in
/// Finder ends translocation, short of removing the quarantine attribute,
/// which Hippocampus never does (scripts/test-no-quarantine-bypass.sh). A
/// copy made here keeps the original's quarantine attribute, so Gatekeeper
/// still checks it.
public enum ApplicationsFolder {
    /// What the launch found out about the running bundle.
    public struct Location: Equatable, Sendable {
        public var bundleURL: URL
        /// macOS runs a temporary copy of the app (Gatekeeper path
        /// randomization).
        public var isTranslocated: Bool
        /// Where the temporary copy came from, when macOS says.
        public var originalURL: URL?
        /// The bundle's volume is a mounted disk image.
        public var onDiskImage: Bool
        /// The bundle's volume can't be written.
        public var onReadOnlyVolume: Bool
        /// The bundle's volume, ejected after a move from a disk image.
        public var volumeURL: URL?

        public init(
            bundleURL: URL,
            isTranslocated: Bool = false,
            originalURL: URL? = nil,
            onDiskImage: Bool = false,
            onReadOnlyVolume: Bool = false,
            volumeURL: URL? = nil
        ) {
            self.bundleURL = bundleURL
            self.isTranslocated = isTranslocated
            self.originalURL = originalURL
            self.onDiskImage = onDiskImage
            self.onReadOnlyVolume = onReadOnlyVolume
            self.volumeURL = volumeURL
        }
    }

    public enum Decision: Equatable, Sendable {
        /// The place lasts; nothing to ask.
        case stay
        /// Offer to copy the app to `destination` and open the copy there.
        case offerMove(destination: URL)
        /// macOS runs a temporary copy. Ask the person to move the app in
        /// Finder, which is what ends translocation. `original` is where the
        /// app really is, when macOS says.
        case moveInFinder(original: URL?, alreadyInApplications: Bool)
    }

    /// The decision for one launch. Pure, so every case is tested.
    public static func decide(_ location: Location, home: URL, systemApplicationsWritable: Bool) -> Decision {
        if location.isTranslocated {
            let original = location.originalURL
            let inApplications = original.map { isInApplicationsFolder($0, home: home) } ?? false
            return .moveInFinder(original: original, alreadyInApplications: inApplications)
        }
        guard location.onDiskImage || location.onReadOnlyVolume,
              !isInApplicationsFolder(location.bundleURL, home: home)
        else { return .stay }
        let folder = destinationFolder(home: home, systemApplicationsWritable: systemApplicationsWritable)
        return .offerMove(destination: folder.appendingPathComponent(location.bundleURL.lastPathComponent, isDirectory: true))
    }

    /// `/Applications` when this account can write to it (an administrator
    /// can), otherwise the person's own `~/Applications`.
    public static func destinationFolder(home: URL, systemApplicationsWritable: Bool) -> URL {
        systemApplicationsWritable
            ? URL(fileURLWithPath: "/Applications", isDirectory: true)
            : home.appendingPathComponent("Applications", isDirectory: true)
    }

    /// Inside `/Applications` or `~/Applications`, at any depth.
    public static func isInApplicationsFolder(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.pathComponents
        let folders = [
            ["/", "Applications"],
            ["/", "System", "Volumes", "Data", "Applications"],
            home.standardizedFileURL.pathComponents + ["Applications"],
        ]
        return folders.contains { folder in path.count > folder.count && Array(path.prefix(folder.count)) == folder }
    }

    /// The randomized path macOS runs a translocated app from:
    /// `/private/var/folders/…/AppTranslocation/<UUID>/d/Hippocampus.app`.
    public static func isTranslocatedPath(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        let underVarFolders = Array(components.prefix(4)) == ["/", "private", "var", "folders"]
            || Array(components.prefix(3)) == ["/", "var", "folders"]
        return underVarFolders && components.contains("AppTranslocation")
    }

    /// macOS mounts a translocated copy with nullfs, and Security's own
    /// check (`SecTranslocateIsTranslocatedURL`) asks just that. The path is
    /// a second sign, in case the mount is ever named differently.
    public static func isTranslocated(_ url: URL, fileSystemType: String?) -> Bool {
        fileSystemType == "nullfs" || isTranslocatedPath(url)
    }

    /// Reads the running bundle's place: its path, its volume's mount flags
    /// and Disk Arbitration's description of that volume. Quick, and it
    /// opens nothing on the volume.
    public static func current(bundleURL: URL) -> Location {
        let url = bundleURL.standardizedFileURL
        var location = Location(bundleURL: url)
        var info = statfs()
        let found = statfs(url.path, &info) == 0
        let fileSystemType = found ? string(&info.f_fstypename) : nil
        if isTranslocated(url, fileSystemType: fileSystemType) {
            location.isTranslocated = true
            location.originalURL = translocationOriginal(of: url)
            return location
        }
        guard found else { return location }
        location.onReadOnlyVolume = info.f_flags & UInt32(MNT_RDONLY) != 0
        let mountPoint = string(&info.f_mntonname)
        guard !mountPoint.isEmpty else { return location }
        let volume = URL(fileURLWithPath: mountPoint, isDirectory: true)
        location.volumeURL = volume
        location.onDiskImage = isDiskImage(volume)
        return location
    }

    private static func string<T>(_ field: inout T) -> String {
        withUnsafeBytes(of: &field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Disk Arbitration names a mounted disk image's device "Disk Image".
    public static func isDiskImage(_ volume: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return false }
        let model = description[kDADiskDescriptionDeviceModelKey as String] as? String
        let deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        return model == diskImageName || deviceProtocol == diskImageName
    }

    static let diskImageName = "Disk Image"

    /// Where macOS made a translocated copy from. Apple documents no API for
    /// this; Security exports `SecTranslocateCreateOriginalPathForURL`, so it
    /// is looked up at run time and its absence only means Finder can't be
    /// shown the original.
    public static func translocationOriginal(of url: URL) -> URL? {
        guard let create = originalPathFunction() else { return nil }
        var error: Unmanaged<CFError>?
        guard let created = create(url as CFURL, &error)?.takeRetainedValue() else {
            error?.release()
            return nil
        }
        let original = (created as URL).standardizedFileURL
        return original == url ? nil : original
    }

    typealias CreateOriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    static func originalPathFunction() -> CreateOriginalPath? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecTranslocateCreateOriginalPathForURL") else {
            return nil
        }
        return unsafeBitCast(symbol, to: CreateOriginalPath.self)
    }
}

// MARK: - The move

/// Copies the app into an Applications folder in one step that can be undone:
/// the copy is staged on the destination's volume, checked against the
/// running app's code signature, and only then put in place. A copy already
/// there goes to the Trash first and comes back if the last step fails.
public struct ApplicationsFolderMover: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The copy already in Applications is running.
        case destinationIsOpen
        /// The destination's disk is full.
        case notEnoughSpace
        /// The copy is not the same signed app, so nothing was replaced.
        case copyNotIntact
        /// Copying, or putting the copy in place, failed.
        case couldNotCopy
    }

    /// Whether a running app was opened from `url`.
    public var isOpen: @Sendable (URL) -> Bool
    /// Whether `copy` is the same signed app as the one running.
    public var isIntact: @Sendable (URL) -> Bool
    /// Moves an item to the Trash and says where it went.
    public var trash: @Sendable (URL) throws -> URL
    /// Puts the checked copy in place: a rename on the same volume.
    public var place: @Sendable (URL, URL) throws -> Void

    public init(
        isOpen: @escaping @Sendable (URL) -> Bool,
        isIntact: @escaping @Sendable (URL) -> Bool,
        trash: @escaping @Sendable (URL) throws -> URL,
        place: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) {
        self.isOpen = isOpen
        self.isIntact = isIntact
        self.trash = trash
        self.place = place
    }

    /// Copies `source` to `destination`, replacing an app already there.
    /// Nothing at `destination` changes unless the checked copy is ready.
    public func move(from source: URL, to destination: URL) throws(Failure) -> URL {
        let files = FileManager.default
        if isOpen(destination) { throw .destinationIsOpen }
        let folder = destination.deletingLastPathComponent()
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw .couldNotCopy
        }
        let staging: URL
        do {
            staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: folder, create: true)
        } catch {
            throw .couldNotCopy
        }
        defer { try? files.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        do {
            try files.copyItem(at: source, to: staged)
        } catch {
            throw Self.isOutOfSpace(error) ? .notEnoughSpace : .couldNotCopy
        }
        guard isIntact(staged) else { throw .copyNotIntact }
        var trashed: URL?
        if (try? destination.checkResourceIsReachable()) == true {
            do {
                trashed = try trash(destination)
            } catch {
                throw .couldNotCopy
            }
        }
        do {
            try place(staged, destination)
        } catch {
            if let trashed { try? files.moveItem(at: trashed, to: destination) }
            throw Self.isOutOfSpace(error) ? .notEnoughSpace : .couldNotCopy
        }
        return destination
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }
}

// MARK: - Checking the copy

/// The copy is the same signed app: valid, and meeting the original's
/// designated requirement, with every nested binary and sealed resource
/// checked. A build that isn't signed has no requirement to meet.
public enum BundleSignature {
    public static func copy(_ copy: URL, matches original: URL) -> Bool {
        var originalCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(original as CFURL, [], &originalCode) == errSecSuccess,
              let originalCode
        else { return false }
        var requirement: SecRequirement?
        let status = SecCodeCopyDesignatedRequirement(originalCode, [], &requirement)
        if status == errSecCSUnsigned { return true }
        guard status == errSecSuccess, let requirement else { return false }
        var copyCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(copy as CFURL, [], &copyCode) == errSecSuccess, let copyCode else {
            return false
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate))
        return SecStaticCodeCheckValidity(copyCode, flags, requirement) == errSecSuccess
    }
}

// MARK: - Opening the copy

/// Opens the copy once this process has quit, so two copies never run at
/// once, after ejecting the disk image the app came from. Not quiet: the
/// copy opens as if the person had opened it.
public enum MovedCopyLauncher {
    /// `/bin/sh` arguments: wait up to 10 s for `pid` to exit, eject
    /// `volume` when given, then open `bundle`.
    public static func arguments(
        bundle: URL,
        waitingFor pid: pid_t,
        ejecting volume: URL?,
        open: String = "/usr/bin/open",
        hdiutil: String = "/usr/bin/hdiutil"
    ) -> [String] {
        [
            "-c",
            """
            i=0
            while /bin/kill -0 "$2" 2>/dev/null && [ "$i" -lt 100 ]; do /bin/sleep 0.1; i=$((i + 1)); done
            if [ -n "$3" ]; then "$5" detach "$3" -quiet; fi
            exec "$4" "$1"
            """,
            "hippocampus-move",
            bundle.path,
            String(pid),
            volume?.path ?? "",
            open,
            hdiutil,
        ]
    }

    public static func launch(bundle: URL, ejecting volume: URL?) throws {
        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(bundle: bundle, waitingFor: getpid(), ejecting: volume)
        try process.run()
    }
}

// MARK: - Words

/// Every word the move shows, in one place for the copy tests.
public enum ApplicationsFolderCopy {
    public static let moveTitle = "Move Hippocampus to Applications?"
    public static let moveMessage = "It’s running from the disk image, which goes away when you eject it. "
        + "In Applications, it can open at login and your AI tools can find it."
    public static let moveButton = "Move to Applications"
    public static let notNow = "Not Now"
    public static let moving = "Moving Hippocampus to Applications…"

    public static let finderTitle = "Move Hippocampus to Applications"
    public static func finderMessage(alreadyInApplications: Bool) -> String {
        let why = "macOS is running a temporary copy of it, so it can’t open at login and your AI tools can’t find it. "
        return why + (alreadyInApplications
            ? "In Finder, drag Hippocampus out of Applications and back in, then open it again."
            : "Drag it into Applications in Finder, then open it from there.")
    }

    public static let showInFinder = "Show in Finder"
    public static let notMovedTitle = "Couldn’t move Hippocampus"

    public static func notMovedMessage(_ failure: ApplicationsFolderMover.Failure) -> String {
        switch failure {
        case .destinationIsOpen:
            "The copy in Applications is open. Quit it from the menu bar, then open this one again."
        case .notEnoughSpace:
            "There isn’t enough space. Hippocampus stays where it is for now."
        case .copyNotIntact:
            "The copy didn’t match this one, so nothing in Applications changed. Drag Hippocampus there in Finder instead."
        case .couldNotCopy:
            "Drag Hippocampus into Applications in Finder instead."
        }
    }

    public static let ok = "OK"
}
