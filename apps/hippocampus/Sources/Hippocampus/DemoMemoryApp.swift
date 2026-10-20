// SPDX-License-Identifier: Apache-2.0
//
// DemoMemoryApp.swift — Demo Memory for this app (SPEC-DELTA 6).

import HippocampusKit

/// Attaches Demo Memory to this app, once at launch, before remembering
/// first starts. Connect AI Tools… always writes the person's own memory
/// into the tools' settings, so while it runs every child gets the
/// person's own memory, even while Demo Memory is in use.
@MainActor
enum DemoMemoryApp {
    static func attach(supervisor: ProcessSupervisor) {
        DemoMemory.attach(supervisor: supervisor, isConnectingAITools: { ConnectAITools.shared.isRunning })
    }
}
