// Apple Vision OCR probe for the screen benchmark. Development only.
//
//   swiftc -O -o vision-probe tools/ocr/screens/VisionProbe.swift
//   vision-probe text|document IMAGE
//
// Prints {"seconds": s, "lines": [{"text", "confidence", "box": [x, y, w, h]}]}
// with boxes normalized and the origin at the bottom left, the shape the
// helper's recognizers use. `text` mirrors the helper's VNRecognizeTextRequest
// settings; `document` uses RecognizeDocumentsRequest (macOS 26), whose
// paragraphs come back in reading order.
import Foundation
import Vision

struct Line: Encodable {
    let text: String
    let confidence: Float
    let box: [Double]
}

struct Reply: Encodable {
    let seconds: Double
    let lines: [Line]
}

func box(_ rect: CGRect) -> [Double] {
    [rect.origin.x, rect.origin.y, rect.width, rect.height].map { Double($0) }
}

func recognizeText(_ url: URL) throws -> [Line] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    request.automaticallyDetectsLanguage = true
    try VNImageRequestHandler(url: url).perform([request])
    return (request.results ?? []).compactMap { observation in
        guard let top = observation.topCandidates(1).first else { return nil }
        return Line(text: top.string, confidence: top.confidence, box: box(observation.boundingBox))
    }
}

@available(macOS 26.0, *)
func recognizeDocument(_ url: URL) async throws -> [Line] {
    let request = RecognizeDocumentsRequest()
    let observations = try await request.perform(on: url)
    var out: [Line] = []
    for observation in observations {
        for paragraph in observation.document.paragraphs {
            for line in paragraph.lines {
                out.append(Line(
                    text: line.transcript, confidence: 1,
                    box: box(line.boundingRegion.boundingBox.cgRect)))
            }
        }
    }
    return out
}

@main
struct VisionProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            FileHandle.standardError.write(Data("usage: vision-probe text|document IMAGE\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: args[2])
        let start = Date()
        let lines: [Line]
        switch args[1] {
        case "text":
            lines = try recognizeText(url)
        case "document":
            guard #available(macOS 26.0, *) else {
                FileHandle.standardError.write(Data("document mode needs macOS 26\n".utf8))
                exit(2)
            }
            lines = try await recognizeDocument(url)
        default:
            exit(2)
        }
        let reply = Reply(seconds: Date().timeIntervalSince(start), lines: lines)
        FileHandle.standardOutput.write(try JSONEncoder().encode(reply))
    }
}
