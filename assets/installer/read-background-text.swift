import CoreGraphics
import Foundation
import ImageIO
import Vision

// Prints every line of text Apple's text recognition reads in an image, top to
// bottom. build-installer.sh --verify-assets uses it to check that the
// installer background shows only its instructions.
//
// With --boxes, each line is a JSON object with the text and where it sits, in
// points from the top left (the image's dpi over 72 gives its scale), the way
// Finder measures icon positions. The layout tests use it to keep every word
// clear of the icons and their names.
var arguments = Array(CommandLine.arguments.dropFirst())
let boxes = arguments.first == "--boxes"
if boxes { arguments.removeFirst() }
guard arguments.count == 1 else {
    FileHandle.standardError.write(Data("usage: read-background-text.swift [--boxes] IMAGE\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: arguments[0])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    FileHandle.standardError.write(Data("could not read \(url.path)\n".utf8))
    exit(1)
}
let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
let scale = ((properties?[kCGImagePropertyDPIWidth] as? Double) ?? 72) / 72

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
do {
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
} catch {
    FileHandle.standardError.write(Data("text recognition failed: \(error)\n".utf8))
    exit(1)
}
let observations = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
for observation in observations {
    guard let text = observation.topCandidates(1).first?.string else { continue }
    guard boxes else {
        print(text)
        continue
    }
    let width = Double(image.width) / scale
    let height = Double(image.height) / scale
    let box = observation.boundingBox
    let line: [String: Any] = [
        "text": text,
        "x": Double(box.minX) * width, "y": (1 - Double(box.maxY)) * height,
        "width": Double(box.width) * width, "height": Double(box.height) * height,
    ]
    let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
