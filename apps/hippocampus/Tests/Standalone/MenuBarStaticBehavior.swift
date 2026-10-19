import AppKit
import Foundation

func require(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
for scheduledWork in ["TimelineView(", ".animation(", ".repeatForever(", ".periodic("] {
    require(!source.contains(scheduledWork), "Menu-bar label must not schedule perpetual rendering: \(scheduledWork)")
}
let states: [MenuBarStatus] = [
    .idle, .starting, .recording, .paused, .error(reason: "first"),
    .needsPermission(.screenRecording), .blocked(reason: "first"),
    .stale(reason: "first"), .noMemory, .unchanged,
    .skipping(reason: "secure_input"), .skipping(reason: "private_browsing"), .stopFailed(reason: "first"),
    .turnOnFailed(reason: "first"),
]
for state in states {
    require(!state.shouldPulse, "Every menu-bar state must be static")
    let original = MenuBarStatusIcon.image(for: state)
    for _ in 0..<1_000 {
        require(MenuBarStatusIcon.image(for: state) === original, "Reuse rendered icon for \(state)")
    }
}
require(MenuBarStatusIcon.image(for: .error(reason: "first")) === MenuBarStatusIcon.image(for: .error(reason: "new reason")), "Reasons must not grow the image cache")
require(MenuBarStatusIcon.image(for: .blocked(reason: "first")) === MenuBarStatusIcon.image(for: .stale(reason: "first")), "Shared pictures share their cached image")
require(MenuBarStatusIcon.image(for: .starting) === MenuBarStatusIcon.image(for: .recording), "Starting shows the solid dot")
require(MenuBarStatusIcon.image(for: .starting) !== MenuBarStatusIcon.image(for: .paused), "Starting never shows the paused picture")
require(MenuBarStatusIcon.image(for: .skipping(reason: "private_browsing")) === MenuBarStatusIcon.image(for: .recording), "A skip other than a password field keeps the solid dot")
require(MenuBarStatusIcon.image(for: .skipping(reason: "secure_input")) !== MenuBarStatusIcon.image(for: .recording), "A password field shows the hollow dot")
let pictures = HiMark.State.allCases.map { MenuBarStatusIcon.image(for: $0).tiffRepresentation! }
require(Set(pictures).count == HiMark.State.allCases.count, "The four pictures remain visually distinct")
require(MenuBarStatusIcon.image(for: .turnOnFailed(reason: "first")) === MenuBarStatusIcon.image(for: .error(reason: "first")), "A turn-on that did not take shows h!")
print("PASS: static menu label, \(states.count * 1_000) cached icon reads, bounded reason-independent cache, four distinct pictures")
