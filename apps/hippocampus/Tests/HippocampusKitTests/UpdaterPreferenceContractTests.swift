import Foundation
import XCTest

final class UpdaterPreferenceContractTests: XCTestCase {
    func testDefaultsArePrivateAndConstructionDoesNotResetOwnerPreference() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil) as! [String: Any]
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(plist["SUEnableSystemProfiling"] as? Bool, false)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/HippocampusKit/Updater.swift"), encoding: .utf8)
        let initializer = try XCTUnwrap(source.range(of: "public override init()"))
        let start = try XCTUnwrap(source.range(of: "public func startUpdater()"))
        let body = source[initializer.lowerBound..<start.lowerBound]
        XCTAssertFalse(body.contains("automaticallyChecksForUpdates ="))
        XCTAssertFalse(body.contains("automaticallyDownloadsUpdates ="))
    }
}
