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

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let userInfo = item.userInfo as? [String: Any],
              let message = userInfo[SFExtensionMessageKey] as? [String: Any]
        else {
            context.completeRequest(returningItems: nil)
            return
        }

        forward(message)

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["status": "ok"]]
        context.completeRequest(returningItems: [response])
    }

    private func forward(_ message: [String: Any]) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.groupID
        ) else {
            logger.error("App Group container not available")
            return
        }

        let inbox = containerURL.appendingPathComponent(Self.inboxDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        let filename = "\(ProcessInfo.processInfo.globallyUniqueString).json"
        let fileURL = inbox.appendingPathComponent(filename)

        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            logger.error("Failed to serialize native message")
            return
        }

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to write to App Group inbox: \(error.localizedDescription)")
        }
    }
}
