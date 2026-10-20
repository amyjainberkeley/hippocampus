import AppKit
import RecallUIKit
import SwiftUI

/// A moment's formatted text in one read-only text view (SPEC 4.6): a
/// selection runs across paragraphs, ⌘C copies plain text, find works, and
/// VoiceOver reads one text area with rotors for its headings, its code and
/// its lists. Code, terminal output and tables draw their box and hairlines
/// through a layout fragment of their own (TextKit 2).
struct ReadingTextView: NSViewRepresentable {
    let built: ReadingAttributedText.Built
    /// A closed quote's line was clicked: open the quote at this block.
    var onOpenQuote: (Int) -> Void = { _ in }
    /// A selection to show (the renders' picture of one).
    var selection: NSRange?

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenQuote: onOpenQuote)
    }

    func makeNSView(context: Context) -> ReadingNSTextView {
        let view = ReadingNSTextView.make()
        view.textLayoutManager?.delegate = context.coordinator
        view.delegate = context.coordinator
        view.show(built)
        select(in: view)
        return view
    }

    func updateNSView(_ view: ReadingNSTextView, context: Context) {
        context.coordinator.onOpenQuote = onOpenQuote
        if view.built !== built {
            view.show(built)
            select(in: view)
        }
    }

    private func select(in view: ReadingNSTextView) {
        guard let selection, NSMaxRange(selection) <= built.string.length else { return }
        view.setSelectedRange(selection)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReadingNSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextLayoutManagerDelegate {
        var onOpenQuote: (Int) -> Void

        init(onOpenQuote: @escaping (Int) -> Void) {
            self.onOpenQuote = onOpenQuote
        }

        /// A quote's line opens the quote; a web address opens in the
        /// browser; nothing else a page showed is ever opened.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let index = ReadingAttributedText.quoteIndex(of: link) {
                onOpenQuote(index)
                return true
            }
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return true
        }

        func textLayoutManager(
            _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
            in textElement: NSTextElement
        ) -> NSTextLayoutFragment {
            let plain = NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
            guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else {
                return plain
            }
            let attributes = paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
            let decoration: ReadingFragment.Decoration
            if let place = attributes[.readingBox] as? String {
                decoration = .box(place)
            } else if attributes[.readingRule] != nil {
                decoration = .rule
            } else if let place = attributes[.readingQuote] as? String {
                decoration = .quote(place)
            } else {
                return plain
            }
            return ReadingFragment(textElement: textElement, range: textElement.elementRange, decoration: decoration)
        }
    }
}

/// One paragraph that draws something around its text: its part of a code
/// or terminal box, a table row's hairline, a quote's rule.
final class ReadingFragment: NSTextLayoutFragment {
    enum Decoration {
        /// A line of a box: "first", "middle", "last" or "only".
        case box(String)
        /// A hairline under the row.
        case rule
        /// A rule at the left: "first", "middle" or "last".
        case quote(String)
    }

    /// Inside a box, around its text (SPEC 4.6).
    static let boxPadding: CGFloat = 10
    /// Above and below a table row's text.
    static let rowPadding: CGFloat = 5

    let decoration: Decoration

    init(textElement: NSTextElement, range: NSTextRange?, decoration: Decoration) {
        self.decoration = decoration
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private var containerWidth: CGFloat {
        let width = textLayoutManager?.textContainer?.size.width ?? 0
        return width > 0 && width < 100_000 ? width : layoutFragmentFrame.width
    }

    /// Where the decoration goes, in the fragment's own coordinates: from the
    /// container's left edge across its width.
    var decorationRect: CGRect {
        let lines = textLineFragments
        let top = lines.first?.typographicBounds.minY ?? 0
        let bottom = lines.last?.typographicBounds.maxY ?? layoutFragmentFrame.height
        let left = -layoutFragmentFrame.minX
        switch decoration {
        case let .box(place):
            let opens = place == "first" || place == "only"
            let closes = place == "last" || place == "only"
            let minY = opens ? top - Self.boxPadding : 0
            let maxY = closes ? bottom + Self.boxPadding : max(bottom, layoutFragmentFrame.height)
            return CGRect(x: left, y: minY, width: containerWidth, height: maxY - minY)
        case .rule:
            return CGRect(x: left, y: bottom + Self.rowPadding - 0.5, width: containerWidth, height: 1)
        case let .quote(place):
            let minY = place == "first" ? top : 0
            let maxY = place == "last" ? bottom : max(bottom, layoutFragmentFrame.height)
            return CGRect(x: left, y: minY, width: 2, height: maxY - minY)
        }
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(decorationRect)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let rect = decorationRect.offsetBy(dx: point.x, dy: point.y)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        switch decoration {
        case let .box(place):
            ReadingStyle.inset.setFill()
            let radius: CGFloat = 8
            let roundTop = place == "first" || place == "only"
            let roundBottom = place == "last" || place == "only"
            Self.path(rect, radius: radius, top: roundTop, bottom: roundBottom).fill()
        case .rule:
            ReadingStyle.hairline.setFill()
            NSBezierPath(rect: rect).fill()
        case .quote:
            ReadingStyle.rule.setFill()
            NSBezierPath(rect: rect).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        super.draw(at: point, in: context)
    }

    /// A rectangle with its top corners, its bottom corners, both or neither
    /// rounded (in flipped coordinates: the top is `minY`).
    static func path(_ rect: CGRect, radius: CGFloat, top: Bool, bottom: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        let topRadius = top ? radius : 0
        let bottomRadius = bottom ? radius : 0
        path.move(to: NSPoint(x: rect.minX + topRadius, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - topRadius, y: rect.minY))
        if topRadius > 0 {
            path.appendArc(from: NSPoint(x: rect.maxX, y: rect.minY), to: NSPoint(x: rect.maxX, y: rect.minY + topRadius),
                           radius: topRadius)
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - bottomRadius))
        if bottomRadius > 0 {
            path.appendArc(from: NSPoint(x: rect.maxX, y: rect.maxY), to: NSPoint(x: rect.maxX - bottomRadius, y: rect.maxY),
                           radius: bottomRadius)
        }
        path.line(to: NSPoint(x: rect.minX + bottomRadius, y: rect.maxY))
        if bottomRadius > 0 {
            path.appendArc(from: NSPoint(x: rect.minX, y: rect.maxY), to: NSPoint(x: rect.minX, y: rect.maxY - bottomRadius),
                           radius: bottomRadius)
        }
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + topRadius))
        if topRadius > 0 {
            path.appendArc(from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.minX + topRadius, y: rect.minY),
                           radius: topRadius)
        }
        path.close()
        return path
    }
}

/// The text view: read-only, selectable, sized by its text.
final class ReadingNSTextView: NSTextView, @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate {
    private(set) var built: ReadingAttributedText.Built?
    /// The link under the pointer, underlined while it is there.
    private var hovered: NSRange?
    private var hoverArea: NSTrackingArea?
    /// The last height measured, for its width and string: SwiftUI asks on
    /// every layout pass, and a long reading takes a while to lay out.
    private var measured: (width: CGFloat, built: ObjectIdentifier, height: CGFloat)?

    static func make() -> ReadingNSTextView {
        let view = ReadingNSTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.allowsUndo = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.usesFindPanel = true
        view.isAutomaticLinkDetectionEnabled = false
        // A link keeps the look the string gives it: an address in the
        // accent, a quote's "Earlier in this thread" as the text around it.
        view.linkTextAttributes = [:]
        return view
    }

    func show(_ built: ReadingAttributedText.Built) {
        self.built = built
        hovered = nil
        let shown = NSMutableAttributedString(attributedString: built.string)
        shown.enumerateAttribute(.link, in: NSRange(location: 0, length: shown.length)) { value, range, _ in
            if value != nil { shown.addAttribute(.cursor, value: NSCursor.pointingHand, range: range) }
        }
        textStorage?.setAttributedString(shown)
        needsLayout = true
        needsDisplay = true
    }

    /// The text starts below the space its first paragraph asks for.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: 0, y: built?.topInset ?? 0)
    }

    /// The height the text takes at `width`, its boxes' padding included.
    func height(forWidth width: CGFloat) -> CGFloat {
        if let built, let measured, measured.built == ObjectIdentifier(built), abs(measured.width - width) < 0.5 {
            return measured.height
        }
        let height = measureHeight(forWidth: width)
        if let built {
            measured = (width, ObjectIdentifier(built), height)
        }
        return height
    }

    private func measureHeight(forWidth width: CGFloat) -> CGFloat {
        guard let manager = textLayoutManager, let container = manager.textContainer else { return 0 }
        if abs(container.size.width - width) > 0.5 {
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        manager.ensureLayout(for: manager.documentRange)
        var bottom = manager.usageBoundsForTextContainer.maxY
        manager.enumerateTextLayoutFragments(from: manager.documentRange.endLocation,
                                             options: [.reverse, .ensuresLayout]) { fragment in
            bottom = max(bottom, fragment.layoutFragmentFrame.minY + fragment.renderingSurfaceBounds.maxY)
            return false
        }
        return ceil(bottom + (built?.topInset ?? 0))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let container = textContainer, abs(container.size.width - newSize.width) > 0.5, newSize.width > 0 {
            container.size = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    // MARK: Copy: plain text, as it was read

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        return pboard.setString(selectedPlainText(), forType: .string)
    }

    /// The selection as plain text: a drawn checkbox or marker as the
    /// marker that was read, a quote's line with its ">", an item's own
    /// lines on lines of their own.
    func selectedPlainText() -> String {
        guard let storage = textStorage else { return "" }
        var out = ""
        for value in selectedRanges {
            let range = value.rangeValue
            guard range.length > 0, NSMaxRange(range) <= storage.length else { continue }
            if !out.isEmpty { out += "\n" }
            out += ReadingAttributedText.copiedText(of: storage, in: range)
        }
        return out
    }

    // MARK: Links underline under the pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                                         .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        var link: NSRange?
        if let storage = textStorage, index < storage.length {
            var range = NSRange()
            if storage.attribute(.link, at: index, effectiveRange: &range) != nil { link = range }
        }
        setHovered(link)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(nil)
    }

    private func setHovered(_ link: NSRange?) {
        guard link != hovered, let storage = textStorage else { return }
        if let hovered, NSMaxRange(hovered) <= storage.length {
            storage.removeAttribute(.underlineStyle, range: hovered)
        }
        if let link {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: link)
        }
        hovered = link
    }

    // MARK: VoiceOver: headings, code and lists

    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        [
            NSAccessibilityCustomRotor(rotorType: .heading, itemSearchDelegate: self),
            NSAccessibilityCustomRotor(label: ReadingCopy.code, itemSearchDelegate: self),
            NSAccessibilityCustomRotor(label: ReadingCopy.lists, itemSearchDelegate: self),
        ]
    }

    /// The ranges a rotor moves through, in order, with what each is called.
    func rotorItems(for rotor: NSAccessibilityCustomRotor) -> [(range: NSRange, label: String)] {
        guard let storage = textStorage else { return [] }
        let all = NSRange(location: 0, length: storage.length)
        var items: [(NSRange, String)] = []
        if rotor.type == .heading {
            storage.enumerateAttribute(.readingHeading, in: all) { value, range, _ in
                guard value != nil else { return }
                items.append((range, (storage.string as NSString).substring(with: range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return items
        }
        let lists = rotor.label == ReadingCopy.lists
        storage.enumerateAttribute(.readingGroup, in: all) { value, range, _ in
            guard let group = value as? String else { return }
            let parts = group.split(separator: ":")
            if lists, parts.first == "list" {
                items.append((range, ReadingCopy.list(items: Int(parts.last ?? "") ?? 0)))
            } else if !lists, parts.first == "code" || parts.first == "terminal" {
                items.append((range, ReadingCopy.code))
            }
        }
        return items
    }

    func rotor(_ rotor: NSAccessibilityCustomRotor,
               resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        let items = rotorItems(for: rotor)
        guard !items.isEmpty else { return nil }
        let current = searchParameters.currentItem?.targetRange.location
        let found: (range: NSRange, label: String)?
        switch searchParameters.searchDirection {
        case .previous:
            found = current.flatMap { location in items.last { $0.range.location < location } } ?? items.last
        default:
            found = current.flatMap { location in items.first { $0.range.location > location } } ?? items.first
        }
        guard let found else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        result.targetRange = found.range
        result.customLabel = found.label
        return result
    }
}
