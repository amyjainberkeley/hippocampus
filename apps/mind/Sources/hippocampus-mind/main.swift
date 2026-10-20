import Foundation
import MindKit

// Owner-only before anything is created: every file this process makes,
// Core ML's compiled-model cache included, is 0600 and every folder 0700
// (reports/e2e, finding 5).
umask(0o077)

// hippocampus-mind --serve
//
// Reads one JSON request per line on stdin and writes one reply per line on
// stdout, in order. The first line written is the ready line, once the
// engine is chosen (`EngineChoice`; a model server gets 2 s to answer).
// Exits as soon as stdin closes, even mid-request (`MindServer.serve`).
// Nothing is logged except content-free failures to stderr.

guard CommandLine.arguments.dropFirst().first == "--serve" else {
    FileHandle.standardError.write(Data("usage: hippocampus-mind --serve\n".utf8))
    exit(64)
}

let engine = await EngineChoice.engine(for: EngineSettings.load())
#if canImport(FoundationModels) && !MIND_NO_FOUNDATION_MODELS
if #available(macOS 26.0, *), let apple = engine as? FoundationEngine, apple.unavailableReason() == nil {
    apple.prewarm()
}
#endif
await MindServer(engine: engine).serve()
