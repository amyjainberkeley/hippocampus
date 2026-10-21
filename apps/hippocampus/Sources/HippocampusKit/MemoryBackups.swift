// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Whether Time Machine backs up the memory (storage-security review S5).
///
/// A backup holds the memory's files beside the login keychain that holds
/// its key, and keeps what is deleted until the backup expires. The memory
/// is a rolling record this Mac rebuilds, so by default its folder carries
/// the sticky "excluded from backup" mark (`isExcludedFromBackup`, which
/// covers everything inside); Preferences can include it.
public enum MemoryBackups {
    /// Preferences' switch.
    public static let toggleTitle = "Include my memory in Time Machine backups"
    /// The one sentence under it.
    public static let tradeoff =
        "A backup can restore your memory, but it also keeps what you delete until that backup expires."

    /// The memory's folder: `~/Library/Application Support/MCI`.
    public static func defaultFolder() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/MCI", isDirectory: true)
    }

    /// Marks `folder` excluded from backups, or not, creating it if it isn't
    /// there yet. The folder is left readable by this account only (mode
    /// 0700), as an earlier release didn't make it. True when the mark is
    /// set as asked.
    ///
    /// The system can make the change a moment after the call that asks for
    /// it returns. On a loaded Mac, taking the mark away has shown up only at
    /// a later check, and a switch turned on and off again quickly has ended
    /// with the mark gone. So this waits, up to `settle`, until the mark
    /// reads as asked before it returns: each change lands before the next
    /// one starts.
    @discardableResult
    public static func apply(include: Bool, folder: URL, settle: Duration = .seconds(1)) -> Bool {
        apply(include: include, folder: folder, settle: settle, mark: { url, excluded in
            var values = URLResourceValues()
            values.isExcludedFromBackup = excluded
            var target = url
            // Ask afresh, not from this URL's cache of an earlier call.
            target.removeAllCachedResourceValues()
            try target.setResourceValues(values)
        }, read: isExcluded)
    }

    /// `apply` with the mark's writer and reader passed in (tests stand in a
    /// system that makes the change late, or never).
    static func apply(
        include: Bool,
        folder: URL,
        settle: Duration,
        mark: (URL, Bool) throws -> Void,
        read: (URL) -> Bool?
    ) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try mark(folder, !include)
        } catch {
            return false
        }
        // While the mark reads as it was, wait for the change; a mark that
        // can't be read at all (nil) ends the wait at once.
        let deadline = ContinuousClock.now.advanced(by: settle)
        while read(folder) == include, ContinuousClock.now < deadline {
            usleep(10_000)
        }
        return read(folder) == !include
    }

    /// The extended attribute the sticky mark is kept in (what
    /// `tmutil addexclusion` and `isExcludedFromBackup` write).
    static let stickyMarkAttribute = "com.apple.metadata:com_apple_backup_excludeItem"

    /// Whether `folder` carries the sticky excluded-from-backup mark; nil
    /// when the folder can't be read. The mark itself, not the computed
    /// value, which is also true anywhere Time Machine skips by path
    /// (`/private/tmp`, the temporary folder).
    public static func isExcluded(_ folder: URL) -> Bool? {
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        let size = getxattr(folder.path, stickyMarkAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        if size >= 0 { return true }
        return errno == ENOATTR ? false : nil
    }
}
