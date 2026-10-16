import Accelerate
import CoreGraphics
import CoreVideo
import Foundation

/// One read's pane edges, found from the region's pixels alone: where the
/// region divides into panes, and, once the text boxes are known, the
/// separators the reading order cuts at.
struct PaneLayout {
    /// The whole pixels the edges were found in, normalized to the frame.
    let region: CGRect
    let width: Int
    let height: Int
    let edges: [PaneSeparators.Edge]

    /// The thinnest pane worth a pass of its own, in pixels.
    static let paneMinimum: CGFloat = 24

    init?(input: OCREngineInput) {
        guard let (gray, region) = PaneSeparators.gray(input.pixelBuffer, roi: input.roi) else { return nil }
        // As the worker decides: a capture that declares 144 dpi or more is
        // Retina, and so is any frame 2560 pixels or more on a side.
        let retina = PaddleOCRImage.pixelsPerMeter(pixelsPerPoint: input.pixelsPerPoint) >= 5669
        self.region = region
        width = gray.width
        height = gray.height
        edges = PaneSeparators.edges(gray, half: retina || max(gray.width, gray.height) >= PaneSeparators.halfSide)
    }

    /// The edges no line crosses, in the frame's normalized space with a
    /// bottom-left origin, as `OCRResult.separators` carries them.
    func separators(crossing lines: [OCRLine]) -> [CGRect] {
        let w = CGFloat(width), h = CGFloat(height)
        let boxes = lines.map { line -> CGRect in
            let b = line.boundingBox
            let x0 = (b.minX - region.minX) / region.width * w, x1 = (b.maxX - region.minX) / region.width * w
            let y0 = (region.maxY - b.maxY) / region.height * h, y1 = (region.maxY - b.minY) / region.height * h
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        return PaneSeparators.separators(edges, boxes: boxes, width: width, height: height).map { s in
            CGRect(x: region.minX + s.minX * region.width, y: region.minY + s.minY * region.height,
                   width: s.width * region.width, height: s.height * region.height)
        }
    }

    /// One region per pane, normalized to the frame, each inside `roi`.
    func regions(within roi: CGRect) -> [CGRect] {
        let w = CGFloat(width), h = CGFloat(height)
        return PaneSeparators.panes(edges, width: width, height: height, minimum: Self.paneMinimum).compactMap { pane in
            let rect = CGRect(x: region.minX + pane.minX / w * region.width,
                              y: region.minY + (h - pane.maxY) / h * region.height,
                              width: pane.width / w * region.width,
                              height: pane.height / h * region.height).intersection(roi)
            return rect.isNull || rect.width <= 0 || rect.height <= 0 ? nil : rect
        }
    }
}

/// Where a window divides into panes. App windows divide their panes with a
/// hairline or a change of background, and either is a long straight edge.
/// Text never makes an edge longer than a line is tall, and never crosses a
/// pane boundary, so the long edges that no text box crosses are where the
/// window divides. `OCRReadingOrder` cuts the reading there first.
///
/// A port of the OCR worker's `pane_separators` (`tools/ocr/worker.py`):
/// `PaneSeparatorsTests` holds it to the worker's own output, and on the 21
/// screens of the bench the two agree on every separator. Grey levels come
/// from vImage with OpenCV's fixed-point weights, and a Retina frame (or any
/// frame 2560 pixels or more on a side) is examined at half size, averaged
/// two by two as OpenCV's area resize does.
///
/// Geometry only: no text, and nothing is kept after the call.
enum PaneSeparators {
    /// Grey levels between neighbouring pixels that make an edge.
    static let step: UInt8 = 5
    /// Pixels of interruption an edge survives, at the analysed scale.
    static let breakPixels = 3
    /// A vertical separator runs this share of the frame's height,
    static let minimumVertical = 0.22
    /// a horizontal one this share of its width.
    static let minimumHorizontal = 0.30
    /// Neighbouring edge positions within this many pixels are one separator.
    static let merge = 4
    /// A box crosses a separator when it reaches this far past it.
    static let pad: CGFloat = 2.0
    static let maximum = 64
    /// Frames this large or larger are examined at half size.
    static let halfSide = 2560

    /// A long straight edge in a region's pixels, top-left origin, at full
    /// scale: `at` is the x of a vertical edge or the y of a horizontal one,
    /// `start` and `end` the span along it.
    struct Edge: Equatable, Sendable {
        let vertical: Bool
        let at: CGFloat
        let start: CGFloat
        let end: CGFloat

        var length: CGFloat { end - start }
    }

    /// A planar grey image, row-major, top row first.
    struct Gray {
        let width: Int
        let height: Int
        var pixels: [UInt8]

        subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }

        /// The same image turned so that rows become columns.
        func transposed() -> Gray {
            var out = [UInt8](repeating: 0, count: pixels.count)
            pixels.withUnsafeBufferPointer { source in
                out.withUnsafeMutableBufferPointer { target in
                    for y in 0..<height {
                        let row = y * width
                        for x in 0..<width { target[x * height + y] = source[row + x] }
                    }
                }
            }
            return Gray(width: height, height: width, pixels: out)
        }

        /// Half size, each pixel the rounded mean of a two-by-two block, as
        /// OpenCV's area resize computes an exact halving. An odd last row or
        /// column is dropped.
        func halved() -> Gray {
            let w = width / 2, h = height / 2
            var out = [UInt8](repeating: 0, count: w * h)
            pixels.withUnsafeBufferPointer { source in
                out.withUnsafeMutableBufferPointer { target in
                    for y in 0..<h {
                        let top = 2 * y * width, bottom = top + width
                        for x in 0..<w {
                            let sum = Int(source[top + 2 * x]) + Int(source[top + 2 * x + 1])
                                + Int(source[bottom + 2 * x]) + Int(source[bottom + 2 * x + 1])
                            target[y * w + x] = UInt8((sum + 2) >> 2)
                        }
                    }
                }
            }
            return Gray(width: w, height: h, pixels: out)
        }
    }

    // MARK: - Pixels

    /// The whole pixels of a BGRA buffer inside `roi` (normalized, bottom-left
    /// origin), cropped inward as `PaddleOCRImage` crops them, in grey; and
    /// the region those pixels cover, normalized. Nil for any other format.
    static func gray(_ buffer: CVPixelBuffer, roi: CGRect) -> (gray: Gray, region: CGRect)? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              roi.minX.isFinite, roi.minY.isFinite, roi.width.isFinite, roi.height.isFinite,
              roi.width > 0, roi.height > 0, CGRect(x: 0, y: 0, width: 1, height: 1).contains(roi)
        else { return nil }
        let fullW = CVPixelBufferGetWidth(buffer), fullH = CVPixelBufferGetHeight(buffer)
        let x0 = Int(ceil(roi.minX * CGFloat(fullW))), x1 = Int(floor(roi.maxX * CGFloat(fullW)))
        let y0 = Int(ceil((1 - roi.maxY) * CGFloat(fullH))), y1 = Int(floor((1 - roi.minY) * CGFloat(fullH)))
        let w = x1 - x0, h = y1 - y0
        guard w > 0, h > 0, CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard rowBytes >= fullW * 4 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        let status = pixels.withUnsafeMutableBytes { target -> vImage_Error in
            var source = vImage_Buffer(data: base.advanced(by: y0 * rowBytes + x0 * 4), height: vImagePixelCount(h),
                                       width: vImagePixelCount(w), rowBytes: rowBytes)
            var destination = vImage_Buffer(data: target.baseAddress, height: vImagePixelCount(h),
                                            width: vImagePixelCount(w), rowBytes: w)
            // OpenCV's BGR to grey: (1868 B + 9617 G + 4899 R + 8192) >> 14.
            let weights: [Int16] = [1868, 9617, 4899, 0]
            return vImageMatrixMultiply_ARGB8888ToPlanar8(&source, &destination, weights, 16384, nil, 8192,
                                                          vImage_Flags(kvImageNoFlags))
        }
        guard status == kvImageNoError else { return nil }
        let region = CGRect(x: CGFloat(x0) / CGFloat(fullW), y: CGFloat(fullH - y1) / CGFloat(fullH),
                            width: CGFloat(w) / CGFloat(fullW), height: CGFloat(h) / CGFloat(fullH))
        return (Gray(width: w, height: h, pixels: pixels), region)
    }

    // MARK: - Edges

    /// Every long edge of a grey region, before any text is known, at full
    /// scale. `half` examines it at half size.
    static func edges(_ gray: Gray, half: Bool) -> [Edge] {
        let width = gray.width, height = gray.height
        guard width >= 8, height >= 8 else { return [] }
        var small = gray
        var scale: CGFloat = 1
        if half, min(width, height) >= 64 {
            small = gray.halved()
            scale = CGFloat(width) / CGFloat(width / 2)
        }
        let yScale = CGFloat(height) / CGFloat(small.height)
        var out: [Edge] = []
        for line in edgeLines(small, minimum: minimumVertical * Double(small.height)) {
            out.append(Edge(vertical: true, at: CGFloat(line.at) * scale,
                            start: CGFloat(line.start) * yScale, end: CGFloat(line.end) * yScale))
        }
        for line in edgeLines(small.transposed(), minimum: minimumHorizontal * Double(small.width)) {
            out.append(Edge(vertical: false, at: CGFloat(line.at) * yScale,
                            start: CGFloat(line.start) * scale, end: CGFloat(line.end) * scale))
        }
        return out
    }

    /// Vertical edges running at least `minimum` pixels, as (x, top, bottom),
    /// x being the pixel boundary the edge lies on.
    static func edgeLines(_ gray: Gray, minimum: Double) -> [(at: Int, start: Int, end: Int)] {
        let width = gray.width - 1, height = gray.height
        guard width > 0, height > 0 else { return [] }
        // Where neighbouring grey levels differ by `step` or more.
        var steps = [UInt8](repeating: 0, count: width * height)
        gray.pixels.withUnsafeBufferPointer { source in
            steps.withUnsafeMutableBufferPointer { target in
                for y in 0..<height {
                    let row = y * gray.width
                    for x in 0..<width {
                        let a = source[row + x], b = source[row + x + 1]
                        target[y * width + x] = (a > b ? a - b : b - a) >= step ? 1 : 0
                    }
                }
            }
        }
        let closed = closeColumns(steps, width: width, height: height)
        // The longest run down each column (the first, of equal ones), found
        // row by row so memory is read in order.
        var run = [Int](repeating: 0, count: width), best = run, bestEnd = run, count = run
        closed.withUnsafeBufferPointer { mask in
            run.withUnsafeMutableBufferPointer { run in
                best.withUnsafeMutableBufferPointer { best in
                    bestEnd.withUnsafeMutableBufferPointer { bestEnd in
                        count.withUnsafeMutableBufferPointer { count in
                            for y in 0..<height {
                                let row = y * width
                                for x in 0..<width {
                                    if mask[row + x] != 0 {
                                        run[x] += 1
                                        count[x] += 1
                                        if run[x] > best[x] {
                                            best[x] = run[x]
                                            bestEnd[x] = y
                                        }
                                    } else {
                                        run[x] = 0
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        var starts = [Int](repeating: 0, count: width), lengths = [Int](repeating: 0, count: width)
        // A column with fewer cells than `minimum` cannot hold a run that long.
        for x in 0..<width where Double(count[x]) >= minimum {
            lengths[x] = best[x]
            starts[x] = bestEnd[x] - best[x] + 1
        }
        // A rule two pixels wide has an edge on each side; edges this close
        // together are one separator, the longer of them.
        var found: [(at: Int, start: Int, end: Int)] = []
        var group: [Int] = []
        func flush() {
            guard let best = group.max(by: { lengths[$0] != lengths[$1] ? lengths[$0] < lengths[$1] : $0 > $1 })
            else { return }
            found.append((best + 1, starts[best], starts[best] + lengths[best]))
            group.removeAll()
        }
        for x in 0..<width where Double(lengths[x]) >= minimum {
            if let first = group.first, x - first >= merge { flush() }
            group.append(x)
        }
        flush()
        return found
    }

    /// Morphological closing down each column with a kernel `breakPixels + 1`
    /// tall, anchored as OpenCV anchors it (rows -2 to +1 for the default):
    /// a dilation, then an erosion, each ignoring rows outside the image.
    static func closeColumns(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        let size = breakPixels + 1
        let low = -(size / 2), high = size - 1 - size / 2
        // Cells are 0 or 1, so a dilation ORs the rows in reach and an
        // erosion ANDs them, a whole row at a time.
        func pass(_ input: [UInt8], dilate: Bool) -> [UInt8] {
            var output = [UInt8](repeating: dilate ? 0 : 1, count: input.count)
            input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { target in
                    for y in 0..<height {
                        let out = y * width
                        for row in max(0, y + low)...min(height - 1, y + high) {
                            let from = row * width
                            if dilate {
                                for x in 0..<width { target[out + x] |= source[from + x] }
                            } else {
                                for x in 0..<width { target[out + x] &= source[from + x] }
                            }
                        }
                    }
                }
            }
            return output
        }
        return pass(pass(mask, dilate: true), dilate: false)
    }

    // MARK: - Separators

    /// The edges no text box crosses, as the worker reports them: normalized
    /// to the region, bottom-left origin, width zero for a vertical separator
    /// and height zero for a horizontal one, longest first, at most
    /// `maximum`. `boxes` are the text boxes in the region's pixels with a
    /// top-left origin.
    static func separators(_ edges: [Edge], boxes: [CGRect], width: Int, height: Int) -> [CGRect] {
        let w = CGFloat(width), h = CGFloat(height)
        var found: [(length: CGFloat, rect: CGRect)] = []
        for edge in edges where edge.vertical {
            let x = edge.at
            let crossed = boxes.contains { box in
                box.minX < x - pad && box.maxX > x + pad && box.maxY > edge.start && box.minY < edge.end
            }
            if pad < x, x < w - pad, !crossed {
                found.append((edge.length, CGRect(x: x / w, y: (h - edge.end) / h, width: 0, height: edge.length / h)))
            }
        }
        for edge in edges where !edge.vertical {
            let y = edge.at
            let crossed = boxes.contains { box in
                box.minY < y - pad && box.maxY > y + pad && box.maxX > edge.start && box.minX < edge.end
            }
            if pad < y, y < h - pad, !crossed {
                found.append((edge.length, CGRect(x: edge.start / w, y: (h - y) / h, width: edge.length / w, height: 0)))
            }
        }
        // Stable, as Python's sort is: equal lengths keep their order.
        let ordered = found.enumerated().sorted { a, b in
            a.element.length != b.element.length ? a.element.length > b.element.length : a.offset < b.offset
        }
        return ordered.prefix(maximum).map(\.element.rect)
    }

    /// The panes of a region before any text is read: cut at every edge that
    /// spans 90% of what it would divide, bars first (top to bottom), then
    /// sidebars (left to right), never thinner than `minimum` pixels. Rects
    /// in the region's pixels, top-left origin, in reading order.
    static func panes(_ edges: [Edge], width: Int, height: Int, minimum: CGFloat) -> [CGRect] {
        var out: [CGRect] = []
        var stack = [CGRect(x: 0, y: 0, width: width, height: height)]
        while let rect = stack.popLast() {
            let across = edges.filter { edge in
                !edge.vertical && rect.minY + minimum <= edge.at && edge.at <= rect.maxY - minimum
                    && min(edge.end, rect.maxX) - max(edge.start, rect.minX) >= 0.9 * rect.width
            }.min { $0.at < $1.at }
            if let cut = across {
                stack.append(CGRect(x: rect.minX, y: cut.at, width: rect.width, height: rect.maxY - cut.at))
                stack.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.at - rect.minY))
                continue
            }
            let down = edges.filter { edge in
                edge.vertical && rect.minX + minimum <= edge.at && edge.at <= rect.maxX - minimum
                    && min(edge.end, rect.maxY) - max(edge.start, rect.minY) >= 0.9 * rect.height
            }.min { $0.at < $1.at }
            if let cut = down {
                stack.append(CGRect(x: cut.at, y: rect.minY, width: rect.maxX - cut.at, height: rect.height))
                stack.append(CGRect(x: rect.minX, y: rect.minY, width: cut.at - rect.minX, height: rect.height))
                continue
            }
            out.append(rect)
        }
        return out
    }
}
