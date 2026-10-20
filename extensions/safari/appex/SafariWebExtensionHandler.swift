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

    /// The extension has no `main` of its own; its first code is this
    /// object's creation, before any request writes to the App Group.
    override init() {
        // Owner-only before anything is created: a staged page is 0600 and
        // the inbox 0700, as in every Hippocampus process (reports/e2e,
        // finding 5).
        umask(0o077)
        super.init()
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
        try? FileManager.default.createDirectory(
            at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        // A page staged over a minute ago is deleted unread, whether or not
        // Hippocampus ever read it (storage-security review S10).
        Self.removeStalePages(in: inbox)

        let filename = "\(ProcessInfo.processInfo.globallyUniqueString).json"
        let fileURL = inbox.appendingPathComponent(filename)

        var authorizedMessage = message
        authorizedMessage["capture_generation"] = generation
        guard let data = try? JSONSerialization.data(withJSONObject: authorizedMessage) else {
            logger.error("Failed to serialize native message")
            return false
        }

        // Mode 0600 from the moment it exists: a hidden temporary file, then
        // renamed, so Hippocampus never reads half a page.
        let temporary = inbox.appendingPathComponent(".\(filename).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            logger.error("Failed to write to App Group inbox")
            return false
        }
        let written = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if result <= 0 { return false }
                offset += result
            }
            return true
        }
        Darwin.close(descriptor)
        guard written, Darwin.rename(temporary.path, fileURL.path) == 0 else {
            Darwin.unlink(temporary.path)
            logger.error("Failed to write to App Group inbox")
            return false
        }
        return true
    }

    /// How long a staged page may wait to be forwarded.
    private static let maxStagedAge: TimeInterval = 60

    /// Deletes every staged page older than `maxStagedAge`.
    private static func removeStalePages(in inbox: URL, now: Date = Date()) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else { return }
        for file in files where file.pathExtension == "json" || file.pathExtension == "tmp" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > maxStagedAge {
                try? FileManager.default.removeItem(at: file)
            }
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
