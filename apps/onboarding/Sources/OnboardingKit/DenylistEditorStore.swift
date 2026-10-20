import Foundation

public protocol DenylistEditorStore: Sendable {
    func load() async
    func allEntries() async -> [DenylistEntry]
    func csoEntries() async -> [DenylistEntry]
    func userEntries() async -> [DenylistEntry]
    func addUserEntry(type: DenylistEntry.EntryType, value: String) async
    func removeUserEntry(id: String) async -> Bool
}

// MARK: - Disk-backed impl (reads security review TOML + user-deny.toml, unions both)

public actor DiskDenylistEditorStore: DenylistEditorStore {
    private let csoPath: URL
    private let userPath: URL
    private var _csoEntries: [DenylistEntry] = []
    private var _userEntries: [DenylistEntry] = []

    public init(csoPath: URL? = nil, userDirectory: URL? = nil) {
        let defaultCSO = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Applications/Hippocampus.app/Contents/Resources/denylist.toml")
        self.csoPath = csoPath ?? defaultCSO

        let dir = userDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MCI")
        self.userPath = dir.appendingPathComponent("user-deny.toml")
    }

    public func load() {
        _csoEntries = Self.parseDenylistToml(at: csoPath, source: .csoRatified)
        _userEntries = Self.parseDenylistToml(at: userPath, source: .userAdded)
    }

    public func allEntries() -> [DenylistEntry] {
        _csoEntries + _userEntries
    }

    public func csoEntries() -> [DenylistEntry] {
        _csoEntries
    }

    public func userEntries() -> [DenylistEntry] {
        _userEntries
    }

    public func addUserEntry(type: DenylistEntry.EntryType, value: String) {
        let entry = DenylistEntry(type: type, value: value, source: .userAdded)
        if _userEntries.contains(where: { $0.id == entry.id }) { return }
        _userEntries.append(entry)
        writeUserEntries()
    }

    public func removeUserEntry(id: String) -> Bool {
        let csoIds = Set(_csoEntries.map(\.id))
        if csoIds.contains(id) { return false }
        let before = _userEntries.count
        _userEntries.removeAll { $0.id == id }
        if _userEntries.count < before {
            writeUserEntries()
            return true
        }
        return false
    }

    // MARK: - Minimal TOML parser for [[entries]] array-of-tables

    static func parseDenylistToml(at url: URL, source: DenylistEntry.Source) -> [DenylistEntry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var entries: [DenylistEntry] = []
        var currentType: String?
        var currentValue: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed == "[[entries]]" {
                if let t = currentType, let v = currentValue,
                   let entryType = DenylistEntry.EntryType(rawValue: t) {
                    entries.append(DenylistEntry(type: entryType, value: v, source: source))
                }
                currentType = nil
                currentValue = nil
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            var val = parts[1].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
                val = val.replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }

            switch key {
            case "type": currentType = val
            case "value": currentValue = val
            default: break
            }
        }

        if let t = currentType, let v = currentValue,
           let entryType = DenylistEntry.EntryType(rawValue: t) {
            entries.append(DenylistEntry(type: entryType, value: v, source: source))
        }

        return entries
    }

    // MARK: - Write user entries to disk (atomic temp+replace)

    private func writeUserEntries() {
        var content = "# MCI user denylist — user-added entries (widens privacy, never relaxes)\n\n"
        for entry in _userEntries {
            content += "[[entries]]\n"
            content += "type = \"\(Self.escapeToml(entry.type.rawValue))\"\n"
            content += "value = \"\(Self.escapeToml(entry.value))\"\n\n"
        }

        let dir = userPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        // The list names the sites and apps the person keeps out, which is
        // itself private: mode 0600 from the moment the file exists
        // (storage-security review S9), never a world-readable fallback.
        try? PrivateFileWriter.write(Data(content.utf8), to: userPath)
    }

    private static func escapeToml(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Stub for tests

public actor StubDenylistEditorStore: DenylistEditorStore {
    private var _cso: [DenylistEntry]
    private var _user: [DenylistEntry]

    public init(cso: [DenylistEntry] = [], user: [DenylistEntry] = []) {
        self._cso = cso
        self._user = user
    }

    public func load() {}

    public func allEntries() -> [DenylistEntry] {
        _cso + _user
    }

    public func csoEntries() -> [DenylistEntry] {
        _cso
    }

    public func userEntries() -> [DenylistEntry] {
        _user
    }

    public func addUserEntry(type: DenylistEntry.EntryType, value: String) {
        let entry = DenylistEntry(type: type, value: value, source: .userAdded)
        if !_user.contains(where: { $0.id == entry.id }) {
            _user.append(entry)
        }
    }

    public func removeUserEntry(id: String) -> Bool {
        let csoIds = Set(_cso.map(\.id))
        if csoIds.contains(id) { return false }
        let before = _user.count
        _user.removeAll { $0.id == id }
        return _user.count < before
    }
}
