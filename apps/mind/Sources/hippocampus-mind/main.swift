import Foundation
import MindKit

// hippocampus-mind --serve
//
// Reads one JSON request per line on stdin and writes one reply per line on
// stdout, in order. The first line written is the ready line. Exits as soon
// as stdin closes, even mid-request (`MindServer.serve`). Nothing is logged
// except content-free failures to stderr.

guard CommandLine.arguments.dropFirst().first == "--serve" else {
    FileHandle.standardError.write(Data("usage: hippocampus-mind --serve\n".utf8))
    exit(64)
}

let engine = FoundationEngine()
if engine.unavailableReason() == nil { engine.prewarm() }
await MindServer(engine: engine).serve()
