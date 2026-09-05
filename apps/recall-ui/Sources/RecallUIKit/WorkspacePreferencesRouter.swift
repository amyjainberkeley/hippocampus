import AppKit
import Darwin
import Foundation
import os

@MainActor
public final class WorkspacePreferencesRouter {
    public static let shared = WorkspacePreferencesRouter()
    private var launchedParent: Process?

    public func open(_ destination: WorkspacePreferencesDestination, bundleURL: URL) async -> Bool {
        let running = NSWorkspace.shared.runningApplications.compactMap {
            Self.executableURL(processID: $0.processIdentifier)
        }
        let pending = launchedParent?.isRunning == true ? launchedParent?.executableURL : nil
        guard let plan = destination.routingPlan(bundleURL: bundleURL,
                                                runningExecutableURLs: running, launchedExecutableURL: pending),
              Bundle(url: bundleURL)?.executableURL?.resolvingSymlinksInPath() == plan.executable,
              FileManager.default.isExecutableFile(atPath: plan.executable.path)
        else { return false }

        let id = UUID()
        let acknowledged = OSAllocatedUnfairLock(initialState: false)
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: WorkspacePreferencesDestination.acknowledgementName,
                                          object: plan.executable.path, queue: .main) { notification in
            guard notification.userInfo?["request_id"] as? String == id.uuidString else { return }
            acknowledged.withLock { $0 = true }
        }
        defer { center.removeObserver(observer) }

        if case .launch(let executable, let arguments) = plan {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            // Do not inherit Recall's DB credentials, model overrides, or pipes.
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                                   "TMPDIR": FileManager.default.temporaryDirectory.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            launchedParent = process
        }

        // The parent may be between exec and observer installation. Only its
        // acknowledgement means the pane opened; launching alone is not success.
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if acknowledged.withLock({ $0 }) { return true }
            if Task.isCancelled { return false }
            center.postNotificationName(WorkspacePreferencesDestination.notificationName,
                                        object: plan.executable.path,
                                        userInfo: destination.notificationInfo(id: id), deliverImmediately: true)
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return acknowledged.withLock { $0 }
    }

    // Bundle IDs and Launch Services metadata are shared by both executables.
    // Ask the kernel which binary is actually running at each application PID.
    static func executableURL(processID: Int32) -> URL? {
        guard processID > 0 else { return nil }
        // proc_info.h defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN;
        // the compound macro is not imported by Swift.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)).resolvingSymlinksInPath()
    }
}
