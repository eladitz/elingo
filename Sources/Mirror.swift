// The translated twin of a document. Each page draws the original page live (so whatever you type into
// the form shows up here too), then covers each passage with its translation, in the passage's own
// spot, on a patch of the page's own background colour.

import PDFKit

final class MirrorPage: PDFPage {
    struct Placed {
        let rect: CGRect          // where the original text is
        let room: CGRect          // where the translation may go: the same, plus free space to the right
        let original: String
        let translation: String
        let background: NSColor
        let ink: NSColor
        let lineHeight: CGFloat
        let bold: Bool
        var fitted: (size: CGFloat, patch: CGRect)? = nil
    }

    let original: PDFPage
    var placed: [Placed] = []
    /// On screen, PDFKit leaves the form's fields (and signatures) out of `draw`, because the view puts
    /// them on top separately; so the mirror draws them itself. Writing a PDF, `draw` already includes them.
    var drawsAnnotations = true

    init(_ original: PDFPage) {
        self.original = original
        super.init()
        rotation = original.rotation
    }

    override func bounds(for box: PDFDisplayBox) -> NSRect { original.bounds(for: box) }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        original.draw(with: box, to: context)
        if drawsAnnotations {
            for annotation in original.annotations where annotation.type == "Widget" || annotation is SignatureAnnotation {
                annotation.draw(with: box, in: context)
            }
        }
        guard !placed.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for i in placed.indices {
            let p = placed[i]
            let fitted = p.fitted ?? Self.fit(p)
            placed[i].fitted = fitted
            p.background.setFill()
            fitted.patch.insetBy(dx: -1.5, dy: -1.5).fill()
            Self.text(p.translation, size: fitted.size, bold: p.bold, ink: p.ink)
                .draw(with: p.room, options: [.usesLineFragmentOrigin])
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    func passage(at point: CGPoint) -> Placed? {
        placed.last { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }
    }

    private static func text(_ s: String, size: CGFloat, bold: Bool, ink: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineHeightMultiple = 0.92
        return NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular),
                                                          .foregroundColor: ink, .paragraphStyle: style])
    }

    /// The biggest size (up to the original's) at which the translation fits its room, and the patch to
    /// paint under it (the original's spot plus whatever the translation covers).
    /// Below 5 pt it stops shrinking and lets the text run past the room instead.
    static func fit(_ p: Placed) -> (size: CGFloat, patch: CGRect) {
        var size = max(5, min(p.lineHeight * 0.82, 30))
        var needed = CGRect.zero
        while true {
            needed = text(p.translation, size: size, bold: p.bold, ink: .black)
                .boundingRect(with: CGSize(width: p.room.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
            if size <= 5 || (needed.height <= p.room.height + 1 && needed.width <= p.room.width + 1) { break }
            size -= 0.5
        }
        let used = CGRect(x: p.room.minX, y: p.room.maxY - needed.height, width: needed.width, height: needed.height)
        return (size, p.rect.union(used))
    }
}

/// Builds a document of `MirrorPage`s for a PDF and fills them in as each page is translated.
@MainActor
final class Mirror {
    let source: PDFDocument
    let document = PDFDocument()
    private(set) var passages: [[Passage]?]

    init(_ source: PDFDocument) {
        self.source = source
        passages = Array(repeating: nil, count: source.pageCount)
        for i in 0..<source.pageCount {
            if let page = source.page(at: i) { document.insert(MirrorPage(page), at: document.pageCount) }
        }
    }

    func page(_ i: Int) -> MirrorPage? { document.page(at: i) as? MirrorPage }

    func passages(onPage i: Int) -> [Passage] {
        if let known = passages[i] { return known }
        let found = source.page(at: i).map(Layout.passages) ?? []
        passages[i] = found
        return found
    }

    /// The document's language, judged from its first pages.
    func detectLanguage() -> Locale.Language? {
        Layout.language(of: (0..<min(5, source.pageCount)).map { passages(onPage: $0) })
    }

    func apply(_ translations: [String], onPage i: Int) {
        guard let page = page(i) else { return }
        let found = passages(onPage: i)
        let colors = PageColors(page.original)
        let box = page.original.bounds(for: .mediaBox)
        // Things a translation mustn't run into: the other passages and the form's fields.
        let obstacles = found.map(\.rect) + page.original.annotations.filter { $0.type == "Widget" }.map(\.bounds)
        page.placed = zip(found, translations).map { passage, translation in
            let r = passage.rect
            let margin = max(18, min(r.minX - box.minX, 72))
            let right = obstacles
                .filter { $0 != r && $0.minX >= r.maxX - 1 && $0.maxY > r.minY + 1 && $0.minY < r.maxY - 1 }
                .map { $0.minX - 8 }
                .reduce(box.maxX - margin, min)
            let room = CGRect(x: r.minX, y: r.minY, width: max(r.width, right - r.minX), height: r.height)
            let background = colors.background(around: r)
            return MirrorPage.Placed(rect: r, room: room, original: passage.text, translation: translation, background: background,
                                     ink: background.isDark ? .white : .black, lineHeight: passage.lineHeight, bold: passage.bold)
        }
    }

    func clear() {
        for i in 0..<document.pageCount { page(i)?.placed = [] }
    }

    /// Writes the translated pages (with what's been typed into the form) as an ordinary PDF.
    func export(to url: URL) throws {
        guard let first = page(0) else { return }
        var box = first.bounds(for: .mediaBox)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw TranslateError("Couldn't write the PDF.") }
        for i in 0..<document.pageCount {
            guard let page = page(i) else { continue }
            var pageBox = page.bounds(for: .mediaBox)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
            page.drawsAnnotations = false
            defer { page.drawsAnnotations = true }
            page.draw(with: .mediaBox, to: context)
            context.endPDFPage()
        }
        context.closePDF()
    }
}

/// A low-resolution picture of a page, for picking the colour around each passage. Drawn in sRGB so
/// the colours picked match the colours painted.
private struct PageColors {
    let pixels: [UInt8]
    let width: Int, height: Int
    let box: CGRect

    init(_ page: PDFPage) {
        box = page.bounds(for: .mediaBox)
        let box = self.box, w = max(1, Int(box.width)), h = max(1, Int(box.height))
        width = w; height = h
        var buffer = [UInt8](repeating: 255, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: context)
        }
        pixels = buffer
    }

    /// The median of a ring of samples just outside the passage, so a stray line or letter doesn't win.
    func background(around rect: CGRect) -> NSColor {
        let r = rect.insetBy(dx: -3, dy: -2)
        var samples: [NSColor] = []
        for fx in stride(from: 0.0, through: 1.0, by: 0.25) {
            for y in [r.minY, r.maxY] { samples.append(sample(r.minX + r.width * fx, y)) }
        }
        for fy in [0.25, 0.5, 0.75] {
            for x in [r.minX, r.maxX] { samples.append(sample(x, r.minY + r.height * fy)) }
        }
        let sorted = samples.sorted { $0.luminance < $1.luminance }
        return sorted[sorted.count / 2]
    }

    private func sample(_ x: CGFloat, _ y: CGFloat) -> NSColor {
        // Bitmap rows run top to bottom; page y runs bottom to top.
        let px = Int((x - box.minX).rounded()), py = height - 1 - Int((y - box.minY).rounded())
        guard px >= 0, py >= 0, px < width, py < height else { return .white }
        let i = (py * width + px) * 4
        return NSColor(srgbRed: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255, blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
    }
}

extension NSColor {
    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 1 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
    var isDark: Bool { luminance < 0.45 }
}
