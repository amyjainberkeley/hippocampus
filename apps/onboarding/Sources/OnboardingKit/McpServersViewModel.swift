// SPDX-License-Identifier: TBD-private
//
// McpServersViewModel — V2-MCP-2 onboarding state for the optional
// "Connect MCP Servers" slide.
//
// Responsibilities:
//   - Load existing entries from `~/Library/Application Support/MCI/
//     mcp-servers.toml` on slide open.
//   - Pre-validate URL shape against the loopback gate (Swift mirror
//     of `core/mcp-client/src/transport/loopback.rs` for the UI tier).
//   - Persist added/removed rows; the agent re-reads on next start.
//
// The slide is OPTIONAL — Skip is supported via a no-op advance.

import Foundation

@MainActor
public final class McpServersViewModel: ObservableObject {
    @Published public private(set) var entries: [McpServerEntry] = []
    @Published public var pendingName: String = ""
    @Published public var pendingURL: String = ""
    @Published public var pendingAuthHeader: String = ""
    @Published public private(set) var lastError: McpServerEditorError?
    @Published public private(set) var lastBanner: String?
    @Published public private(set) var isLoaded: Bool = false

    private let store: any McpServersStore

    public init(store: any McpServersStore = FileMcpServersStore()) {
        self.store = store
    }

    public func load() async {
        let loaded = await store.load()
        entries = loaded
        isLoaded = true
    }

    public func addPending() async -> Bool {
        let name = pendingName.trimmingCharacters(in: .whitespaces)
        let url = pendingURL.trimmingCharacters(in: .whitespaces)
        let auth = pendingAuthHeader.trimmingCharacters(in: .whitespaces)

        if name.isEmpty {
            lastError = .emptyName
            return false
        }
        if !isValidName(name) {
            lastError = .invalidName
            return false
        }
        if entries.contains(where: { $0.name == name }) {
            lastError = .duplicateName(name)
            return false
        }
        if url.isEmpty {
            lastError = .emptyURL
            return false
        }
        if let loopbackError = McpServersViewModel.preCheckLoopbackURL(url) {
            lastError = loopbackError
            return false
        }

        let entry = McpServerEntry(
            name: name,
            url: url,
            authHeader: auth.isEmpty ? nil : auth,
            enabled: true
        )
        var updated = entries
        updated.append(entry)
        do {
            try await store.save(updated)
            entries = updated
            pendingName = ""
            pendingURL = ""
            pendingAuthHeader = ""
            lastError = nil
            lastBanner = "Added \(name). The agent will connect on next restart."
            return true
        } catch {
            lastError = .saveFailed(error.localizedDescription)
            return false
        }
    }

    public func remove(_ name: String) async {
        let updated = entries.filter { $0.name != name }
        do {
            try await store.save(updated)
            entries = updated
            lastBanner = "Removed \(name)."
            lastError = nil
        } catch {
            lastError = .saveFailed(error.localizedDescription)
        }
    }

    public func dismissBanner() {
        lastBanner = nil
    }

    public func dismissError() {
        lastError = nil
    }

    private func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-")
        }
    }

    /// Conservative loopback pre-check. Mirrors the *shape* of the
    /// Rust [`LoopbackHost::parse`] gate but does not perform DNS
    /// resolution — the agent re-validates with full DNS at load.
    /// This is a UX-tier check so the user sees a clear refusal in
    /// the slide immediately rather than after agent restart.
    public static func preCheckLoopbackURL(_ raw: String) -> McpServerEditorError? {
        guard let parsed = URLComponents(string: raw),
              let scheme = parsed.scheme?.lowercased() else {
            return .badURL
        }
        if scheme != "http" && scheme != "https" {
            return .badScheme
        }
        if parsed.user != nil || parsed.password != nil {
            return .userinfoNotAllowed
        }
        guard let host = parsed.host?.lowercased(), !host.isEmpty else {
            return .badURL
        }
        // Allow the canonical loopback hostnames literally; for any
        // other DNS name, defer to the Rust gate (a UI-tier DNS lookup
        // is not worth doing here — the agent re-checks at restart).
        // Explicitly refuse `0.0.0.0` and obvious non-loopback IPs so
        // the slide does not lie to the user.
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" {
            return nil
        }
        if host.hasPrefix("127.") {
            return nil
        }
        if host == "0.0.0.0" {
            return .nonLoopback
        }
        // IPv4 literal that is NOT 127/8 → refuse.
        if let octets = ipv4Octets(host) {
            return octets[0] == 127 ? nil : .nonLoopback
        }
        // IPv6 literal with brackets — accept only `[::1]`.
        if host.hasPrefix("[") && host.hasSuffix("]") {
            let inner = String(host.dropFirst().dropLast())
            return inner == "::1" ? nil : .nonLoopback
        }
        // Unknown DNS-style hostname (e.g. `example.com`,
        // `localhost.example.com`) — surface as a soft warning; the
        // agent's full DNS check will accept or refuse on next start.
        return .dnsUnverified
    }

    private static func ipv4Octets(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard let v = UInt8(p) else { return nil }
            out.append(v)
        }
        return out
    }
}

public enum McpServerEditorError: Sendable, Equatable {
    case emptyName
    case invalidName
    case duplicateName(String)
    case emptyURL
    case badURL
    case badScheme
    case userinfoNotAllowed
    case nonLoopback
    case dnsUnverified
    case saveFailed(String)

    public var displayMessage: String {
        switch self {
        case .emptyName:
            return "Name cannot be empty."
        case .invalidName:
            return "Name must use only letters, digits, _ or -."
        case let .duplicateName(name):
            return "\(name) is already registered."
        case .emptyURL:
            return "URL cannot be empty."
        case .badURL:
            return "URL did not parse — expected http://… or https://…"
        case .badScheme:
            return "URL must use http:// or https://"
        case .userinfoNotAllowed:
            return "URL must not embed user:password@. Use the auth header field instead."
        case .nonLoopback:
            return "URL is not loopback. Hippocampus only connects to local MCP servers (127.0.0.1, ::1, localhost)."
        case .dnsUnverified:
            return "Hostname is not a literal loopback address. The agent will refuse it on next start if it does not resolve to 127.0.0.1 / ::1."
        case let .saveFailed(msg):
            return "Could not save: \(msg)"
        }
    }
}
