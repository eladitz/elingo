// Finds the passages of text on a page and where they sit: from the PDF's own text when it has some,
// or by reading the page image (Vision) when it's a scan. Lines that wrap are joined into one passage,
// so a sentence is translated as a sentence; short labels (a form's "Name:", "Geburtsdatum") stay apart.

import PDFKit
import Vision
import NaturalLanguage

struct Passage {
    var rect: CGRect        // page space
    var text: String
    var lineHeight: CGFloat
    var bold = false
}

enum Layout {
    static func passages(on page: PDFPage) -> [Passage] {
        var runs = textRuns(page)
        if runs.isEmpty { runs = ocrRuns(page) }
        return join(runs)
    }

    /// The language most of the document is written in, from its first pages.
    static func language(of pages: [[Passage]]) -> Locale.Language? {
        let text = pages.prefix(5).joined().map(\.text).joined(separator: "\n")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(20_000)))
        return recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
    }

    // MARK: Lines

    private struct Run {
        var rect: CGRect
        var text: String
        var bold = false
    }

    /// PDFKit's lines, split where a big gap separates two things on one baseline (columns, a label
    /// and the field beside it). Words are measured through selections: `characterBounds(at:)` drifts by
    /// one character per line break, so it can't be trusted.
    private static func textRuns(_ page: PDFPage) -> [Run] {
        guard let all = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        var runs: [Run] = []
        for line in all.selectionsByLine() {
            guard let text = line.string as NSString?, text.length > 0 else { continue }
            let start = line.range(at: 0, on: page).location
            var current: Run?
            func flush() {
                if var run = current {
                    run.text = clean(run.text)
                    if run.text.contains(where: \.isLetter) { runs.append(run) }
                }
                current = nil
            }
            text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byWords) { _, _, enclosing, _ in
                // The enclosing range keeps the punctuation after a word ("Name:"), trimmed of spaces.
                let raw = text.substring(with: enclosing)
                let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty,
                      let selection = page.selection(for: NSRange(location: start + enclosing.location, length: enclosing.length)) else { return }
                let rect = selection.bounds(for: page)
                guard rect.width > 0 else { return }
                if var run = current {
                    let h = max(run.rect.height, rect.height)
                    if rect.minX - run.rect.maxX < h * 1.6 {
                        run.text += " " + word
                        run.rect = run.rect.union(rect)
                        current = run
                        return
                    }
                    flush()
                }
                let font = selection.attributedString.flatMap { $0.length > 0 ? $0.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil }
                let bold = font.map { $0.fontDescriptor.symbolicTraits.contains(.bold) || $0.fontName.lowercased().contains("bold") } ?? false
                current = Run(rect: rect, text: word, bold: bold)
            }
            flush()
        }
        return runs
    }

    /// Dot leaders and long dash rules are layout, not words.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"[.·…_\-–]{3,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([.,:;!?)])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func ocrRuns(_ page: PDFPage) -> [Run] {
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.5
        let image = page.thumbnail(of: NSSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let r = observation.boundingBox
            let rect = CGRect(x: box.minX + r.minX * box.width, y: box.minY + r.minY * box.height,
                              width: r.width * box.width, height: r.height * box.height)
            let cleaned = clean(text)
            return cleaned.contains(where: \.isLetter) ? Run(rect: rect, text: cleaned) : nil
        }
    }

    // MARK: Passages

    /// A line joins the passage above it when it starts at the same left edge, sits just below, is the same
    /// size, and the line above ran long and didn't end like a label or a sentence.
    private static func join(_ runs: [Run]) -> [Passage] {
        let ordered = runs.sorted { abs($0.rect.maxY - $1.rect.maxY) > 2 ? $0.rect.maxY > $1.rect.maxY : $0.rect.minX < $1.rect.minX }
        var passages: [Passage] = []
        var lastLine: [Int: CGRect] = [:]   // passage index → its bottom line
        var lastText: [Int: String] = [:]

        for run in ordered {
            let h = run.rect.height
            let target = passages.indices.reversed().first { i in
                guard let line = lastLine[i], let text = lastText[i] else { return false }
                let gap = line.minY - run.rect.maxY
                return gap > -h * 0.3 && gap < h * 0.8
                    && abs(run.rect.minX - passages[i].rect.minX) < h * 1.2
                    && h / line.height > 0.75 && h / line.height < 1.33
                    && text.count >= 30
                    && !text.hasSuffix(":") && !text.hasSuffix(".")
            }
            if let i = target {
                var text = passages[i].text
                if text.hasSuffix("-"), run.text.first?.isLowercase == true { text.removeLast() } else { text += " " }
                passages[i].text = text + run.text
                passages[i].rect = passages[i].rect.union(run.rect)
                lastLine[i] = run.rect
                lastText[i] = run.text
            } else {
                passages.append(Passage(rect: run.rect, text: run.text, lineHeight: h, bold: run.bold))
                lastLine[passages.count - 1] = run.rect
                lastText[passages.count - 1] = run.text
            }
        }
        return passages
    }
}
