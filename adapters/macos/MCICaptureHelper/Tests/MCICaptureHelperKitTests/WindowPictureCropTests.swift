import CoreGraphics
import CoreVideo
import ImageIO
import XCTest
@testable import MCICaptureHelperKit

/// A picture of a window beside the one in front never shows another
/// window's pixels (SPEC 6.4): every made-up layout below is painted into a
/// synthetic display frame, one solid colour per window, and the picture is
/// decoded and searched for any colour but its own window's and the mask's.
final class WindowPictureCropTests: XCTestCase {
    /// A 1000x600-point display at the global origin, read at 2x.
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let excluded = BackgroundCapturePolicy.excludedBundleIds(userEntries: [])

    private struct RGB: Equatable {
        let r: UInt8, g: UInt8, b: UInt8
        func distance(to other: RGB) -> Int {
            abs(Int(r) - Int(other.r)) + abs(Int(g) - Int(other.g)) + abs(Int(b) - Int(other.b))
        }
    }

    private let own = RGB(r: 30, g: 90, b: 220)
    private let editor = RGB(r: 230, g: 40, b: 40)
    private let privateBrowser = RGB(r: 40, g: 200, b: 60)
    private let behind = RGB(r: 200, g: 40, b: 200)
    private let desktop = RGB(r: 20, g: 20, b: 20)
    private var mask: RGB {
        RGB(r: WindowPictureCrop.maskRGB.red, g: WindowPictureCrop.maskRGB.green, b: WindowPictureCrop.maskRGB.blue)
    }

    private func window(_ id: CGWindowID, _ bundle: String?, _ title: String?, _ rect: CGRect,
                        layer: Int = 0) -> VisibleWindow {
        VisibleWindow(windowId: id, bundleId: bundle, title: title, bounds: rect, layer: layer)
    }

    /// A frame of `pixelSize` showing `display`, the desktop and then each
    /// window painted back to front in its colour.
    private func frame(_ layout: [(VisibleWindow, RGB)], display: CGRect,
                       pixelSize: CGSize = CGSize(width: 2000, height: 1200)) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, Int(pixelSize.width), Int(pixelSize.height),
                                         kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        let sx = pixelSize.width / display.width, sy = pixelSize.height / display.height
        func paint(_ rect: CGRect, _ colour: RGB) {
            let x0 = max(0, Int(((rect.minX - display.minX) * sx).rounded(.down)))
            let x1 = min(Int(pixelSize.width), Int(((rect.maxX - display.minX) * sx).rounded(.up)))
            let y0 = max(0, Int(((rect.minY - display.minY) * sy).rounded(.down)))
            let y1 = min(Int(pixelSize.height), Int(((rect.maxY - display.minY) * sy).rounded(.up)))
            guard x1 > x0, y1 > y0 else { return }
            var pattern = UInt32(colour.b) | UInt32(colour.g) << 8 | UInt32(colour.r) << 16 | 0xFF00_0000
            for y in y0..<y1 { memset_pattern4(base + y * bytesPerRow + x0 * 4, &pattern, (x1 - x0) * 4) }
        }
        paint(display, desktop)
        for (window, colour) in layout.reversed() { paint(window.bounds, colour) }
        return pixels
    }

    /// The picture's pixels, decoded from the JPEG it would be stored as.
    private func decodedPicture(of target: VisibleWindow, in layout: [(VisibleWindow, RGB)],
                                display: CGRect? = nil, pixelSize: CGSize = CGSize(width: 2000, height: 1200))
        throws -> (pixels: [RGB], width: Int, height: Int, plan: WindowPictureCrop.Plan) {
        let display = display ?? self.display
        let windows = layout.map(\.0)
        let plan = try XCTUnwrap(WindowPictureCrop.plan(for: target, displayBounds: display, pixelSize: pixelSize,
                                                        windows: windows, excludedBundleIds: excluded))
        let buffer = frame(layout, display: display, pixelSize: pixelSize)
        let picture = try XCTUnwrap(WindowPictureCrop.render(buffer, plan: plan))
        let jpeg = try XCTUnwrap(WindowPictureCrop.jpeg(picture.image))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var pixels = [RGB]()
        pixels.reserveCapacity(w * h)
        bytes.withUnsafeBufferPointer { raw in
            var i = 0
            while i < raw.count {
                pixels.append(RGB(r: raw[i], g: raw[i + 1], b: raw[i + 2]))
                i += 4
            }
        }
        return (pixels, w, h, plan)
    }

    /// Pixels whose nearest of `palette` is `colour`, and close to it.
    /// Every pixel is looked at: a leak of one is a failure.
    private func count(_ colour: RGB, in pixels: [RGB], palette: [RGB], tolerance: Int = 90) -> Int {
        var found = 0
        for pixel in pixels {
            let own = pixel.distance(to: colour)
            guard own < tolerance else { continue }
            var nearest = true
            for other in palette where other != colour && pixel.distance(to: other) < own {
                nearest = false
                break
            }
            if nearest { found += 1 }
        }
        return found
    }

    private var palette: [RGB] { [own, editor, privateBrowser, behind, desktop, mask] }

    /// How many pixels are nearest each colour of the palette, and close to
    /// it, in one pass over every pixel.
    private func census(_ pixels: [RGB], tolerance: Int = 90) -> [Int] {
        let colours = palette
        var counts = [Int](repeating: 0, count: colours.count)
        for pixel in pixels {
            var best = 0, bestDistance = Int.max
            for (index, colour) in colours.enumerated() {
                let distance = pixel.distance(to: colour)
                if distance < bestDistance { best = index; bestDistance = distance }
            }
            if bestDistance < tolerance { counts[best] += 1 }
        }
        return counts
    }

    private func assertOnlyItsOwnPixels(_ pixels: [RGB], file: StaticString = #filePath, line: UInt = #line) {
        let counts = census(pixels)
        let byColour = Dictionary(uniqueKeysWithValues: zip(palette.map { "\($0)" }, counts))
        for foreign in [editor, privateBrowser, behind, desktop] {
            XCTAssertEqual(byColour["\(foreign)"], 0, "\(foreign)", file: file, line: line)
        }
        XCTAssertGreaterThan(byColour["\(own)"] ?? 0, pixels.count / 3, file: file, line: line)
    }

    // MARK: Masking

    func testAWindowInFrontIsMaskedOutOfTheSidePicture() throws {
        let side = window(3, "com.tinyspeck.slackmacgap", "launch", CGRect(x: 400, y: 150, width: 500, height: 400))
        let layout = [
            (window(1, "com.microsoft.VSCode", "tax.rs", CGRect(x: 100, y: 100, width: 450, height: 300)), editor),
            (side, own),
            (window(4, "com.apple.Notes", "Notes", CGRect(x: 0, y: 30, width: 1000, height: 570)), behind),
        ]
        let picture = try decodedPicture(of: side, in: layout)
        assertOnlyItsOwnPixels(picture.pixels)
        XCTAssertGreaterThan(count(mask, in: picture.pixels, palette: palette), 0)
        XCTAssertEqual(picture.plan.masks.count, 1)
        // 150 of its 500 points across and 250 of its 400 down are covered.
        XCTAssertEqual(picture.plan.visibleFraction, 1 - (150.0 * 250.0) / (500.0 * 400.0), accuracy: 0.001)
    }

    func testAPrivateBrowserWindowInFrontIsMaskedAndNeverShows() throws {
        let side = window(3, "com.apple.Notes", "Launch checklist", CGRect(x: 200, y: 100, width: 600, height: 400))
        let layout = [
            (window(2, "com.google.Chrome", "New Incognito Tab", CGRect(x: 550, y: 80, width: 300, height: 200)),
             privateBrowser),
            (side, own),
            (window(4, "com.apple.TextEdit", "Draft", CGRect(x: 0, y: 30, width: 1000, height: 570)), behind),
        ]
        let picture = try decodedPicture(of: side, in: layout)
        assertOnlyItsOwnPixels(picture.pixels)
    }

    func testSeveralOverlappingWindowsInFrontAreAllMasked() throws {
        let side = window(5, "com.figma.Desktop", "Pricing page", CGRect(x: 100, y: 60, width: 800, height: 500))
        let layout = [
            (window(1, "com.microsoft.VSCode", "tax.rs", CGRect(x: 0, y: 0, width: 300, height: 250)), editor),
            (window(2, "com.google.Chrome", "Private Browsing", CGRect(x: 700, y: 400, width: 300, height: 200)),
             privateBrowser),
            (window(3, "com.apple.Notes", "Notes", CGRect(x: 250, y: 200, width: 200, height: 120)), behind),
            (side, own),
        ]
        let picture = try decodedPicture(of: side, in: layout)
        assertOnlyItsOwnPixels(picture.pixels)
        XCTAssertEqual(picture.plan.masks.count, 3)
    }

    func testOnlyThePartOnTheDisplayBeingReadIsUsed() throws {
        // A second display to the right; the window crosses onto it.
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 600)
        let side = window(3, "com.apple.Notes", "Launch checklist", CGRect(x: 1100, y: 100, width: 1000, height: 300))
        let picture = try decodedPicture(of: side, in: [(side, own)], display: right)
        assertOnlyItsOwnPixels(picture.pixels)
        // 900 of its 1000 points are on this display: 90% of it.
        XCTAssertEqual(picture.plan.visibleFraction, 0.9, accuracy: 0.001)
        XCTAssertEqual(picture.plan.crop, CGRect(x: 200, y: 200, width: 1800, height: 600))
    }

    func testAWindowMostlyOnAnotherDisplayGetsNoPicture() {
        let side = window(3, "com.apple.Notes", "Launch checklist", CGRect(x: 800, y: 100, width: 500, height: 300))
        let plan = WindowPictureCrop.plan(for: side, displayBounds: display, pixelSize: CGSize(width: 2000, height: 1200),
                                          windows: [side], excludedBundleIds: excluded)
        XCTAssertEqual(plan?.visibleFraction ?? 1, 0.4, accuracy: 0.001)
        XCTAssertEqual(plan?.isVisibleEnough, false)
    }

    func testAMostlyCoveredWindowGetsNoPicture() {
        let side = window(3, "com.apple.Notes", "Launch checklist", CGRect(x: 100, y: 100, width: 400, height: 300))
        let front = window(1, "com.microsoft.VSCode", "tax.rs", CGRect(x: 80, y: 80, width: 300, height: 300))
        let plan = WindowPictureCrop.plan(for: side, displayBounds: display, pixelSize: CGSize(width: 2000, height: 1200),
                                          windows: [front, side], excludedBundleIds: excluded)
        XCTAssertNotNil(plan)
        XCTAssertLessThan(plan?.visibleFraction ?? 1, 0.6)
        XCTAssertEqual(plan?.isVisibleEnough, false)
    }

    func testASmallWindowGetsNoPicture() {
        let side = window(3, "com.apple.Notes", "Sticky", CGRect(x: 100, y: 100, width: 190, height: 300))
        let plan = WindowPictureCrop.plan(for: side, displayBounds: display, pixelSize: CGSize(width: 2000, height: 1200),
                                          windows: [side], excludedBundleIds: excluded)
        XCTAssertEqual(plan?.isVisibleEnough, false)
        let short = window(4, "com.apple.Notes", "Sticky", CGRect(x: 100, y: 100, width: 400, height: 110))
        XCTAssertEqual(WindowPictureCrop.plan(for: short, displayBounds: display,
                                              pixelSize: CGSize(width: 2000, height: 1200), windows: [short],
                                              excludedBundleIds: excluded)?.isVisibleEnough, false)
    }

    func testTheDocksDisplaySizedOverlayDoesNotMaskTheWholePicture() {
        // Excluded from the pixels at layer 20, it never covers anything.
        let side = window(3, "com.apple.Notes", "Launch checklist", CGRect(x: 100, y: 100, width: 600, height: 400))
        let plan = WindowPictureCrop.plan(for: side, displayBounds: display, pixelSize: CGSize(width: 2000, height: 1200),
                                          windows: [window(1, "com.apple.dock", nil, display, layer: 20), side],
                                          excludedBundleIds: excluded)
        XCTAssertEqual(plan?.masks, [])
        XCTAssertEqual(plan?.visibleFraction, 1)
    }

    func testAPasswordManagersWindowInFrontIsMaskedAllTheSame() {
        // Removed from the pixels by the filter; masked anyway, in case the
        // filter were ever behind.
        let side = window(3, "com.apple.Notes", "Launch checklist", CGRect(x: 100, y: 100, width: 600, height: 400))
        let vault = window(1, "com.1password.1password", "Vault", CGRect(x: 50, y: 50, width: 200, height: 200))
        let plan = WindowPictureCrop.plan(for: side, displayBounds: display, pixelSize: CGSize(width: 2000, height: 1200),
                                          windows: [vault, side], excludedBundleIds: excluded)
        XCTAssertEqual(plan?.masks, [CGRect(x: 0, y: 0, width: 300, height: 300)])
    }

    func testAFloatingPanelInFrontIsMasked() throws {
        let side = window(3, "com.apple.Notes", "Launch checklist", CGRect(x: 100, y: 100, width: 600, height: 400))
        let panel = window(1, "com.apple.QuickTimePlayerX", nil, CGRect(x: 500, y: 350, width: 300, height: 200), layer: 3)
        let picture = try decodedPicture(of: side, in: [(panel, editor), (side, own)])
        assertOnlyItsOwnPixels(picture.pixels)
    }

    func testFractionalScalesNeverLeakAnEdge() throws {
        // A 5K display read at 3840 pixels: 1.333 pixels a point.
        let side = window(3, "com.apple.Notes", "Launch checklist", CGRect(x: 101, y: 103, width: 499, height: 301))
        let layout = [
            (window(1, "com.microsoft.VSCode", "tax.rs", CGRect(x: 333, y: 211, width: 101, height: 77)), editor),
            (side, own),
            (window(4, "com.apple.TextEdit", "Draft", CGRect(x: 0, y: 30, width: 1000, height: 570)), behind),
        ]
        let picture = try decodedPicture(of: side, in: layout, pixelSize: CGSize(width: 1333, height: 800))
        assertOnlyItsOwnPixels(picture.pixels)
    }

    func testTheCornersOutsideARoundedWindowAreMasked() throws {
        let side = window(3, "com.apple.Notes", "Launch checklist", CGRect(x: 100, y: 100, width: 600, height: 400))
        let picture = try decodedPicture(of: side, in: [(side, own)])
        // The very corner pixel is the mask's, the middle is the window's.
        let corner = picture.pixels[0]
        let middle = picture.pixels[(picture.height / 2) * picture.width + picture.width / 2]
        XCTAssertLessThan(corner.distance(to: mask), 30)
        XCTAssertLessThan(middle.distance(to: own), 30)
    }

    // MARK: Size, format and metadata

    func testThePictureIsAtMost1600PixelsOnItsLongEdge() throws {
        let side = window(3, "com.apple.Notes", "Launch checklist", CGRect(x: 0, y: 0, width: 1000, height: 600))
        let picture = try decodedPicture(of: side, in: [(side, own)])
        XCTAssertEqual(max(picture.width, picture.height), 1600)
        XCTAssertEqual(picture.width, 1600)
        XCTAssertEqual(picture.height, 960)
    }

    func testTheJPEGCarriesNoMetadata() throws {
        let side = window(3, "com.apple.Notes", "Launch checklist", CGRect(x: 100, y: 100, width: 300, height: 200))
        let buffer = frame([(side, own)], display: display)
        let plan = try XCTUnwrap(WindowPictureCrop.plan(for: side, displayBounds: display,
                                                        pixelSize: CGSize(width: 2000, height: 1200),
                                                        windows: [side], excludedBundleIds: excluded))
        let picture = try XCTUnwrap(WindowPictureCrop.render(buffer, plan: plan))
        let jpeg = try XCTUnwrap(WindowPictureCrop.jpeg(picture.image))
        let bytes = [UInt8](jpeg)
        XCTAssertEqual(Array(bytes.prefix(2)), [0xFF, 0xD8])
        var offset = 2, markers: [UInt8] = []
        while offset + 4 <= bytes.count, bytes[offset] == 0xFF, bytes[offset + 1] != 0xDA {
            markers.append(bytes[offset + 1])
            offset += 2 + (Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]))
        }
        XCTAssertFalse(markers.isEmpty)
        XCTAssertTrue(markers.allSatisfy { !(0xE1...0xEF).contains($0) && $0 != 0xFE }, "\(markers)")
        let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(jpeg as CFData, nil)!, 0, nil)
            as? [CFString: Any]
        XCTAssertNil(properties?[kCGImagePropertyExifDictionary])
        XCTAssertNil(properties?[kCGImagePropertyTIFFDictionary])
        XCTAssertNil(properties?[kCGImagePropertyGPSDictionary])
    }

    func testMetadataSegmentsAreRemovedFromAnyJPEG() {
        let app1: [UInt8] = [0xFF, 0xE1, 0x00, 0x06, 0x45, 0x78, 0x69, 0x66]
        let comment: [UInt8] = [0xFF, 0xFE, 0x00, 0x04, 0x68, 0x69]
        let app0: [UInt8] = [0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46]
        let scan: [UInt8] = [0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9]
        let input = Data([0xFF, 0xD8] + app0 + app1 + comment + scan)
        XCTAssertEqual(WindowPictureCrop.withoutMetadata(input), Data([0xFF, 0xD8] + app0 + scan))
        XCTAssertNil(WindowPictureCrop.withoutMetadata(Data([0x00, 0x01, 0x02, 0x03, 0x04])))
    }

    // MARK: One colour and dHash

    func testABlackWindowIsAlmostOneColour() throws {
        let side = window(3, "com.apple.TV", "Movie", CGRect(x: 100, y: 100, width: 600, height: 400))
        let black = RGB(r: 0, g: 0, b: 0)
        let buffer = frame([(side, black)], display: display)
        let plan = try XCTUnwrap(WindowPictureCrop.plan(for: side, displayBounds: display,
                                                        pixelSize: CGSize(width: 2000, height: 1200),
                                                        windows: [side], excludedBundleIds: excluded))
        XCTAssertEqual(WindowPictureCrop.render(buffer, plan: plan)?.nearlyOneColour, true)
    }

    func testAWindowWithTextIsNotOneColourAndChangesItsHash() throws {
        let side = window(3, "com.apple.Notes", "Launch checklist", CGRect(x: 100, y: 100, width: 600, height: 400))
        let plan = try XCTUnwrap(WindowPictureCrop.plan(for: side, displayBounds: display,
                                                        pixelSize: CGSize(width: 2000, height: 1200),
                                                        windows: [side], excludedBundleIds: excluded))
        /// A white page with dark columns in every other ninth of it.
        func page(darkColumns parity: Int) -> [(VisibleWindow, RGB)] {
            var layout: [(VisibleWindow, RGB)] = (0..<9).filter { $0 % 2 == parity }.map { column in
                (window(CGWindowID(100 + column), "x", nil,
                        CGRect(x: 100 + CGFloat(column) * 600 / 9 + 8, y: 140, width: 600 / 9 - 16, height: 320)),
                 RGB(r: 20, g: 20, b: 20))
            }
            layout.append((side, RGB(r: 250, g: 250, b: 250)))
            return layout
        }
        let first = try XCTUnwrap(WindowPictureCrop.render(frame(page(darkColumns: 0), display: display), plan: plan))
        XCTAssertFalse(first.nearlyOneColour)
        let second = try XCTUnwrap(WindowPictureCrop.render(frame(page(darkColumns: 1), display: display), plan: plan))
        XCTAssertGreaterThanOrEqual(first.dhash.distance(to: second.dhash), 12)
        let again = try XCTUnwrap(WindowPictureCrop.render(frame(page(darkColumns: 0), display: display), plan: plan))
        XCTAssertEqual(first.dhash, again.dhash)
    }

    func testMakingAPictureOfAFullDisplayIsCheap() throws {
        // A 4K frame, the largest the whole-screen stream reads, with a
        // window covering part of it. SPEC 6.9 budgets about 10 ms in a
        // release build; a debug test only guards against a slow path.
        let big = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let side = window(3, "com.apple.Notes", "Launch checklist", big)
        let front = window(1, "com.microsoft.VSCode", "tax.rs", CGRect(x: 200, y: 200, width: 800, height: 500))
        let buffer = frame([(front, editor), (side, own)], display: big, pixelSize: CGSize(width: 3840, height: 2160))
        let plan = try XCTUnwrap(WindowPictureCrop.plan(for: side, displayBounds: big,
                                                        pixelSize: CGSize(width: 3840, height: 2160),
                                                        windows: [front, side], excludedBundleIds: excluded))
        let started = Date()
        let picture = try XCTUnwrap(WindowPictureCrop.render(buffer, plan: plan))
        XCTAssertNotNil(WindowPictureCrop.jpeg(picture.image))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testAWindowNotInTheListOrOffTheDisplayHasNoPlan() {
        let side = window(3, "com.apple.Notes", "Launch checklist", CGRect(x: 100, y: 100, width: 600, height: 400))
        XCTAssertNil(WindowPictureCrop.plan(for: side, displayBounds: display, pixelSize: CGSize(width: 2000, height: 1200),
                                            windows: [], excludedBundleIds: excluded))
        let away = window(3, "com.apple.Notes", "Launch checklist", CGRect(x: 1200, y: 100, width: 600, height: 400))
        XCTAssertNil(WindowPictureCrop.plan(for: away, displayBounds: display, pixelSize: CGSize(width: 2000, height: 1200),
                                            windows: [away], excludedBundleIds: excluded))
    }
}
