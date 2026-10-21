// SPDX-License-Identifier: Apache-2.0
//
// Consent is the click on Start Remembering. Its only record is the file
// `~/Library/Application Support/MCI/.onboarding-complete`, which the app
// watches before it starts remembering (`OnboardingSentinel` in
// HippocampusKit holds the same path; onboarding does not link that kit).
//
// The file's second line carries the "Open Hippocampus at login" choice:
//
//     onboarding-completed-at 2026-10-12T21:05:00Z
//     open-at-login yes
//
// The app registers the login item only when it reads `open-at-login yes`,
// so no launch turns it on without the person's say.

import Foundation

public protocol OnboardingConsentStore: Sendable {
    var isGiven: Bool { get }
    /// Record consent with the open-at-login choice. Does nothing when
    /// consent already exists, so running setup again never rewrites the
    /// first answer.
    func give(openAtLogin: Bool) throws
}

public struct FileOnboardingConsentStore: OnboardingConsentStore {
    public static let defaultURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MCI/.onboarding-complete")

    private let url: URL
    private let now: @Sendable () -> Date

    public init(
        url: URL = FileOnboardingConsentStore.defaultURL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.url = url
        self.now = now
    }

    public var isGiven: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func give(openAtLogin: Bool) throws {
        if isGiven { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Written to a private temporary file and renamed, so the app never
        // reads half a file when the directory watch fires, and the file is
        // mode 0600 from the moment it exists (storage-security review S9).
        try PrivateFileWriter.write(Data(Self.body(at: now(), openAtLogin: openAtLogin).utf8), to: url)
    }

    public static func body(at date: Date, openAtLogin: Bool) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        return "onboarding-completed-at \(stamp)\nopen-at-login \(openAtLogin ? "yes" : "no")\n"
    }
}

/// For tests and previews: consent that lives only in memory, with a write
/// that can be made to fail.
public final class InMemoryOnboardingConsentStore: OnboardingConsentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var given: Bool
    private var choice: Bool?
    private var writes = 0
    private var error: (any Error)?

    public init(given: Bool = false) {
        self.given = given
    }

    public var isGiven: Bool { lock.withLock { given } }
    /// The open-at-login choice of the write that gave consent.
    public var openAtLogin: Bool? { lock.withLock { choice } }
    /// Calls to `give` that wrote consent.
    public var writeCount: Int { lock.withLock { writes } }

    /// Make the next writes throw, as a full disk would.
    public func failWrites(with error: any Error) {
        lock.withLock { self.error = error }
    }

    public func give(openAtLogin: Bool) throws {
        try lock.withLock {
            if given { return }
            if let error { throw error }
            given = true
            choice = openAtLogin
            writes += 1
        }
    }
}
