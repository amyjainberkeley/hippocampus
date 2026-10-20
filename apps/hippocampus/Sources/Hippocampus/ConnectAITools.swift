// SPDX-License-Identifier: Apache-2.0
//
// ConnectAITools.swift — "Connect AI Tools…" does the whole job in one step
// (RULINGS S4, product critique 5, SPEC 5.4): it asks whether the AI tools it
// finds may look things up in your memory, naming them (and ChatGPT's
// desktop app, which reads Codex's settings), connects them only on
// Connect, asks the session-start question, and ends on "Connected. Restart
// {tool}." Every word is in `AIToolsCopy` and `HandoffCopy`, where tests pin
// them.

import AppKit
import HippocampusKit

@MainActor
final class ConnectAITools {
    static let shared = ConnectAITools()

    private(set) var isRunning = false

    /// `done` receives the tools that are connected now.
    func run(supervisor: ProcessSupervisor, done: @escaping (Set<AITool>) -> Void = { _ in }) {
        guard !isRunning else { return }
        guard let agent = supervisor.agentBinaryPath else {
            show(title: "Couldn’t connect AI tools",
                 message: AIToolConnectorError.agentUnavailable.errorDescription ?? "")
            done([])
            return
        }
        isRunning = true
        let environment = supervisor.sanitizedChildEnvironment()
        let dbURL = supervisor.dbPath
        Task { [weak self] in
            defer { self?.isRunning = false }
            let connector = AIToolConnector(agentURL: agent, baseEnvironment: environment)
            // The tools found, named in the question; an older agent that
            // can't say is asked about both.
            let found = (try? await connector.clients()).map { states in
                AITool.allCases.filter { states[$0]?.installed == true }
            } ?? AITool.allCases
            guard !found.isEmpty else {
                let result = AIToolsCopy.result(AIToolReport(outcomes: [.claudeCode: .notInstalled, .codex: .notInstalled]))
                self?.show(title: result.title, message: result.message)
                done([])
                return
            }
            let chatGPT = DestinationDetector.live().installed().contains { $0.tool == .chatgpt }
            guard self?.askToConnect(found, chatGPTInstalled: chatGPT) == true else {
                done([])
                return
            }
            let report: AIToolReport
            do {
                report = try await AIToolConnector(agentURL: agent, baseEnvironment: environment).connect()
            } catch {
                self?.show(title: "Couldn’t connect AI tools", message: Self.message(for: error))
                done([])
                return
            }
            let connected = report.tools(.connected)
            let sessionErrors = self?.offerSessionStart(for: connected, dbURL: dbURL) ?? []
            let result = AIToolsCopy.result(report, sessionErrors: sessionErrors)
            self?.show(title: result.title, message: result.message)
            done(Set(connected))
        }
    }

    /// The one question, for the connected tools that do not start their
    /// sessions with your recent work yet. Returns what went wrong.
    private func offerSessionStart(for tools: [AITool], dbURL: URL) -> [String] {
        guard let installer = try? SessionContextInstaller.forApp(
            executableURL: Bundle.main.executableURL, dbURL: dbURL
        ) else { return [] }
        let asking = tools.filter { (try? installer.status(for: $0)) == .notConfigured }
        guard !asking.isEmpty, ask(asking) else { return [] }
        return asking.compactMap { tool in
            do {
                try installer.setEnabled(true, for: tool)
                return nil
            } catch {
                return (error as? SessionContextInstallError)?.errorDescription
                    ?? "Couldn’t change \(tool.name)’s settings. Try again."
            }
        }
    }

    /// "Let Claude Code and Codex look things up in your memory?" Nothing is
    /// connected without Connect.
    private func askToConnect(_ tools: [AITool], chatGPTInstalled: Bool) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = AIToolsCopy.connectTitle(tools)
        alert.informativeText = AIToolsCopy.connectMessage(tools, chatGPTInstalled: chatGPTInstalled)
        alert.addButton(withTitle: HandoffCopy.connect)
        alert.addButton(withTitle: HandoffCopy.notNow)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func ask(_ tools: [AITool]) -> Bool {
        // A menu-bar app's alert opens behind other apps unless it is
        // active first (critique-shell-engineering 9).
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = AIToolsCopy.questionTitle
        alert.informativeText = AIToolsCopy.questionMessage(tools)
        alert.addButton(withTitle: AIToolsCopy.share)
        alert.addButton(withTitle: AIToolsCopy.dontShare)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func show(title: String, message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = title.hasPrefix("Couldn") ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func message(for error: Error) -> String {
        (error as? AIToolConnectorError)?.errorDescription
            ?? AIToolConnectorError.launchFailed.errorDescription ?? ""
    }
}
