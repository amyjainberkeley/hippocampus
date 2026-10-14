// SPDX-License-Identifier: Apache-2.0
import Foundation

enum SupervisorStopPolicy {
    static func shouldWait(
        now: Date,
        deadline: Date,
        helperRunning: Bool,
        agentRunning: Bool
    ) -> Bool {
        now < deadline && (helperRunning || agentRunning)
    }
}
