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
]
for state in states {
    require(!state.shouldPulse, "Every menu-bar state must be static")
    let original = MenuBarStatusIcon.image(for: state)
    for _ in 0..<1_000 {
        require(MenuBarStatusIcon.image(for: state) === original, "Reuse rendered icon for \(state)")
    }
}
require(MenuBarStatusIcon.image(for: .error(reason: "first")) === MenuBarStatusIcon.image(for: .error(reason: "new reason")), "Reasons must not grow the image cache")
require(MenuBarStatusIcon.image(for: .blocked(reason: "first")) === MenuBarStatusIcon.image(for: .noMemory), "Shared glyphs share their cached image")
let distinct = [MenuBarStatus.idle, .recording, .paused, .error(reason: "test")]
let pixels = distinct.map { MenuBarStatusIcon.image(for: $0).tiffRepresentation! }
require(Set(pixels).count == distinct.count, "Static status glyphs remain visually distinct")
print("PASS: static menu label, 10000 cached icon reads, bounded reason-independent cache, distinct glyphs")
