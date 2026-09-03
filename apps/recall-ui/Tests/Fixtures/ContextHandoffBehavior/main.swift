import Darwin
import Foundation
import RecallUIKit

@main
struct ContextHandoffBehavior {
    static func main() async {
        do {
            let echo = ContextHandoffCommand(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["bounded context"]
            )
            let output = try await ContextHandoffExporter.run(
                command: echo,
                timeoutSeconds: 1
            )
            guard output.trimmingCharacters(in: .whitespacesAndNewlines) == "bounded context" else {
                fail("fast command output was not preserved")
            }

            let sleep = ContextHandoffCommand(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"]
            )
            let started = Date()
            do {
                _ = try await ContextHandoffExporter.run(
                    command: sleep,
                    timeoutSeconds: 0.05
                )
                fail("sleep command unexpectedly completed")
            } catch ContextHandoffError.timedOut {
                guard Date().timeIntervalSince(started) < 1 else {
                    fail("timed-out child was not terminated promptly")
                }
            }

            print("context handoff behavior: PASS")
        } catch {
            fail("unexpected error: \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("context handoff behavior: FAIL: \(message)\n".utf8))
        Darwin.exit(1)
    }
}
