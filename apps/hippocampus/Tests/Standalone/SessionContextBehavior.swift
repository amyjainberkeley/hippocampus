import Foundation
import Darwin

func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

func expectRefusal(_ operation: () throws -> Void) {
    do {
        try operation()
        fatalError("Expected a refusal")
    } catch {}
}

let sandbox = FileManager.default.temporaryDirectory
    .appendingPathComponent("session-context-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: sandbox) }
let executable = sandbox.appendingPathComponent("App's $(touch bad) folder/Hippocampus")
let installer = SessionContextInstaller(
    homeURL: sandbox, executableURL: executable,
    dbURL: sandbox.appendingPathComponent("brain.sqlite")
)
let settings = installer.claudeSettingsURL
try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
let original = Data(#"{"theme":"dark","permissions":{"deny":["Bash(rm *)"]},"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"echo user-hook"}]}],"Stop":[{"hooks":[]}]}}"#.utf8)
try original.write(to: settings)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
check(try installer.claudeStatus() == .notConfigured, "No synthetic configured status")
print("Testing Claude settings merge")
fflush(nil)
try installer.setClaudeEnabled(true)
let installed = try Data(contentsOf: settings)
let decoded = try JSONSerialization.jsonObject(with: installed) as! [String: Any]
let hooks = decoded["hooks"] as! [String: Any]
let starts = hooks["SessionStart"] as! [[String: Any]]
check(starts.count == 2 && decoded["theme"] as? String == "dark", "Preserve unrelated settings")
check(starts[0]["matcher"] as? String == "startup", "Preserve user hooks")
check(try installer.claudeStatus() == .configured, "Configuration is not delivery")
try installer.setClaudeEnabled(true)
check(try Data(contentsOf: settings) == installed, "Idempotent installation")
let handler = (starts[1]["hooks"] as! [[String: Any]])[0]
check(handler["command"] as? String == installer.claudeCommand, "Fixed quoted executable")
check(!(String(data: installed, encoding: .utf8)!.contains("KEY_HEX")), "No serialized secret keys")
let mode = try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as! NSNumber
check(mode.intValue == 0o600, "Private settings remain private")
try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("#!/bin/sh\nprintf '%s\\n' \"$1\" \"$2\" \"$3\"\n".utf8).write(to: executable)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
let commandCheck = Process()
commandCheck.executableURL = URL(fileURLWithPath: "/bin/sh")
commandCheck.arguments = ["-c", installer.claudeCommand]
commandCheck.currentDirectoryURL = sandbox
let commandOutput = Pipe()
commandCheck.standardOutput = commandOutput
try commandCheck.run()
commandCheck.waitUntilExit()
let commandText = String(decoding: commandOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
check(commandCheck.terminationStatus == 0 && commandText == "--claude-session-context\n--db-path\n\(installer.dbURL.path)\n", "Shell quoting preserves all fixed arguments")
check(!FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("bad").path), "Quoted app path cannot execute substitutions")
try installer.setClaudeEnabled(false)
let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! NSDictionary
check(restored == (try JSONSerialization.jsonObject(with: original) as! NSDictionary), "Remove only our hook")
try installer.setClaudeEnabled(true)
var changed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
changed["disableAllHooks"] = true
try JSONSerialization.data(withJSONObject: changed).write(to: settings)
check(try installer.claudeStatus() == .disabledByClient, "Disabled hooks are not active")
try installer.setClaudeEnabled(false)
check((try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any])["disableAllHooks"] as? Bool == true, "Removal preserves client disable switch")
try Data("{bad json".utf8).write(to: settings)
expectRefusal { try installer.setClaudeEnabled(true) }
check(try Data(contentsOf: settings) == Data("{bad json".utf8), "Malformed file untouched")
try Data(#"{"disableAllHooks":true}"#.utf8).write(to: settings)
expectRefusal { try installer.setClaudeEnabled(true) }
try FileManager.default.removeItem(at: settings)
let victim = sandbox.appendingPathComponent("victim")
try original.write(to: victim)
try FileManager.default.linkItem(at: victim, to: settings)
expectRefusal { try installer.setClaudeEnabled(true) }
try FileManager.default.removeItem(at: settings)
try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: victim)
expectRefusal { try installer.setClaudeEnabled(true) }
check(try Data(contentsOf: victim) == original, "Symlink target untouched")
try FileManager.default.removeItem(at: settings)

let agents = installer.codexInstructionsURL
print("Testing Codex instructions merge")
fflush(nil)
try FileManager.default.createDirectory(at: agents.deletingLastPathComponent(), withIntermediateDirectories: true)
let userInstructions = "# User instructions\n\nKeep my settings.\n"
try Data(userInstructions.utf8).write(to: agents)
try installer.setCodexEnabled(true)
let firstInstructions = try Data(contentsOf: agents)
try installer.setCodexEnabled(true)
check(try Data(contentsOf: agents) == firstInstructions, "Codex instruction merge idempotent")
check(try installer.codexStatus() == .configured, "Only claim instructions configured")
try Data("Override".utf8).write(to: installer.codexOverrideURL)
check(try installer.codexStatus() == .overridden, "Report shadowing override")
expectRefusal { try installer.setCodexEnabled(true) }
try installer.setCodexEnabled(false)
check(try String(contentsOf: agents, encoding: .utf8) == userInstructions, "Restore exact user instructions")
try FileManager.default.removeItem(at: installer.codexOverrideURL)
try installer.setCodexEnabled(true)
let modifiedInstructions = try String(contentsOf: agents, encoding: .utf8)
    .replacingOccurrences(of: "max_tokens 1000", with: "max_tokens 999")
try Data(modifiedInstructions.utf8).write(to: agents)
expectRefusal { try installer.setCodexEnabled(false) }
check(try String(contentsOf: agents, encoding: .utf8) == modifiedInstructions, "Do not overwrite edited app block")

let agent = sandbox.appendingPathComponent("fake-agent")
print("Testing bounded local retrieval")
fflush(nil)
@MainActor
func stub(_ script: String) throws {
    try Data(("#!/bin/sh\n" + script).utf8).write(to: agent)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
}
let hostileFocus = "$(touch injected);'quoted'"
let hostileCWD = "/tmp/" + hostileFocus
let input = try JSONSerialization.data(withJSONObject: [
    "hook_event_name": "SessionStart", "source": "resume", "cwd": hostileCWD,
    "transcript_path": "/never/read/this"
])
let request = try SessionContextHook.request(from: input)
check(request.cwd == hostileCWD, "cwd is parsed as data, not shell")
check(try SessionContextHook.arguments(dbURL: installer.dbURL, request: request, homeURL: sandbox).suffix(2) == ["--focus", hostileFocus], "Only the last project component is one focus argument")
let focusCases: [(String, String?)] = [
    ("/Users/amy/hippo-work/hippocampus-v1", "hippocampus-v1"),
    ("/Users/amy/My Project/./", "My Project"),
    ("/Users/amy/My Project/nested/..", "My Project"),
    ("/Users/amy", nil), ("/Users/amy/./", nil), ("/", nil), ("////", nil),
    ("/Users/amy-not-home", "amy-not-home"),
    ("/Users/amy/--options;$(touch injected)", "--options;$(touch injected)"),
]
for (cwd, expected) in focusCases {
    let arguments = try SessionContextHook.arguments(
        dbURL: installer.dbURL, request: .init(cwd: cwd), homeURL: URL(fileURLWithPath: "/Users/amy")
    )
    if let expected {
        check(arguments.suffix(2) == ["--focus", expected], "Project focus: \(cwd)")
    } else {
        check(!arguments.contains("--focus") && arguments.count == 9, "Recent context only at home/root")
    }
}
expectRefusal {
    _ = try SessionContextHook.arguments(dbURL: installer.dbURL, request: .init(cwd: "/projects/   "), homeURL: sandbox)
}
expectRefusal { _ = try SessionContextHook.request(from: Data(#"{"hook_event_name":"Stop","source":"resume","cwd":"/tmp"}"#.utf8)) }
expectRefusal { _ = try SessionContextHook.request(from: Data(repeating: 65, count: 65_537)) }
for source in ["startup", "resume", "clear", "compact"] {
    _ = try SessionContextHook.request(from: JSONSerialization.data(withJSONObject: [
        "hook_event_name": "SessionStart", "source": source, "cwd": "/tmp"
    ]))
}
try stub("""
test "${11}" = \(SessionContextInstaller.shellQuote(hostileFocus)) || exit 1
test -z "${MCI_DB_KEY_HEX+x}${ANTHROPIC_API_KEY+x}${OPENAI_API_KEY+x}${MCI_DB_PATH+x}" || exit 2
test "$MCI_DB_KEYCHAIN_SERVICE" = ai.hippocampus.brain || exit 3
printf '# Hippocampus context\\nTruth status: grounded\\n- Saved observation [event 42]\\n## Sources\\n- [event 42] timestamp_us=42\\n'
""")
let output = SessionContextHook.response(input: input, agentURL: agent, dbURL: installer.dbURL, homeURL: sandbox)
let response = try JSONSerialization.jsonObject(with: output) as! [String: Any]
let context = (response["hookSpecificOutput"] as! [String: Any])["additionalContext"] as! String
check(context.contains("[event 42] timestamp_us=42"), "Preserve citations")
check(!FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("injected").path), "No cwd execution")
let calls = sandbox.appendingPathComponent("retrieval-calls")
let countCall = "printf 'call\\n' >> \(SessionContextInstaller.shellQuote(calls.path))\n"
try stub(countCall + "printf 'PRIVATE DIAGNOSTIC' >&2\nexit 13\n")
let failure = String(decoding: SessionContextHook.response(input: input, agentURL: agent, dbURL: installer.dbURL, homeURL: sandbox), as: UTF8.self)
check(failure.contains("unavailable") && !failure.contains("PRIVATE"), "Fail open with content-free diagnostic")
check(try String(contentsOf: calls, encoding: .utf8) == "call\n", "Project failure must not retry without focus")
try Data().write(to: calls)
try stub(countCall + "printf '# Hippocampus context\\nTruth status: empty\\nNo relevant local memory was available within this packet limits.\\n'\n")
let empty = String(decoding: SessionContextHook.response(input: input, agentURL: agent, dbURL: installer.dbURL, homeURL: sandbox), as: UTF8.self)
check(empty.contains("No relevant local memory"), "Empty stays empty")
check(try String(contentsOf: calls, encoding: .utf8) == "call\n", "Empty project result must not retry without focus")
try stub("test \"$#\" -eq 9 || exit 1\nprintf '# Hippocampus context\\nTruth status: observed\\nRecent local observation [event 7]\\n'\n")
for cwd in [sandbox.path, "/"] {
    let input = try JSONSerialization.data(withJSONObject: [
        "hook_event_name": "SessionStart", "source": "startup", "cwd": cwd
    ])
    let recent = SessionContextHook.response(input: input, agentURL: agent, dbURL: installer.dbURL, homeURL: sandbox)
    check(String(decoding: recent, as: UTF8.self).contains("Recent local observation [event 7]"), "Home/root response uses supplied home and no focus")
}
try stub("/usr/bin/yes x | /usr/bin/head -c 20000\n")
let oversized = String(decoding: SessionContextHook.response(input: input, agentURL: agent, dbURL: installer.dbURL, homeURL: sandbox), as: UTF8.self)
check(oversized.contains("limit") && !oversized.contains("xxx"), "Never sever citations by truncating a packet")
try stub("trap '' TERM\nwhile :; do :; done\n")
let before = Date()
let timeout = String(decoding: SessionContextHook.response(input: input, agentURL: agent, dbURL: installer.dbURL, homeURL: sandbox, timeout: 0.15), as: UTF8.self)
check(Date().timeIntervalSince(before) < 2 && timeout.contains("unavailable"), "Bound unresponsive child")
print("PASS: session context config, privacy, argument safety, truth states, and timeout")
