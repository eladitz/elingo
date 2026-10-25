// Text you add to a PDF that has no fields to type into: ordinary PDF "free text" notes, so they stay
// editable in any PDF app when saved editable, and become part of the page in a signed & locked copy.

import PDFKit

enum TextBoxes {
    /// Marks the boxes Elingo made, so they can be moved and edited (and not a document's own notes).
    static let marker = "Elingo text"

    static func isTextBox(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "FreeText" && annotation.userName == marker
    }

    /// A box with its text's middle at `point`.
    static func make(_ text: String, at point: CGPoint, size: CGFloat, color: NSColor) -> PDFAnnotation {
        let box = PDFAnnotation(bounds: CGRect(x: point.x - 2, y: point.y - size * 0.7, width: 20, height: size * 1.4), forType: .freeText, withProperties: nil)
        box.userName = marker
        box.font = NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        box.fontColor = color
        box.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        box.border = border
        box.alignment = .left
        box.contents = text
        fit(box)
        return box
    }

    /// Snug round the text, keeping its top-left corner where it is.
    static func fit(_ box: PDFAnnotation) {
        let font = box.font ?? .systemFont(ofSize: 11)
        let size = ((box.contents ?? " ") as NSString).boundingRect(with: CGSize(width: 2000, height: 2000), options: [.usesLineFragmentOrigin],
                                                                  attributes: [.font: font]).size
        let b = box.bounds
        let height = ceil(size.height) + 4
        box.bounds = CGRect(x: b.minX, y: b.maxY - height, width: ceil(size.width) + 8, height: height)
    }
}
