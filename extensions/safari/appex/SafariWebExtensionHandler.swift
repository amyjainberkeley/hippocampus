import Darwin
import Foundation
import SafariServices
import os.log

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let logger = Logger(
        subsystem: "ai.hippocampus.SafariExtension",
        category: "native-messaging"
    )

    private static let appGroupInfoPlistKey = "HippocampusAppGroupIdentifier"
    private static let inboxDir = "safari-inbox"
    private static let consentFilename = "capture-consent.json"

    private struct CaptureConsentState: Decodable {
        let enabled: Bool
        let generation: String?
        let ownerProcessID: Int32
        let ownerStartTimeUs: UInt64
    }

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let userInfo = item.userInfo as? [String: Any],
              let message = userInfo[SFExtensionMessageKey] as? [String: Any]
        else {
            context.completeRequest(returningItems: nil)
            return
        }

        let status: String
        if message["type"] as? String == "capture_authorization" {
            status = isCaptureAuthorized(message) ? "authorized" : "capture_disabled"
        } else {
            status = forward(message) ? "ok" : "capture_disabled"
        }

        let response = NSExtensionItem()
        response.userInfo = [
            SFExtensionMessageKey: ["status": status]
        ]
        context.completeRequest(returningItems: [response])
    }

    @discardableResult
    private func forward(_ message: [String: Any]) -> Bool {
        // Require the browser-owned tab classification to say non-private.
        // Missing or malformed state fails closed, before App Group storage.
        guard message["incognito"] as? Bool == false else {
            return false
        }

        guard let appGroupID = Self.appGroupID,
              let containerURL = FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: appGroupID
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

    private func isCaptureAuthorized(_ message: [String: Any]) -> Bool {
        guard message["incognito"] as? Bool == false,
              let appGroupID = Self.appGroupID,
              let containerURL = FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: appGroupID
              )
        else { return false }
        return authorizedGeneration(in: containerURL) != nil
    }

    private func authorizedGeneration(in containerURL: URL) -> String? {
        let stateURL = containerURL.appendingPathComponent(Self.consentFilename)
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(CaptureConsentState.self, from: data),
              state.enabled,
              let generation = state.generation,
              !generation.isEmpty,
              ownerProcessIdentityMatches(
                  state.ownerProcessID,
                  expectedStartTimeUs: state.ownerStartTimeUs
              )
        else { return nil }
        return generation
    }

    private func ownerProcessIdentityMatches(
        _ processID: Int32,
        expectedStartTimeUs: UInt64
    ) -> Bool {
        guard processID > 0, expectedStartTimeUs > 0 else { return false }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, $0, Int32(size))
        }
        guard result == Int32(size) else { return false }
        let seconds = info.pbi_start_tvsec.multipliedReportingOverflow(by: 1_000_000)
        guard !seconds.overflow else { return false }
        let total = seconds.partialValue.addingReportingOverflow(info.pbi_start_tvusec)
        return !total.overflow && total.partialValue == expectedStartTimeUs
    }

    private static var appGroupID: String? {
        guard let raw = Bundle.main.object(
            forInfoDictionaryKey: appGroupInfoPlistKey
        ) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
