import CoreGraphics
import Foundation
import ImageIO
import Vision

// Prints every line of text Apple's text recognition reads in an image, top to
// bottom. build-installer.sh --verify-assets uses it to check that the
// installer background shows only its instructions.
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: read-background-text.swift IMAGE\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    FileHandle.standardError.write(Data("could not read \(url.path)\n".utf8))
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
do {
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
} catch {
    FileHandle.standardError.write(Data("text recognition failed: \(error)\n".utf8))
    exit(1)
}
let lines = (request.results ?? [])
    .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
    .compactMap { $0.topCandidates(1).first?.string }
for line in lines {
    print(line)
}
