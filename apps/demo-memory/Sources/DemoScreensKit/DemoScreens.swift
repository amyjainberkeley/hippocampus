// SPDX-License-Identifier: Apache-2.0
//
// DemoScreens.swift — draw each screen of the list, and seal it the way the
// capture helper seals a screenshot.

import AppKit
import Foundation
import MCIKeyframeCodec

/// Draws the screenshots of Demo Memory's made-up week. Every word on them
/// is from the screen list; every pixel is drawn here.
@MainActor
public enum DemoScreens {
    /// A window the size of a 14-inch MacBook's screen, in points.
    public static let size = CGSize(width: 1440, height: 900)
    /// Drawn at 2x, as the helper keeps a Retina window.
    public static let scale: CGFloat = 2
    /// The helper's JPEG quality (`KeyframeBlobEncoder`).
    public static let jpegQuality: CGFloat = 0.88

    public enum DrawError: Error, Equatable {
        case unknownTemplate(String)
        case drawingFailed(String)
    }

    /// The drawings this tool knows.
    public static let templates = ["editor", "terminal", "browser", "slack", "zoom", "notion", "figma", "calendar"]

    /// The screen, drawn, as the bitmap it would be on screen.
    public static func bitmap(_ spec: DemoScreenSpec) throws -> NSBitmapImageRep {
        guard templates.contains(spec.template) else { throw DrawError.unknownTemplate(spec.template) }
        let pixelsWide = Int(size.width * scale)
        let pixelsHigh = Int(size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
            let base = NSGraphicsContext(bitmapImageRep: rep)
        else { throw DrawError.drawingFailed(spec.id) }
        let cg = base.cgContext
        // Points, top-left origin, at 2x. The bitmap says its size in points
        // once drawn, so it reads as a Retina picture.
        defer { rep.size = NSSize(width: size.width, height: size.height) }
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let canvas = Canvas(size: size)
        canvas.fill(canvas.bounds, .white)
        switch spec.template {
        case "editor": EditorScreen(spec: spec, canvas: canvas).draw()
        case "terminal": TerminalScreen(spec: spec, canvas: canvas).draw()
        case "browser": BrowserScreen(spec: spec, canvas: canvas).draw()
        case "slack": SlackScreen(spec: spec, canvas: canvas).draw()
        case "zoom": ZoomScreen(spec: spec, canvas: canvas).draw()
        case "notion": NotionScreen(spec: spec, canvas: canvas).draw()
        case "figma": FigmaScreen(spec: spec, canvas: canvas).draw()
        default: CalendarScreen(spec: spec, canvas: canvas).draw()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The screen as the capture helper keeps it: a JPEG of the window.
    public static func jpeg(_ spec: DemoScreenSpec) throws -> Data {
        let rep = try bitmap(spec)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
        else { throw DrawError.drawingFailed(spec.id) }
        return data
    }

    /// The screen as a PNG, to look at while working on the drawings.
    public static func png(_ spec: DemoScreenSpec) throws -> Data {
        guard let data = try bitmap(spec).representation(using: .png, properties: [:])
        else { throw DrawError.drawingFailed(spec.id) }
        return data
    }

    /// Draw every screen of `list`, seal each with `key` (the memory's
    /// 32-byte key, as the helper seals with it) into `blobRoot` as
    /// `<sha256 of the sealed bytes>.bin`, readable by this user only, and
    /// return the manifest. With `pngFolder`, each drawing is also written
    /// there as `<id>.png`, unsealed, for review only.
    public static func make(
        _ list: DemoScreenList, key: Data, blobRoot: URL, pngFolder: URL? = nil
    ) throws -> DemoScreenManifest {
        try FileManager.default.createDirectory(at: blobRoot, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if let pngFolder {
            try FileManager.default.createDirectory(at: pngFolder, withIntermediateDirectories: true)
        }
        var digests: [String: String] = [:]
        for spec in list.screens {
            let image = try jpeg(spec)
            let sealed = try KeyframeBlobCodec.seal(plaintext: image, keyMaterial: key)
            let url = blobRoot.appendingPathComponent(sealed.lowercaseHexDigest).appendingPathExtension("bin")
            try sealed.bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            digests[spec.id] = sealed.lowercaseHexDigest
            if let pngFolder {
                try png(spec).write(to: pngFolder.appendingPathComponent("\(spec.id).png"), options: .atomic)
            }
        }
        return DemoScreenManifest(screens: digests)
    }
}

extension DemoScreenSpec {
    /// The screen's text, one line at a time.
    var mainLines: [String] { main.components(separatedBy: "\n") }
}
