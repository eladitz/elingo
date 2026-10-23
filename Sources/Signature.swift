// Signing: draw your signature (or type it), click where it goes, drag to move, drag its corner to resize.
// "Signed & Locked" bakes the form answers and the signature into the pages and protects the file against
// editing. It's a visual signature, like signing a printout, not a certificate-based digital signature.

import SwiftUI
import PDFKit

/// A signature placed on a page: a picture with a transparent background.
final class SignatureAnnotation: PDFAnnotation {
    let image: NSImage

    init(image: NSImage, bounds: CGRect) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.draw(cg, in: bounds)
    }

    /// The bottom-right corner, for resizing.
    func isCorner(_ p: CGPoint) -> Bool { abs(p.x - bounds.maxX) < 12 && abs(p.y - bounds.minY) < 12 }
}

enum Signatures {
    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Elconvo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("signature.png")
    }

    /// The last signature made, kept on this Mac only, so the next form takes one click.
    static var saved: NSImage? { NSImage(contentsOf: file) }

    static func save(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: file)
    }

    /// Strokes drawn on a canvas (top-left origin) → a picture cropped to the ink.
    static func image(strokes: [[CGPoint]], width: CGFloat = 2.6) -> NSImage? {
        let points = strokes.joined()
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let pad = width * 2, scale: CGFloat = 4
        let size = NSSize(width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
        return render(size, scale: scale) {
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for stroke in strokes {
                let mapped = stroke.map { NSPoint(x: $0.x - minX + pad, y: size.height - ($0.y - minY + pad)) }
                guard let first = mapped.first else { continue }
                path.move(to: first)
                if mapped.count == 1 { path.line(to: NSPoint(x: first.x + 0.5, y: first.y)) }
                // Midpoint smoothing: curves through the midpoints, with the samples as control points.
                for i in 1..<max(mapped.count, 1) where mapped.count > 1 {
                    let mid = NSPoint(x: (mapped[i - 1].x + mapped[i].x) / 2, y: (mapped[i - 1].y + mapped[i].y) / 2)
                    path.curve(to: mid, controlPoint1: mapped[i - 1], controlPoint2: mapped[i - 1])
                }
                if let last = mapped.last, mapped.count > 1 { path.line(to: last) }
            }
            NSColor(srgbRed: 0.05, green: 0.1, blue: 0.35, alpha: 1).setStroke()
            path.stroke()
        }
    }

    /// A typed name in a handwriting font.
    static func image(typed name: String) -> NSImage? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let font = NSFont(name: "SnellRoundhand-Bold", size: 64) ?? NSFont(name: "Zapfino", size: 40) ?? .systemFont(ofSize: 48)
        let text = NSAttributedString(string: trimmed, attributes: [.font: font, .foregroundColor: NSColor(srgbRed: 0.05, green: 0.1, blue: 0.35, alpha: 1)])
        let bounds = text.boundingRect(with: NSSize(width: 4000, height: 400), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = NSSize(width: ceil(bounds.width) + 24, height: ceil(bounds.height) + 12)
        return render(size, scale: 3) { text.draw(at: NSPoint(x: 12, y: 6)) }
    }

    private static func render(_ size: NSSize, scale: CGFloat, _ draw: () -> Void) -> NSImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Every page drawn as it looks now (form answers, signatures) into a new PDF with no fields left,
    /// protected so it can be printed and copied from but not edited.
    static func writeLocked(_ document: PDFDocument, to url: URL, title: String) throws {
        // 1. Flatten: draw each page as it looks now into a plain PDF.
        let flat = FileManager.default.temporaryDirectory.appendingPathComponent("elingo-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: flat) }
        guard let first = document.page(at: 0) else { throw TranslateError("The PDF has no pages.") }
        var box = first.bounds(for: .mediaBox)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Elingo"]
        guard let context = CGContext(flat as CFURL, mediaBox: &box, info as CFDictionary) else { throw TranslateError("Couldn't write the PDF.") }
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            var pageBox = page.bounds(for: .mediaBox)
            context.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            page.draw(with: .mediaBox, to: context)
            context.endPDFPage()
        }
        context.closePDF()

        // 2. Lock: anyone can open, print and copy from it; changing it needs a password nobody has.
        guard let flattened = PDFDocument(url: flat) else { throw TranslateError("Couldn't write the PDF.") }
        let allowed = [PDFAccessPermissions.allowsHighQualityPrinting, .allowsLowQualityPrinting, .allowsContentCopying, .allowsContentAccessibility]
            .reduce(0) { $0 | $1.rawValue }   // a plain enum in Swift, not an option set
        let options: [PDFDocumentWriteOption: Any] = [.ownerPasswordOption: UUID().uuidString, .accessPermissionsOption: allowed]
        guard flattened.write(to: url, withOptions: options) else { throw TranslateError("Couldn't save \(url.lastPathComponent).") }
    }
}

// MARK: The signature pad

@MainActor
final class SignaturePadModel: ObservableObject {
    @Published var strokes: [[CGPoint]] = []
    @Published var typed = ""
    @Published var typing = false
    var drawing = false   // a stroke is under way
    var onDone: ((NSImage) -> Void)?
    weak var window: NSWindow?

    var image: NSImage? { typing ? Signatures.image(typed: typed) : Signatures.image(strokes: strokes) }

    static func open(_ done: @escaping (NSImage) -> Void) {
        let model = SignaturePadModel()
        model.onDone = done
        model.window = Windows.show("Your Signature", size: NSSize(width: 560, height: 330), SignaturePadView(model: model))
    }

    func finish() {
        guard let image else { return }
        Signatures.save(image)
        onDone?(image)
        window?.close()
    }
}

struct SignaturePadView: View {
    @ObservedObject var model: SignaturePadModel

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $model.typing) {
                Text("Draw").tag(false)
                Text("Type").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)

            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white)
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.gray.opacity(0.4))
                Rectangle().fill(Color.gray.opacity(0.35)).frame(height: 1).padding(.horizontal, 30).offset(y: 50)
                if model.typing {
                    TextField("Your name", text: $model.typed)
                        .font(.custom("SnellRoundhand-Bold", size: 44))
                        .foregroundStyle(Color(red: 0.05, green: 0.1, blue: 0.35))
                        .textFieldStyle(.plain).multilineTextAlignment(.center).padding(.horizontal, 30)
                } else {
                    Canvas { context, _ in
                        for stroke in model.strokes {
                            var path = Path()
                            path.addLines(stroke)
                            context.stroke(path, with: .color(Color(red: 0.05, green: 0.1, blue: 0.35)),
                                           style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if model.drawing { model.strokes[model.strokes.count - 1].append(value.location) }
                            else { model.strokes.append([value.location]); model.drawing = true }
                        }
                        .onEnded { _ in model.drawing = false })
                    if model.strokes.isEmpty {
                        Text("Sign here with your trackpad or mouse").foregroundStyle(.gray).allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 180)

            HStack {
                Text("Kept on this Mac only, for your next form.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.strokes = []; model.typed = "" }
                Button("Cancel") { model.window?.close() }.keyboardShortcut(.cancelAction)
                Button("Use Signature") { model.finish() }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.image == nil)
            }
        }
        .padding(16)
    }
}
