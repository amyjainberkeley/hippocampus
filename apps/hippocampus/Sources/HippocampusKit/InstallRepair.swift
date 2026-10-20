// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import os

/// What a launch puts right that an older Hippocampus left on this Mac,
/// before anything else starts. Every step is idempotent, so it runs on each
/// launch: the first launch after an upgrade does the work, and later
/// launches find nothing to do.
public enum InstallRepair {
    /// The two folders 0.3.0's OCR worker left in the account's `~/Library`.
    /// Its ONNX Runtime carried Microsoft's telemetry client, whose CFNetwork
    /// session kept a URL cache and HTTP storage named after the worker's
    /// process (reports/e2e, finding 1; the storage review's S1). The worker
    /// now runs with telemetry off and no network, so nothing makes them
    /// again.
    ///
    /// ONNX Runtime's own `Application Support/Microsoft/DeveloperTools/
    /// .onnxruntime` is not on this list: every app that uses ONNX Runtime
    /// shares it.
    public static func ocrWorkerNetworkFolders(home: URL) -> [URL] {
        [
            home.appendingPathComponent("Library/Caches/hippocampus-ocr", isDirectory: true),
            home.appendingPathComponent("Library/HTTPStorages/hippocampus-ocr", isDirectory: true),
        ]
    }

    /// Deletes exactly ``ocrWorkerNetworkFolders(home:)``, and nothing else.
    /// A symlink in a folder's place is removed, never followed. Returns
    /// what was removed.
    @discardableResult
    public static func removeOCRWorkerNetworkFolders(
        home: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        ocrWorkerNetworkFolders(home: home).filter { folder in
            var info = stat()
            guard lstat(folder.path, &info) == 0 else { return false }
            return (try? fileManager.removeItem(at: folder)) != nil
        }
    }

    /// The folders an older install made 0755, each with the files it made
    /// 0644 directly inside (reports/e2e, finding 5): the memory's folder
    /// (its database, WAL and SHM among them), its logs, the run-lock and
    /// dictionary folder, the device ID, the settings, and the caches.
    public static func ownerOnlyFolders(home: URL) -> [URL] {
        [
            "Library/Application Support/MCI",
            "Library/Logs/MCI",
            "Library/Application Support/Hippocampus",
            ".mci",
            ".config/hippocampus",
            "Library/Caches/ai.hippocampus",
        ].map { home.appendingPathComponent($0, isDirectory: true) }
    }

    /// Takes group and other access off each of ``ownerOnlyFolders(home:)``
    /// and what is directly inside it. The owner's own bits stay (a script
    /// stays runnable), a symlink is never followed, and nothing outside
    /// those folders changes. Returns every path whose mode changed.
    @discardableResult
    public static func makeOwnerOnly(home: URL, fileManager: FileManager = .default) -> [URL] {
        var changed: [URL] = []
        for folder in ownerOnlyFolders(home: home) {
            guard isRealDirectory(folder) else { continue }
            if takeGroupAndOtherAccessOff(folder) { changed.append(folder) }
            let inside = (try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            for item in inside where takeGroupAndOtherAccessOff(item) {
                changed.append(item)
            }
        }
        return changed
    }

    /// Both repairs, as the app runs them at launch. Content-free log lines.
    public static func runOnLaunch(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let logger = Logger(subsystem: "ai.hippocampus", category: "install-repair")
        let removed = removeOCRWorkerNetworkFolders(home: home)
        if !removed.isEmpty {
            logger.info("install-repair: removed \(removed.count, privacy: .public) folder(s) the old OCR worker's network client left")
        }
        let tightened = makeOwnerOnly(home: home)
        if !tightened.isEmpty {
            logger.info("install-repair: made \(tightened.count, privacy: .public) older file(s) and folder(s) owner-only")
        }
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// `chmod g-rwx,o-rwx` without following a symlink. True when it changed.
    private static func takeGroupAndOtherAccessOff(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return false }
        let mode = info.st_mode & 0o7777
        let ownerOnly = mode & ~mode_t(0o077)
        guard ownerOnly != mode else { return false }
        return lchmod(url.path, ownerOnly) == 0
    }
}
