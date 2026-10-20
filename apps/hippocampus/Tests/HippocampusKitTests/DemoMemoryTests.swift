// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import HippocampusKit

/// Demo Memory reaches the app in three places, and while it is off each one
/// changes nothing (SPEC-DELTA 6): children read the person's own memory,
/// the menu is the menu, and no flag ever says otherwise.
final class DemoMemoryTests: XCTestCase {
    private let dbPath = URL(fileURLWithPath: "/tmp/hippocampus-tests/mci.sqlite")

    func testItIsNeverInUseYet() {
        XCTAssertFalse(DemoMemory.isActive)
        XCTAssertEqual(DemoMemory.menuItems(optionHeld: false), [])
        XCTAssertEqual(DemoMemory.menuItems(optionHeld: true), [])
    }

    func testEveryChildReadsThePersonsOwnMemoryWhileItIsOff() {
        let base = ["SAFE_VALUE": "kept", "PATH": "/usr/bin:/bin"]
        let environment = ProcessSupervisorLaunchPlan.sanitizedEnvironment(
            baseEnvironment: base, dbPath: dbPath, keyReference: .defaultDatabaseKey
        )
        XCTAssertEqual(environment["MCI_DB_PATH"], dbPath.path)
        XCTAssertEqual(environment["SAFE_VALUE"], "kept")
        XCTAssertNil(environment[DemoMemory.windowEnvironmentKey])
        XCTAssertEqual(DemoMemory.childEnvironment(environment), environment, "nothing else changes")
    }

    func testAFlagPassedDownNeverReachesAChild() {
        let base = [DemoMemory.windowEnvironmentKey: "1"]
        for environment in [
            ProcessSupervisorLaunchPlan.sanitizedEnvironment(
                baseEnvironment: base, dbPath: dbPath, keyReference: .defaultDatabaseKey
            ),
            ProcessSupervisorLaunchPlan.recallEnvironment(
                baseEnvironment: base, dbPath: dbPath, keyReference: .defaultDatabaseKey,
                initialTab: nil, focusEventId: nil, openPopup: false, agentURL: nil
            ),
            ProcessSupervisorLaunchPlan.onboardingEnvironment(
                baseEnvironment: base, dbPath: dbPath, keyReference: .defaultDatabaseKey, initialStep: nil
            ),
        ] {
            XCTAssertNil(environment[DemoMemory.windowEnvironmentKey],
                         "the window shows its Demo tag only when Demo Memory is in use")
            XCTAssertEqual(environment["MCI_DB_PATH"], dbPath.path)
        }
    }

    func testTheWindowsFlagIsTheNameTheWindowReads() {
        // RecallUIKit's DemoMemoryMode.environmentKey; the two apps share no code.
        XCTAssertEqual(DemoMemory.windowEnvironmentKey, "MCI_DEMO_MEMORY")
    }

    func testTheAgentsLaunchPlanIsUnchangedWhileItIsOff() {
        let generation = SupervisorProcessGeneration(
            id: "generation-1", readinessURL: URL(fileURLWithPath: "/tmp/generation-1.json"), captureEnabled: true
        )
        let plan = ProcessSupervisorLaunchPlan.make(
            helperURL: URL(fileURLWithPath: "/bundle/MCICaptureHelper"),
            agentURL: URL(fileURLWithPath: "/bundle/mci-agent"),
            dbPath: dbPath, keyReference: .defaultDatabaseKey, knownSafeAppsURL: nil,
            captureEnabled: true, crashReportOptedIn: false, generation: generation,
            baseEnvironment: [DemoMemory.windowEnvironmentKey: "1"]
        )
        XCTAssertEqual(plan.agentArguments, ["--drain-stdin", "--strict", "--db-path", dbPath.path])
        XCTAssertNil(plan.agentEnvironment[DemoMemory.windowEnvironmentKey])
        XCTAssertNil(plan.helperEnvironment[DemoMemory.windowEnvironmentKey])
        XCTAssertEqual(plan.agentEnvironment["MCI_DB_PATH"], dbPath.path)
    }
}
