import Foundation
import MindKit

// hippocampus-mind --serve
//
// Reads one JSON request per line on stdin and writes one reply per line on
// stdout, in order. The first line written is the ready line. Exits when stdin
// closes. Nothing is logged except content-free failures to stderr.

guard CommandLine.arguments.dropFirst().first == "--serve" else {
    FileHandle.standardError.write(Data("usage: hippocampus-mind --serve\n".utf8))
    exit(64)
}

let engine = FoundationEngine()
let server = MindServer(engine: engine)
if engine.unavailableReason() == nil { engine.prewarm() }

func emit(_ data: Data) {
    FileHandle.standardOutput.write(data)
}

emit(server.readyLine())

// Top-level code runs on the main actor; awaiting here (rather than blocking
// the main thread while a Task reads) keeps the loop free to run.
do {
    for try await line in FileHandle.standardInput.bytes.lines {
        guard !line.isEmpty else { continue }
        emit(await server.handle(Data(line.utf8)))
    }
} catch {
    FileHandle.standardError.write(Data("hippocampus-mind: input closed with an error\n".utf8))
}
