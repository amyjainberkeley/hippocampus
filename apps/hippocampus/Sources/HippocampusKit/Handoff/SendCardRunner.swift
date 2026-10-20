// SPDX-License-Identifier: Apache-2.0
//
// SendCardRunner.swift — the Ask panel's way to the one builder
// (`mci-agent send-card`, SPEC 5.3.10) and to what Working On and Web Pages
// list (`mci-agent work`), so the panel finds items and pages as you type.
// The request goes on standard input, never in arguments, so a question
// never shows in the process list. Nothing here sends anything: a card is a
// link to open or text to copy, and the person presses send in the tool.

import Darwin
import Foundation

/// What to hand to which tool, as `send-card` reads it.
public struct SendCardRequest: Encodable, Equatable, Sendable {
    public struct Session: Encodable, Equatable, Sendable {
        public var startUs: UInt64
        public var endUs: UInt64
        public var title: String?

        public init(startUs: UInt64, endUs: UInt64, title: String?) {
            self.startUs = startUs
            self.endUs = endUs
            self.title = title
        }

        enum CodingKeys: String, CodingKey {
            case startUs = "start_us", endUs = "end_us", title
        }
    }

    public var to: String
    public var question: String?
    public var moments: [UInt64]
    public var selected: UInt64?
    public var session: Session?
    public var item: String?
    public var includeAboutMe: Bool
    public var includeScreenshot: Bool
    public var appInstalled: Bool?
    public var full: Bool

    public init(
        to: String, question: String? = nil, moments: [UInt64] = [], selected: UInt64? = nil,
        session: Session? = nil, item: String? = nil, includeAboutMe: Bool = false,
        includeScreenshot: Bool = false, appInstalled: Bool? = nil, full: Bool = false
    ) {
        self.to = to
        self.question = question
        self.moments = moments
        self.selected = selected
        self.session = session
        self.item = item
        self.includeAboutMe = includeAboutMe
        self.includeScreenshot = includeScreenshot
        self.appInstalled = appInstalled
        self.full = full
    }

    enum CodingKeys: String, CodingKey {
        case to, question, moments, selected, session, item, full
        case includeAboutMe = "include_about_me"
        case includeScreenshot = "include_screenshot"
        case appInstalled = "app_installed"
    }
}

/// What goes in the tool's message box, and how it gets there.
public struct SendCard: Decodable, Equatable, Sendable {
    public struct LeftOut: Decodable, Equatable, Sendable {
        public var forgotten = 0
        public var keptOut = 0
        public var secretLines = 0
        public var trimmedMoments = 0

        public init(forgotten: Int = 0, keptOut: Int = 0, secretLines: Int = 0, trimmedMoments: Int = 0) {
            self.forgotten = forgotten
            self.keptOut = keptOut
            self.secretLines = secretLines
            self.trimmedMoments = trimmedMoments
        }

        enum CodingKeys: String, CodingKey {
            case forgotten, keptOut = "kept_out", secretLines = "secret_lines", trimmedMoments = "trimmed_moments"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            forgotten = try c.decodeIfPresent(Int.self, forKey: .forgotten) ?? 0
            keptOut = try c.decodeIfPresent(Int.self, forKey: .keptOut) ?? 0
            secretLines = try c.decodeIfPresent(Int.self, forKey: .secretLines) ?? 0
            trimmedMoments = try c.decodeIfPresent(Int.self, forKey: .trimmedMoments) ?? 0
        }
    }

    public var message: String
    public var words: Int
    public var open: String?
    public var copy: Bool
    public var folder: String?
    public var included: [UInt64]
    public var leftOut: LeftOut
    public var shortened: Bool
    public var peopleMessages: Bool
    public var screenshotMoment: UInt64?

    public init(
        message: String, words: Int, open: String?, copy: Bool, folder: String? = nil, included: [UInt64],
        leftOut: LeftOut = LeftOut(), shortened: Bool = false, peopleMessages: Bool = false,
        screenshotMoment: UInt64? = nil
    ) {
        self.message = message
        self.words = words
        self.open = open
        self.copy = copy
        self.folder = folder
        self.included = included
        self.leftOut = leftOut
        self.shortened = shortened
        self.peopleMessages = peopleMessages
        self.screenshotMoment = screenshotMoment
    }

    enum CodingKeys: String, CodingKey {
        case message, words, open, copy, folder, included, shortened
        case leftOut = "left_out", peopleMessages = "people_messages", screenshotMoment = "screenshot_moment"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decode(String.self, forKey: .message)
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        open = try c.decodeIfPresent(String.self, forKey: .open)
        copy = try c.decodeIfPresent(Bool.self, forKey: .copy) ?? true
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        included = try c.decodeIfPresent([UInt64].self, forKey: .included) ?? []
        leftOut = try c.decodeIfPresent(LeftOut.self, forKey: .leftOut) ?? LeftOut()
        shortened = try c.decodeIfPresent(Bool.self, forKey: .shortened) ?? false
        peopleMessages = try c.decodeIfPresent(Bool.self, forKey: .peopleMessages) ?? false
        screenshotMoment = try c.decodeIfPresent(UInt64.self, forKey: .screenshotMoment)
    }
}

/// A Working On item, as `mci-agent work` lists it: only what the panel
/// shows and finds by.
public struct PanelItem: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var name: String
    public var apps: [String]
    public var lastUs: UInt64
    public var folderGuess: String?
    public var moments: [UInt64]

    public init(id: String, kind: String, name: String, apps: [String], lastUs: UInt64,
                folderGuess: String? = nil, moments: [UInt64]) {
        self.id = id
        self.kind = kind
        self.name = name
        self.apps = apps
        self.lastUs = lastUs
        self.folderGuess = folderGuess
        self.moments = moments
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, apps, moments
        case lastUs = "last_us", folderGuess = "folder_guess"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "document"
        name = try c.decode(String.self, forKey: .name)
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
        lastUs = try c.decodeIfPresent(UInt64.self, forKey: .lastUs) ?? 0
        folderGuess = try c.decodeIfPresent(String.self, forKey: .folderGuess)
        moments = try c.decodeIfPresent([UInt64].self, forKey: .moments) ?? []
    }
}

/// A page Web Pages lists.
public struct PanelPage: Decodable, Equatable, Sendable, Identifiable {
    public var title: String
    public var host: String?
    /// Its path, without the query and fragment.
    public var path: String?
    public var app: String
    public var days: Int
    public var lastUs: UInt64
    public var moments: [UInt64]
    public var id: String { "\(app)|\(host ?? "")|\(title)|\(moments.first ?? 0)" }

    /// Its address, when its host is known: what ↩ opens.
    public var url: URL? {
        guard let host, !host.isEmpty else { return nil }
        return URL(string: "https://\(host)\(path ?? "/")")
    }

    public init(title: String, host: String?, path: String? = nil, app: String, days: Int, lastUs: UInt64,
                moments: [UInt64]) {
        self.title = title
        self.host = host
        self.path = path
        self.app = app
        self.days = days
        self.lastUs = lastUs
        self.moments = moments
    }

    enum CodingKeys: String, CodingKey {
        case title, host, path, app, days, moments
        case lastUs = "last_us"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        days = try c.decodeIfPresent(Int.self, forKey: .days) ?? 1
        lastUs = try c.decodeIfPresent(UInt64.self, forKey: .lastUs) ?? 0
        moments = try c.decodeIfPresent([UInt64].self, forKey: .moments) ?? []
    }
}

/// What Working On and Web Pages list.
public struct PanelWork: Decodable, Equatable, Sendable {
    public var items: [PanelItem]
    public var pages: [PanelPage]

    public init(items: [PanelItem] = [], pages: [PanelPage] = []) {
        self.items = items
        self.pages = pages
    }

    enum CodingKeys: String, CodingKey { case items, pages }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([PanelItem].self, forKey: .items)) ?? []
        pages = (try? c.decodeIfPresent([PanelPage].self, forKey: .pages)) ?? []
    }
}

public enum SendCardError: Error, Equatable, Sendable {
    /// Part of Hippocampus is missing or couldn't start.
    case unavailable
    /// The memory couldn't be opened (its key, after a password change).
    case locked
    case timedOut
    case failed
}

/// The agent's reads the panel uses. A protocol so the panel is tested with
/// fixtures and drawn without memory.
public protocol PanelAgent: Sendable {
    func card(_ request: SendCardRequest) async throws -> SendCard
    func work() async throws -> PanelWork
}

/// The real agent, run as a child with the memory's path and its Keychain
/// reference only, bounded in time, and stopped when the panel moves on.
public struct AgentProcess: PanelAgent {
    public let executable: URL
    public let environment: [String: String]
    public var timeout: Duration = .seconds(15)
    /// How far back Working On's items and Web Pages' pages are read.
    public var workDays = 30

    public init(executable: URL, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    public func card(_ request: SendCardRequest) async throws -> SendCard {
        let body = try JSONEncoder().encode(request)
        let data = try await run(["send-card", "--json"], input: body)
        guard let card = try? JSONDecoder().decode(SendCard.self, from: data) else { throw SendCardError.failed }
        return card
    }

    public func work() async throws -> PanelWork {
        let data = try await run(["work", "--json", "--days", String(workDays)], input: nil)
        guard let work = try? JSONDecoder().decode(PanelWork.self, from: data) else { throw SendCardError.failed }
        return work
    }

    /// Runs the agent with `arguments` and `input` on standard input; its
    /// standard output. Cancelling the task stops the child.
    func run(_ arguments: [String], input: Data?) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw SendCardError.unavailable }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw SendCardError.unavailable
        }
        let reader = Task.detached(priority: .userInitiated) {
            stdout.fileHandleForReading.readDataToEndOfFile()
        }
        if let input {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
        }
        try? stdin.fileHandleForWriting.close()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(15))
        }
        if process.isRunning {
            process.terminate()
            let grace = clock.now.advanced(by: .milliseconds(250))
            while process.isRunning, clock.now < grace {
                try? await Task.sleep(for: .milliseconds(15))
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = await reader.value
            if Task.isCancelled { throw CancellationError() }
            throw SendCardError.timedOut
        }
        let output = await reader.value
        try Task.checkCancellation()
        switch process.terminationStatus {
        case 0: return output
        // The key couldn't be read or the memory opened.
        case 10, 11, 12: throw SendCardError.locked
        default: throw SendCardError.failed
        }
    }
}

/// No agent at all: the panel drawn from fixtures, and tests.
public struct NoPanelAgent: PanelAgent {
    public init() {}
    public func card(_ request: SendCardRequest) async throws -> SendCard { throw SendCardError.unavailable }
    public func work() async throws -> PanelWork { PanelWork() }
}
