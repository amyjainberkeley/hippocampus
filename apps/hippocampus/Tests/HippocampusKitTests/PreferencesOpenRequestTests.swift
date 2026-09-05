import Foundation
import XCTest
@testable import HippocampusKit

final class PreferencesOpenRequestTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/Applications/Hippocampus.app/Contents/MacOS/Hippocampus")

    func testCommandLineAcceptsOnlyOneCanonicalPaneArgument() {
        for section in PreferencesSection.allCases {
            XCTAssertEqual(PreferencesOpenRequest(arguments: ["--open-preferences", section.rawValue.lowercased()])?.section, section)
        }
        for args in [[], ["--open-preferences"], ["--open-preferences", "Sources"],
                     ["--open-preferences", "sources", "--enable-capture"],
                     ["--open-preferences", "capture?enabled=1"], ["--other", "sources"]] {
            XCTAssertNil(PreferencesOpenRequest(arguments: args), "\(args)")
        }
    }

    func testNotificationMustTargetThisExecutableAndContainOnlyTypedNavigation() {
        let request = PreferencesOpenRequest(section: .sources)
        let good = Notification(name: PreferencesOpenRequest.notificationName,
                                object: executable.path, userInfo: request.userInfo)
        XCTAssertEqual(PreferencesOpenRequest(notification: good, executableURL: executable), request)
        for wrongObject in [nil, "/Applications/Hippocampus Backup.app/Contents/MacOS/Hippocampus", "ai.hippocampus"] as [String?] {
            XCTAssertNil(PreferencesOpenRequest(notification: Notification(
                name: good.name, object: wrongObject, userInfo: good.userInfo), executableURL: executable))
        }
        for badInfo in [["section": "sources"], ["section": "Sources", "request_id": request.id.uuidString],
                        ["section": "sources", "request_id": "not-a-uuid"],
                        ["section": "sources", "request_id": request.id.uuidString, "enable_capture": "true"]] {
            XCTAssertNil(PreferencesOpenRequest(notification: Notification(
                name: good.name, object: executable.path, userInfo: badInfo), executableURL: executable))
        }
        XCTAssertNil(PreferencesOpenRequest(notification: Notification(
            name: Notification.Name("unrelated"), object: executable.path,
            userInfo: request.userInfo), executableURL: executable))
    }

    func testWireContractMatchesRecallWithoutLinkingItsDatabaseLibrary() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let recall = try String(contentsOf: root.appendingPathComponent(
            "recall-ui/Sources/RecallUIKit/WorkspacePreferences.swift"), encoding: .utf8)
        for value in [PreferencesOpenRequest.flag, PreferencesOpenRequest.notificationName.rawValue,
                      PreferencesOpenRequest.acknowledgementName.rawValue, "request_id", "section"] {
            XCTAssertTrue(recall.contains("\"\(value)\""), value)
        }
    }

    func testDistributedRequestAndAcknowledgementRoundTripWithoutOpeningAnApp() {
        let center = DistributedNotificationCenter.default()
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let request = PreferencesOpenRequest(section: .privacy)
        let delivered = expectation(description: "Acknowledged typed pane request")
        let receiver = center.addObserver(forName: PreferencesOpenRequest.notificationName,
                                          object: target.path, queue: .main) { notification in
            guard let received = PreferencesOpenRequest(notification: notification, executableURL: target) else { return }
            XCTAssertEqual(received.section, .privacy)
            received.acknowledge(from: target)
        }
        let acknowledgement = center.addObserver(forName: PreferencesOpenRequest.acknowledgementName,
                                                 object: target.path, queue: .main) { notification in
            guard notification.userInfo?["request_id"] as? String == request.id.uuidString else { return }
            delivered.fulfill()
        }
        defer {
            center.removeObserver(receiver)
            center.removeObserver(acknowledgement)
        }
        request.post(to: target)
        wait(for: [delivered], timeout: 3)
    }
}
