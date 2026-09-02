import Darwin
import Foundation
import SafariServices
import os.log

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let logger = Logger(
        subsystem: "ai.hippocampus.SafariExtension",
        category: "native-messaging"
    )

    private static let groupID = "group.ai.hippocampus"
    private static let inboxDir = "safari-inbox"
    private static let consentFilename = "capture-consent.json"

    private struct CaptureConsentState: Decodable {
        let enabled: Bool
        let generation: String?
        let ownerProcessID: Int32
    }

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let userInfo = item.userInfo as? [String: Any],
              let message = userInfo[SFExtensionMessageKey] as? [String: Any]
        else {
            context.completeRequest(returningItems: nil)
            return
        }

        let forwarded = forward(message)

        let response = NSExtensionItem()
        response.userInfo = [
            SFExtensionMessageKey: ["status": forwarded ? "ok" : "capture_disabled"]
        ]
        context.completeRequest(returningItems: [response])
    }

    @discardableResult
    private func forward(_ message: [String: Any]) -> Bool {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.groupID
        ) else {
            logger.error("App Group container not available")
            return false
        }

        guard let generation = authorizedGeneration(in: containerURL) else {
            return false
        }

        let inbox = containerURL.appendingPathComponent(Self.inboxDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        let filename = "\(ProcessInfo.processInfo.globallyUniqueString).json"
        let fileURL = inbox.appendingPathComponent(filename)

        var authorizedMessage = message
        authorizedMessage["capture_generation"] = generation
        guard let data = try? JSONSerialization.data(withJSONObject: authorizedMessage) else {
            logger.error("Failed to serialize native message")
            return false
        }

        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            logger.error("Failed to write to App Group inbox: \(error.localizedDescription)")
            return false
        }
    }

    private func authorizedGeneration(in containerURL: URL) -> String? {
        let stateURL = containerURL.appendingPathComponent(Self.consentFilename)
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(CaptureConsentState.self, from: data),
              state.enabled,
              let generation = state.generation,
              !generation.isEmpty,
              ownerProcessIsAlive(state.ownerProcessID)
        else { return nil }
        return generation
    }

    private func ownerProcessIsAlive(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }
}
