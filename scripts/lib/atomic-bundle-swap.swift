#!/usr/bin/swift
// Usage: swift atomic-bundle-swap.swift --old /absolute/Old.app --new /absolute/New.app
//        --expected-old-head <40 lowercase hex> --expected-new-head <40 lowercase hex>
// Expected source heads must differ; same-revision builds are not supported.
// Caller owns quiescence, backup, nested signatures and full provenance verification.
// Both trees and their parents must remain exclusively controlled during this command.
// This only exchanges names. It never launches, deletes, or rolls back either bundle.
import Foundation
import Darwin

private enum Refusal: String, Error {
    case invalidArguments = "invalid_arguments"
    case invalidExpectedHead = "invalid_expected_head"
    case distinctSourceHeadsRequired = "distinct_source_heads_required"
    case invalidPath = "invalid_path"
    case missingPath = "missing_path"
    case symlinkPath = "symlink_path"
    case wrongFileType = "wrong_file_type"
    case overlappingPaths = "overlapping_paths"
    case differentDevices = "different_devices"
    case invalidBundle = "invalid_bundle"
    case invalidExecutable = "invalid_executable"
    case invalidManifest = "invalid_manifest"
    case sourceHeadMismatch = "source_head_mismatch"
    case metadataTooLarge = "metadata_too_large"
    case metadataReadFailed = "metadata_read_failed"
    case pathChanged = "path_changed"
}

private func isSourceHead(_ value: String) -> Bool {
    value.utf8.count == 40 && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
    }
}

private struct Request {
    let old: String
    let new: String
    let oldHead: String
    let newHead: String

    init(_ arguments: [String]) throws {
        let flags: Set<String> = ["--old", "--new", "--expected-old-head", "--expected-new-head"]
        guard arguments.count == 8 else { throw Refusal.invalidArguments }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let flag = arguments[index]
            guard flags.contains(flag), values[flag] == nil else { throw Refusal.invalidArguments }
            values[flag] = arguments[index + 1]
        }
        guard let old = values["--old"], let new = values["--new"],
              let oldHead = values["--expected-old-head"], let newHead = values["--expected-new-head"]
        else { throw Refusal.invalidArguments }
        guard isSourceHead(oldHead), isSourceHead(newHead) else { throw Refusal.invalidExpectedHead }
        guard oldHead != newHead else { throw Refusal.distinctSourceHeadsRequired }
        for path in [old, new] {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.hasPrefix("/"), path.hasSuffix(".app"), !path.utf8.contains(0),
                  parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
            else { throw Refusal.invalidPath }
        }
        guard old != new, !old.hasPrefix(new + "/"), !new.hasPrefix(old + "/")
        else { throw Refusal.overlappingPaths }
        self.old = old
        self.new = new
        self.oldHead = oldHead
        self.newHead = newHead
    }
}

private func sameIdentity(_ first: stat, _ second: stat) -> Bool {
    first.st_dev == second.st_dev && first.st_ino == second.st_ino
}

private func checkedPath(_ path: String, type: mode_t) throws -> stat {
    let parts = path.split(separator: "/")
    var prefix = ""
    var info = stat()
    for (index, part) in parts.enumerated() {
        prefix += "/" + part
        guard prefix.withCString({ lstat($0, &info) }) == 0 else { throw Refusal.missingPath }
        let actualType = info.st_mode & mode_t(S_IFMT)
        guard actualType != mode_t(S_IFLNK) else { throw Refusal.symlinkPath }
        let expectedType = index == parts.count - 1 ? type : mode_t(S_IFDIR)
        guard actualType == expectedType else { throw Refusal.wrongFileType }
    }
    return info
}

private func readMetadata(_ path: String) throws -> Data {
    let expected = try checkedPath(path, type: mode_t(S_IFREG))
    let fd = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
    guard fd >= 0 else { throw Refusal.metadataReadFailed }
    defer { close(fd) }
    var opened = stat()
    guard fstat(fd, &opened) == 0, sameIdentity(expected, opened),
          opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    else { throw Refusal.pathChanged }
    let maximum = 1024 * 1024
    guard opened.st_size >= 0, opened.st_size <= maximum else { throw Refusal.metadataTooLarge }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while data.count <= maximum {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EINTR { continue }
            throw Refusal.metadataReadFailed
        }
        if count == 0 { return data }
        guard data.count + count <= maximum else { throw Refusal.metadataTooLarge }
        data.append(contentsOf: buffer.prefix(count))
    }
    throw Refusal.metadataTooLarge
}

private struct Manifest: Decodable {
    let schemaVersion: Int
    let sourceHead: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sourceHead = "source_head"
    }
}

private func validateBundle(_ path: String, expectedHead: String) throws {
    let infoData = try readMetadata(path + "/Contents/Info.plist")
    guard let info = (try? PropertyListSerialization.propertyList(from: infoData, format: nil))
            as? [String: Any],
          info["CFBundleIdentifier"] as? String == "ai.hippocampus",
          info["CFBundleExecutable"] as? String == "Hippocampus",
          info["CFBundlePackageType"] as? String == "APPL"
    else { throw Refusal.invalidBundle }
    let executable = path + "/Contents/MacOS/Hippocampus"
    let executableInfo = try checkedPath(executable, type: mode_t(S_IFREG))
    guard executableInfo.st_mode & 0o111 != 0,
          executable.withCString({ access($0, X_OK) }) == 0
    else { throw Refusal.invalidExecutable }
    let manifestData = try readMetadata(path + "/Contents/Resources/build-provenance.json")
    guard let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
          manifest.schemaVersion == 1, isSourceHead(manifest.sourceHead)
    else { throw Refusal.invalidManifest }
    guard manifest.sourceHead == expectedHead else { throw Refusal.sourceHeadMismatch }
}

private struct SwapFailure: Error {
    let code: Int32
}

private func swap(_ request: Request) throws {
    let old = try checkedPath(request.old, type: mode_t(S_IFDIR))
    let new = try checkedPath(request.new, type: mode_t(S_IFDIR))
    guard !sameIdentity(old, new) else { throw Refusal.overlappingPaths }
    guard old.st_dev == new.st_dev else { throw Refusal.differentDevices }
    try validateBundle(request.old, expectedHead: request.oldHead)
    try validateBundle(request.new, expectedHead: request.newHead)
    let currentOld = try checkedPath(request.old, type: mode_t(S_IFDIR))
    let currentNew = try checkedPath(request.new, type: mode_t(S_IFDIR))
    guard sameIdentity(old, currentOld), sameIdentity(new, currentNew) else { throw Refusal.pathChanged }

    // NOFOLLOW also rejects symlinks introduced after validation. Other concurrent
    // mutations remain outside this helper's exclusively controlled staging contract.
    let result = request.old.withCString { oldPath in
        request.new.withCString { newPath in
            renamex_np(oldPath, newPath, UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY))
        }
    }
    guard result == 0 else { throw SwapFailure(code: errno) }
}

private func refuse(_ code: String) -> Never {
    FileHandle.standardError.write(Data("bundle swap refused: \(code)\n".utf8))
    exit(1)
}

do {
    try swap(Request(Array(CommandLine.arguments.dropFirst())))
    print("bundle swap complete")
} catch let failure as Refusal {
    refuse(failure.rawValue)
} catch let failure as SwapFailure {
    refuse("rename_failed_errno_\(failure.code)")
} catch {
    refuse("validation_failed")
}
