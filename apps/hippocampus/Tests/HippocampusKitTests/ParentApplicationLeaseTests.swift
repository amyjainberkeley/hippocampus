import Foundation
import XCTest
@testable import HippocampusKit

final class ParentApplicationLeaseTests: XCTestCase {
    func testLeaseRejectsDuplicateAndReleasesOnOwnerExit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = URL(fileURLWithPath: "/test/Hippocampus.app/Contents/MacOS/Hippocampus")
        var first = try ParentApplicationLease.acquire(executableURL: executable, directory: directory)
        XCTAssertNotNil(first)
        XCTAssertNil(try ParentApplicationLease.acquire(executableURL: executable, directory: directory))
        withExtendedLifetime(first) {}
        first = nil
        XCTAssertNotNil(try ParentApplicationLease.acquire(executableURL: executable, directory: directory))
    }

    func testSeparateInstalledBundlesHaveSeparateLeases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try ParentApplicationLease.acquire(
            executableURL: URL(fileURLWithPath: "/test/Hippocampus.app/Contents/MacOS/Hippocampus"), directory: directory)
        let second = try ParentApplicationLease.acquire(
            executableURL: URL(fileURLWithPath: "/test/Backup.app/Contents/MacOS/Hippocampus"), directory: directory)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        withExtendedLifetime((first, second)) {}
    }

    func testLeaseRejectsSymlinkInsteadOfFollowingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = URL(fileURLWithPath: "/test/Hippocampus.app/Contents/MacOS/Hippocampus")
        let lease = try ParentApplicationLease.acquire(executableURL: executable, directory: directory)
        let lock = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: directory.appendingPathComponent("missing"))
        XCTAssertThrowsError(try ParentApplicationLease.acquire(executableURL: executable, directory: directory))
        withExtendedLifetime(lease) {}
    }
}
