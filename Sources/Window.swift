// The window: a PDF on the left to fill in and sign, and the same pages on the right with every passage
// translated in place. The two scroll and zoom together, what you type on the left shows up on the right,
// and pointing at a passage on either side shows the original and its translation.

import SwiftUI
import PDFKit
import Translation

@MainActor
final class TranslateModel: ObservableObject {
    let url: URL
    let original: PDFDocument
    let mirror: Mirror
    let translator: Translator   // shared by the window's files: one download prompt, one memory of phrases
    let left = HoverPDFView()
    let right = HoverPDFView()

    @Published var languages: [Locale.Language] = []
    @Published var sourceID = "auto"
    @Published var targetID: String
    @Published var detected: Locale.Language?
    @Published var status = "Reading the document…"
    @Published var hovered: MirrorPage.Placed?
    @Published var busy = false
    private(set) var startedAt = Date()
    @Published var placing: NSImage?   // a signature waiting for a click on the page
    @Published var signedCopy: URL?    // the signed & locked copy saved this session, for the file list
    /// The target language was changed here; the window passes it on to its other files.
    var onTargetChosen: ((String) -> Void)?
    weak var window: NSWindow?
    private var dragging: (item: PDFAnnotation, corner: Bool, grab: CGPoint)?

    private var job: Task<Void, Never>?
    private var syncing = false
    private var observers: [NSObjectProtocol] = []
    private var fieldState: [Int: String] = [:]
    private let highlights = (HighlightView(), HighlightView())

    init?(url: URL, translator: Translator) {
        guard let doc = PDFDocument(url: url) else { return nil }
        self.url = url
        self.translator = translator
        original = doc
        mirror = Mirror(doc)
        targetID = UserDefaults.standard.string(forKey: "translateTarget") ?? Locale.current.language.languageCode?.identifier ?? "en"

        for (view, document) in [(left, original), (right, mirror.document)] {
            // Limits before autoScales: setting them afterwards quietly switches fitting off.
            view.minScaleFactor = 0.1
            view.maxScaleFactor = 8
            view.document = document
            view.autoScales = true
            view.displayMode = .singlePageContinuous
            view.backgroundColor = .underPageBackgroundColor
            view.onHover = { [weak self] page, point in self?.hover(page, point) }
        }
        left.onMouseDown = { [weak self] page, point, clicks in self?.mouseDown(page, point, clicks: clicks) ?? false }
        left.onMouseDragged = { [weak self] page, point in self?.mouseDragged(page, point) }
        left.onMouseUp = { [weak self] in self?.dragging = nil }
        left.placedAt = { page, point in Self.placed(on: page, at: point) }
        left.onRemove = { [weak self] item in self?.remove(item) }
        left.onEdit = { [weak self] item in self?.beginEditing(item) }
        left.onRecolor = { [weak self] item, color in self?.recolor(item, color) }
        left.onAddHere = { [weak self] kind, page, point in self?.add(kind, on: page, at: point) }
        left.addSubview(highlights.0)
        left.addSubview(selection)
        left.onDeleteKey = { [weak self] in
            guard let self, self.editing == nil, let item = self.selected else { return false }
            self.remove(item)
            return true
        }
        right.addSubview(highlights.1)
        DispatchQueue.main.async { [weak self] in self?.linkScrolling() }
        watchForm()

        Task {
            languages = await Translator.supportedLanguages()
            if !languages.contains(where: { $0.minimalIdentifier == targetID }) {
                let code = Locale.Language(identifier: targetID).languageCode
                targetID = languages.first { $0.languageCode == code }?.minimalIdentifier ?? "en"
            }
            translate()
        }
    }

    // MARK: Translating

    func translate() {
        job?.cancel()
        UserDefaults.standard.set(targetID, forKey: "translateTarget")
        mirror.clear()
        redrawMirror()
        job = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        startedAt = Date()
        busy = true
        defer { busy = false }
        status = "Reading the document…"
        await Task.yield()
        let source: Locale.Language
        if sourceID == "auto" {
            guard let found = mirror.detectLanguage() else {
                status = "There's no text in this PDF to translate."
                return
            }
            detected = found
            source = found
        } else {
            source = Locale.Language(identifier: sourceID)
        }
        let target = Locale.Language(identifier: targetID)
        guard source.languageCode != target.languageCode else {
            status = "This document is already in \(Translator.name(target)). Pick another language on the right."
            return
        }
        let pages = mirror.document.pageCount
        for i in 0..<pages {
            if Task.isCancelled { return }
            status = pages == 1 ? "Translating…" : "Translating page \(i + 1) of \(pages)…"
            let texts = mirror.passages(onPage: i).map(\.text)
            guard !texts.isEmpty else { continue }
            if ProcessInfo.processInfo.environment["ELINGO_DEBUG"] != nil { print("page", i, texts.count, "passages") }
            do {
                let translated = try await translator.translate(texts, from: source, to: target)
                if Task.isCancelled { return }
                mirror.apply(translated, onPage: i)
                redrawMirror()
            } catch {
                status = error.localizedDescription
                return
            }
        }
        status = "\(Translator.name(source)) → \(Translator.name(target)). Point at any passage to see the original next to its translation."
    }

    private func redrawMirror() {
        right.layoutDocumentView()
        right.needsDisplay = true
        right.documentView?.subviews.forEach { $0.needsDisplay = true }
        right.documentView?.needsDisplay = true
    }

    // MARK: Saving

    /// The form with your answers, still editable. Signatures only go into the signed & locked copy.
    func saveFilled() {
        commitEditing()
        window?.makeFirstResponder(nil)   // finish the field being typed in
        guard let out = ask(name: "\(base) (filled).pdf") else { return }
        let signatures = allSignatures()
        for (page, signature) in signatures { page.removeAnnotation(signature) }
        let saved = original.write(to: out)
        for (page, signature) in signatures { page.addAnnotation(signature) }
        status = !saved ? "Couldn't save \(out.lastPathComponent)."
            : signatures.isEmpty ? "Saved \(out.lastPathComponent). Fields stay editable."
            : "Saved \(out.lastPathComponent) without the signature (fields stay editable). Use Save Signed & Locked to include it."
        if saved { Donation.recordUse() }
    }

    /// Answers and signature baked into the pages, no fields left, protected against editing.
    func saveLocked() {
        commitEditing()
        window?.makeFirstResponder(nil)
        if allSignatures().isEmpty {
            let alert = NSAlert()
            alert.messageText = "There's no signature on the form yet"
            alert.informativeText = "Click Sign to add one first, or save it locked without a signature."
            alert.addButton(withTitle: "Add Signature…")
            alert.addButton(withTitle: "Save Without")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: newSignature(); return
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        guard let out = ask(name: "\(base) (signed).pdf") else { return }
        if out.standardizedFileURL == url.standardizedFileURL {
            status = "Choose a new name: the signed copy can't replace the form it's made from."
            return
        }
        do {
            try Signatures.writeLocked(original, to: out, title: base)
            status = "Saved \(out.lastPathComponent): answers and signature are part of the pages now, and the file is locked against editing."
            signedCopy = out
            Donation.recordUse()
        } catch {
            status = error.localizedDescription
        }
    }

    private var base: String { url.deletingPathExtension().lastPathComponent }

    func saveTranslation() {
        window?.makeFirstResponder(nil)
        let language = Translator.name(Locale.Language(identifier: targetID))
        guard let out = ask(name: "\(base) (\(language)).pdf") else { return }
        do {
            try mirror.export(to: out)
            status = "Saved \(out.lastPathComponent)."
            Donation.recordUse()
        } catch {
            status = error.localizedDescription
        }
    }

    private func ask(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Keeping the two sides together

    private func linkScrolling() {
        for (a, b) in [(left, right), (right, left)] {
            if let clip = a.documentView?.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.follow(a, b) }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: a, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow(a, b) }
            })
        }
    }

    private func follow(_ a: PDFView, _ b: PDFView) {
        // A side that isn't on screen yet (no width) has a meaningless zoom; copying it shrank both pages.
        guard !syncing, a.bounds.width > 50, b.bounds.width > 50,
              let from = a.documentView?.enclosingScrollView?.contentView,
              let to = b.documentView?.enclosingScrollView else { return }
        syncing = true
        defer { syncing = false; zoom = left.scaleFactor; fitting = left.autoScales }
        clearHighlight()
        commitEditing()   // the typing box doesn't scroll with the page
        refreshSelection()
        if b.autoScales != a.autoScales { b.autoScales = a.autoScales }
        if !a.autoScales && abs(b.scaleFactor - a.scaleFactor) > 0.0001 { b.scaleFactor = a.scaleFactor }
        to.contentView.setBoundsOrigin(from.bounds.origin)
        to.reflectScrolledClipView(to.contentView)
    }

    // MARK: Zoom (both sides follow the left one)

    @Published var zoom: CGFloat = 1
    @Published var fitting = true

    func zoom(by factor: CGFloat) {
        left.zoom(by: factor, at: NSPoint(x: left.bounds.midX, y: left.bounds.midY))
    }

    /// Off and on again: PDFKit doesn't re-fit a view that was set up before it was on screen.
    func fitWidth() {
        for view in [left, right] {
            view.autoScales = false
            view.autoScales = true
        }
        fitting = true
        zoom = left.scaleFactor
    }

    func actualSize() {
        left.autoScales = false
        left.scaleFactor = 1
    }

    /// Typing into a field doesn't announce itself, so look twice a second at the visible pages' fields
    /// and redraw the translated side when they change.
    private func watchForm() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                var changed = false
                for page in self.left.visiblePages {
                    let i = self.original.index(for: page)
                    let state = page.annotations.filter { $0.type == "Widget" }
                        .map { "\($0.widgetStringValue ?? "")|\($0.buttonWidgetState.rawValue)" }.joined(separator: "\u{1F}")
                    if self.fieldState[i] != nil && self.fieldState[i] != state { changed = true }
                    self.fieldState[i] = state
                }
                if changed { self.redrawMirror() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Signing

    func placeSavedSignature() {
        guard Signatures.hasSaved else { return newSignature() }
        Task {
            do {
                guard let image = try await Signatures.unlockSaved() else { return newSignature() }
                place(image)
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func newSignature() {
        SignaturePadModel.open { [weak self] image in self?.place(image) }
    }

    /// From the page's right-click menu: text, a mark or a signature exactly where you clicked.
    private func add(_ kind: String, on page: PDFPage, at point: CGPoint) {
        switch kind {
        case "sign":
            guard Signatures.hasSaved else { return add("new-sign", on: page, at: point) }
            Task {
                do {
                    guard let image = try await Signatures.unlockSaved() else { return }
                    putSignature(image, on: page, at: point)
                } catch {
                    status = error.localizedDescription
                }
            }
        case "new-sign":
            SignaturePadModel.open { [weak self] image in self?.putSignature(image, on: page, at: point) }
        default:
            let mark = kind == "text" ? "" : kind
            let box = TextBoxes.make(mark, at: point, size: mark.isEmpty ? textSize : textSize * 1.3,
                                     color: Ink.remembered("textInk", default: .black))
            page.addAnnotation(box)
            selected = box
            if mark.isEmpty { beginEditing(box) } else { redrawMirror() }
        }
    }

    private func putSignature(_ image: NSImage, on page: PDFPage, at point: CGPoint) {
        let width = min(170, page.bounds(for: .mediaBox).width * 0.3)
        let height = width * image.size.height / max(image.size.width, 1)
        let signature = SignatureAnnotation(image: image, bounds: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height))
        page.addAnnotation(signature)
        selected = signature
        status = "Signed. Drag it to move it, drag its corner to resize, ✕ removes it."
        redrawMirror()
    }

    func forgetSignature() {
        Signatures.forget()
        status = "Your saved signature was removed from this Mac."
    }

    private func place(_ image: NSImage) {
        cancelPlacing()
        placing = image
        status = "Click on the form where your signature goes."
        window?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.push()
    }

    // MARK: Text

    /// "" for a text box to type into, or a mark ("✓", "✗") to stamp.
    @Published var addingText: String?
    @Published var textSize = UserDefaults.standard.object(forKey: "textSize") as? CGFloat ?? 11
    private var editing: PDFAnnotation?
    private let editor = NSTextField()
    private lazy var editorDelegate = EditorDelegate(commit: { [weak self] in self?.commitEditing() },
                                                     cancel: { [weak self] in self?.commitEditing() },
                                                     changed: { [weak self] in self?.growEditor() })

    func startText(_ mark: String = "") {
        cancelPlacing()
        addingText = mark
        status = mark.isEmpty ? "Click where the text goes, then type. Enter finishes." : "Click the box to mark it."
        window?.makeKeyAndOrderFront(nil)
        (mark.isEmpty ? NSCursor.iBeam : NSCursor.crosshair).push()
    }

    func setTextSize(_ size: CGFloat) {
        textSize = size
        UserDefaults.standard.set(size, forKey: "textSize")
    }

    private func cancelPlacing() {
        if placing != nil || addingText != nil { NSCursor.pop() }
        placing = nil
        addingText = nil
    }

    private func beginEditing(_ box: PDFAnnotation) {
        guard let page = box.page else { return }
        commitEditing()
        editing = box
        box.shouldDisplay = false
        let font = NSFont(name: "Helvetica", size: (box.font?.pointSize ?? textSize) * left.scaleFactor) ?? .systemFont(ofSize: 12)
        editor.font = font
        editor.textColor = box.fontColor ?? .black
        editor.backgroundColor = NSColor.white.withAlphaComponent(0.9)
        editor.drawsBackground = true
        editor.isBordered = true
        editor.focusRingType = .exterior
        editor.stringValue = box.contents ?? ""
        editor.delegate = editorDelegate
        let rect = left.convert(box.bounds, from: page)
        let height = ceil(font.ascender - font.descender + font.leading) + 6
        editor.frame = NSRect(x: rect.minX - 2, y: rect.maxY - height + 2, width: max(rect.width + 24, 140), height: height)
        left.addSubview(editor)
        window?.makeFirstResponder(editor)
        left.annotationsChanged(on: page)
    }

    private func growEditor() {
        guard let font = editor.font else { return }
        let width = (editor.stringValue as NSString).size(withAttributes: [.font: font]).width + 30
        editor.frame.size.width = max(editor.frame.width, width)
    }

    /// Ends typing: keeps the text (sized to fit), or drops an empty box.
    func commitEditing() {
        guard let box = editing else { return }
        editing = nil
        let text = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.removeFromSuperview()
        box.shouldDisplay = true
        if text.isEmpty {
            box.page?.removeAnnotation(box)
        } else {
            box.contents = text
            TextBoxes.fit(box)
        }
        if let page = box.page { left.annotationsChanged(on: page) }
        refreshSelection()
        redrawMirror()
    }

    // MARK: Things placed on the page (signatures and text)

    private func allSignatures() -> [(PDFPage, SignatureAnnotation)] {
        (0..<original.pageCount).compactMap(original.page(at:)).flatMap { page in
            page.annotations.compactMap { $0 as? SignatureAnnotation }.map { (page, $0) }
        }
    }

    static func placed(on page: PDFPage, at point: CGPoint) -> PDFAnnotation? {
        page.annotations.reversed().first { ($0 is SignatureAnnotation || TextBoxes.isTextBox($0)) && $0.bounds.insetBy(dx: -6, dy: -6).contains(point) }
    }

    private func mouseDown(_ page: PDFPage, _ point: CGPoint, clicks: Int) -> Bool {
        if let image = placing {
            cancelPlacing()
            putSignature(image, on: page, at: point)
            return true
        }
        if let mark = addingText {
            cancelPlacing()
            add(mark.isEmpty ? "text" : mark, on: page, at: point)
            status = "Drag text to move it, drag its corner to resize, double-click to edit, ✕ removes it."
            return true
        }
        guard let item = Self.placed(on: page, at: point) else {
            commitEditing()
            selected = nil
            return false
        }
        selected = item
        if clicks == 2, TextBoxes.isTextBox(item) {
            beginEditing(item)
            return true
        }
        commitEditing()
        dragging = (item, item.isCorner(point), CGPoint(x: point.x - item.bounds.minX, y: point.y - item.bounds.minY))
        return true
    }

    private func mouseDragged(_ page: PDFPage, _ point: CGPoint) {
        guard let (item, corner, grab) = dragging else { return }
        var b = item.bounds
        if corner {
            let width = max(TextBoxes.isTextBox(item) ? 12 : 40, point.x - b.minX)
            if TextBoxes.isTextBox(item), let font = item.font {
                // Text grows by its font, so it stays crisp and the box stays snug.
                let size = max(5, min(72, font.pointSize * width / max(b.width, 1)))
                item.font = NSFont(name: font.fontName, size: size)
                TextBoxes.fit(item)
            } else {
                let ratio = b.height / max(b.width, 1)
                b = CGRect(x: b.minX, y: b.maxY - width * ratio, width: width, height: width * ratio)
                item.bounds = b
            }
        } else {
            b.origin = CGPoint(x: point.x - grab.x, y: point.y - grab.y)
            item.bounds = b
        }
        left.annotationsChanged(on: page)
        refreshSelection()
        redrawMirror()
    }

    private func remove(_ item: PDFAnnotation) {
        if item === editing { editing = nil; editor.removeFromSuperview() }
        if item === selected { selected = nil }
        if item === hoveredPlaced { hoveredPlaced = nil }
        item.page?.removeAnnotation(item)
        refreshSelection()
        redrawMirror()
    }

    private func recolor(_ item: PDFAnnotation, _ color: NSColor) {
        if let signature = item as? SignatureAnnotation {
            signature.recolor(color)
        } else {
            item.fontColor = color
            Ink.remember(color, as: "textInk")
        }
        if let page = item.page { left.annotationsChanged(on: page) }
        refreshSelection()
        redrawMirror()
    }

    /// For screenshots (ELINGO_PLACE): a text box on the first page, selected.
    func addTestText(_ text: String) {
        guard let page = original.page(at: 0) else { return }
        let box = TextBoxes.make(text, at: CGPoint(x: 205, y: 667), size: 12, color: .black)
        page.addAnnotation(box)
        selected = box
        left.annotationsChanged(on: page)
        redrawMirror()
    }

    // MARK: Selection frame

    /// The signature or text last clicked or placed; the one under the pointer gets the frame too.
    private var selected: PDFAnnotation? { didSet { refreshSelection() } }
    private var hoveredPlaced: PDFAnnotation?
    private lazy var selection = SelectionOverlay { [weak self] in
        if let self, let item = self.selected ?? self.hoveredPlaced { self.remove(item) }
    }

    func refreshSelection() {
        guard let item = selected ?? hoveredPlaced, let page = item.page, item !== editing else {
            selection.isHidden = true
            return
        }
        selection.show(left.convert(item.bounds, from: page))
    }

    // MARK: Hover

    private func hover(_ page: PDFPage?, _ point: CGPoint) {
        let over = page.flatMap { $0 is MirrorPage ? nil : Self.placed(on: $0, at: point) }
        if over !== hoveredPlaced {
            hoveredPlaced = over
            refreshSelection()
        }
        guard let page else { return clearHighlight() }
        let index = page is MirrorPage ? mirror.document.index(for: page) : original.index(for: page)
        guard let mirrored = mirror.page(index), let passage = mirrored.passage(at: point) else { return clearHighlight() }
        hovered = passage
        if let originalPage = original.page(at: index) {
            highlights.0.show(left.convert(passage.rect, from: originalPage))
        }
        highlights.1.show(right.convert(passage.rect, from: mirrored))
    }

    private func clearHighlight() {
        hovered = nil
        highlights.0.isHidden = true
        highlights.1.isHidden = true
    }
}

/// A PDF view that reports where the pointer is, in page coordinates.
final class HoverPDFView: PDFView {
    var onHover: ((PDFPage?, CGPoint) -> Void)?
    /// Returns true when it handled the click (placing or grabbing a signature), so the form doesn't get it.
    var onMouseDown: ((PDFPage, CGPoint, Int) -> Bool)?
    var onMouseDragged: ((PDFPage, CGPoint) -> Void)?
    var onMouseUp: (() -> Void)?
    var placedAt: ((PDFPage, CGPoint) -> PDFAnnotation?)?
    var onRemove: ((PDFAnnotation) -> Void)?
    var onEdit: ((PDFAnnotation) -> Void)?
    var onRecolor: ((PDFAnnotation, NSColor) -> Void)?
    /// Delete or ⌫ with a signature or text selected removes it; otherwise the key goes to the form.
    var onDeleteKey: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if [51, 117].contains(event.keyCode), onDeleteKey?() == true { return }
        super.keyDown(with: event)
    }
    private var area: NSTrackingArea?
    private var grabbedPage: PDFPage?

    private func located(_ event: NSEvent, on fixed: PDFPage? = nil) -> (PDFPage, CGPoint)? {
        let p = convert(event.locationInWindow, from: nil)
        guard let page = fixed ?? page(for: p, nearest: true) else { return nil }
        return (page, convert(p, to: page))
    }

    override func mouseDown(with event: NSEvent) {
        if let (page, point) = located(event), onMouseDown?(page, point, event.clickCount) == true {
            grabbedPage = page
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let page = grabbedPage else { return super.mouseDragged(with: event) }
        if let (_, point) = located(event, on: page) { onMouseDragged?(page, point) }
    }

    override func mouseUp(with event: NSEvent) {
        guard grabbedPage != nil else { return super.mouseUp(with: event) }
        grabbedPage = nil
        onMouseUp?()
    }

    /// Right-click on the page (not on a signature or text): put something right there.
    var onAddHere: ((String, PDFPage, CGPoint) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let (page, point) = located(event) else { return super.menu(for: event) }
        guard let placed = placedAt?(page, point) else {
            guard let onAddHere else { return super.menu(for: event) }
            let menu = NSMenu()
            for (title, kind) in [("Add Text Here", "text"), ("Add ✓ Here", "✓"), ("Add ✗ Here", "✗"), ("-", ""),
                                  ("Sign Here", "sign"), ("New Signature Here…", "new-sign")] {
                if title == "-" { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: title, action: #selector(addHere(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = (kind, page, point)
                menu.addItem(item)
            }
            // PDFKit's own items (zoom, page layout) after ours.
            if let own = super.menu(for: event), !own.items.isEmpty {
                menu.addItem(.separator())
                for item in own.items { own.removeItem(item); menu.addItem(item) }
            }
            return menu
        }
        let isText = TextBoxes.isTextBox(placed)
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ object: Any) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = object
            menu.addItem(item)
        }
        if isText { add("Edit Text", #selector(editPlaced(_:)), placed) }
        let colours = NSMenu()
        for swatch in Ink.swatches {
            let item = NSMenuItem(title: swatch.name, action: #selector(recolorPlaced(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (placed, swatch.color)
            item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                swatch.color.setFill(); NSBezierPath(ovalIn: rect).fill(); return true
            }
            colours.addItem(item)
        }
        let colourItem = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        colourItem.submenu = colours
        menu.addItem(colourItem)
        menu.addItem(.separator())
        add(isText ? "Remove Text" : "Remove Signature", #selector(removePlaced(_:)), placed)
        return menu
    }

    @objc private func addHere(_ sender: NSMenuItem) {
        if let (kind, page, point) = sender.representedObject as? (String, PDFPage, CGPoint) { onAddHere?(kind, page, point) }
    }

    @objc private func removePlaced(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? PDFAnnotation { onRemove?(item) }
    }

    @objc private func editPlaced(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? PDFAnnotation { onEdit?(item) }
    }

    @objc private func recolorPlaced(_ sender: NSMenuItem) {
        if let (item, color) = sender.representedObject as? (PDFAnnotation, NSColor) { onRecolor?(item, color) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        guard let page = page(for: p, nearest: false) else { return onHover?(nil, .zero) ?? () }
        onHover?(page, convert(p, to: page))
    }

    /// A mouse wheel zooms around the pointer (hold ⌥ to scroll instead). Trackpads keep scrolling, and
    /// pinch or ⌘-scroll zoom. Mouse wheels send whole notches; trackpads send precise deltas.
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.option) && event.scrollingDeltaY != 0 {
            return zoom(by: event.scrollingDeltaY > 0 ? 1.12 : 1 / 1.12, at: point)
        }
        if event.hasPreciseScrollingDeltas && event.modifierFlags.contains(.command) && event.scrollingDeltaY != 0 {
            return zoom(by: 1 + max(-0.2, min(0.2, event.scrollingDeltaY * 0.01)), at: point)
        }
        super.scrollWheel(with: event)
    }

    /// Changes the zoom keeping the spot under `point` where it is.
    func zoom(by factor: CGFloat, at point: NSPoint) {
        guard let document = documentView, let scroll = document.enclosingScrollView else { return }
        let old = scaleFactor
        let new = min(max(old * factor, minScaleFactor), maxScaleFactor)
        guard abs(new - old) > 0.0001 else { return }
        let before = document.convert(point, from: self)
        let offset = NSPoint(x: before.x - scroll.contentView.bounds.minX, y: before.y - scroll.contentView.bounds.minY)
        autoScales = false
        scaleFactor = new
        let after = NSPoint(x: before.x * new / old, y: before.y * new / old)
        scroll.contentView.setBoundsOrigin(NSPoint(x: after.x - offset.x, y: after.y - offset.y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil, .zero)
    }
}

/// The dashed frame round a signature or text, with a resize handle (bottom right) and ✕ (top right).
/// Only the ✕ takes clicks; everything else falls through to the page, where dragging moves or resizes.
final class SelectionOverlay: NSView {
    private let border = CAShapeLayer()
    private let handle = CALayer()
    private let close = NSButton()
    private let onClose: () -> Void
    private let margin: CGFloat = 9   // room outside the frame for the ✕ and the handle

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        border.fillColor = nil
        border.strokeColor = NSColor.controlAccentColor.cgColor
        border.lineWidth = 1.5
        border.lineDashPattern = [5, 3]
        layer?.addSublayer(border)
        handle.backgroundColor = NSColor.white.cgColor
        handle.borderColor = NSColor.controlAccentColor.cgColor
        handle.borderWidth = 1.5
        handle.cornerRadius = 2
        layer?.addSublayer(handle)
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        close.isBordered = false
        close.contentTintColor = .systemRed
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = "Remove"
        addSubview(close)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeClicked() { onClose() }

    func show(_ rect: NSRect) {
        frame = rect.insetBy(dx: -margin - 3, dy: -margin - 3)
        isHidden = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inner = bounds.insetBy(dx: margin, dy: margin)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.path = CGPath(roundedRect: inner, cornerWidth: 3, cornerHeight: 3, transform: nil)
        handle.frame = CGRect(x: inner.maxX - 4, y: (isFlipped ? inner.maxY : inner.minY) - 4, width: 8, height: 8)
        CATransaction.commit()
        close.frame = NSRect(x: inner.maxX - 9, y: (isFlipped ? inner.minY : inner.maxY) - 9, width: 18, height: 18)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        return close.frame.insetBy(dx: -2, dy: -2).contains(local) ? close : nil
    }
}

/// Enter or Esc ends typing in a text box; the box grows as you type.
final class EditorDelegate: NSObject, NSTextFieldDelegate {
    let commit: () -> Void, cancel: () -> Void, changed: () -> Void
    init(commit: @escaping () -> Void, cancel: @escaping () -> Void, changed: @escaping () -> Void) {
        self.commit = commit; self.cancel = cancel; self.changed = changed
    }
    func controlTextDidChange(_ obj: Notification) { changed() }
    func controlTextDidEndEditing(_ obj: Notification) { commit() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }
}

/// The outline drawn round the passage under the pointer, on both sides at once.
final class HighlightView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 2
        layer?.cornerRadius = 3
        layer?.borderColor = NSColor.systemOrange.cgColor
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never steal a click from the form

    func show(_ rect: NSRect) {
        frame = rect.insetBy(dx: -3, dy: -3)
        isHidden = false
    }
}

private struct PDFHost: NSViewRepresentable {
    let view: PDFView
    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ view: PDFView, context: Context) {}
}

struct TranslatePDFView: View {
    @ObservedObject var model: TranslateModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("From", selection: $model.sourceID) {
                    Text(model.detected.map { "Detect (\(Translator.name($0)))" } ?? "Detect language").tag("auto")
                    Divider()
                    ForEach(model.languages, id: \.minimalIdentifier) { Text(Translator.name($0)).tag($0.minimalIdentifier) }
                }
                .frame(width: 250)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("To", selection: $model.targetID) {
                    ForEach(model.languages, id: \.minimalIdentifier) { Text(Translator.name($0)).tag($0.minimalIdentifier) }
                }
                .frame(width: 220)
                Spacer()
                Menu {
                    Button("Add Text") { model.startText() }
                    Button("Add ✓ Mark") { model.startText("✓") }
                    Button("Add ✗ Mark") { model.startText("✗") }
                    Divider()
                    Picker("Text Size", selection: Binding(get: { model.textSize }, set: { model.setTextSize($0) })) {
                        Text("Small").tag(CGFloat(9))
                        Text("Medium").tag(CGFloat(11))
                        Text("Large").tag(CGFloat(14))
                    }
                } label: {
                    Label("Text", systemImage: "character.cursor.ibeam")
                } primaryAction: {
                    model.startText()
                }
                .fixedSize()
                .help("Click, then click on the page and type. The arrow has ✓ / ✗ marks and sizes.")
                Menu {
                    Button("Place My Signature") { model.placeSavedSignature() }.disabled(!Signatures.hasSaved)
                    Button("New Signature…") { model.newSignature() }
                    Divider()
                    Button("Forget My Saved Signature") { model.forgetSignature() }.disabled(!Signatures.hasSaved)
                } label: {
                    Label("Sign", systemImage: "signature")
                } primaryAction: {
                    model.placeSavedSignature()
                }
                .fixedSize()
                .help("Click to place your saved signature (asks for Touch ID or your password); the arrow makes a new one")
                Menu("Save") {
                    Button("Signed & Locked PDF…") { model.saveLocked() }
                        .keyboardShortcut("s")
                    Button("Filled PDF, Still Editable…") { model.saveFilled() }
                        .keyboardShortcut("s", modifiers: [.command, .option])
                    Divider()
                    Button("Translation as PDF…") { model.saveTranslation() }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                }
                .fixedSize()
            }
            .padding(10)

            HStack(spacing: 0) {
                pane("Original · fill it in here", model.left)
                Divider()
                pane("Translation · for reading", model.right)
                    .overlay(alignment: .top) {
                        if model.busy {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text(model.status).font(.system(size: 13, weight: .medium))
                                // Some pairs (those that go through English, like German → Hebrew) take
                                // Apple's translator a minute; a ticking count shows it hasn't stalled.
                                TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                                    let seconds = Int(context.date.timeIntervalSince(model.startedAt))
                                    if seconds >= 3 { Text("\(seconds)s").monospacedDigit().foregroundStyle(.secondary) }
                                }
                                .font(.system(size: 12))
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.quaternary))
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                            .padding(.top, 44)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: model.busy)
            }

            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                if let p = model.hovered {
                    Text(p.original).foregroundStyle(.secondary).lineLimit(2)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Text(p.translation).lineLimit(2)
                } else {
                    Text(model.status).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    Button { model.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("Zoom out (⌘−, or turn the mouse wheel)")
                    Text("\(Int((model.zoom * 100).rounded()))%").monospacedDigit().frame(width: 46)
                    Button { model.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("Zoom in (⌘+, or turn the mouse wheel)")
                    Divider().frame(height: 16).padding(.horizontal, 6)
                    Button("Fit") { model.fitWidth() }
                        .help("Fit the page to the width (⌘0)")
                        .foregroundStyle(model.fitting ? accent : .primary)
                    Button("100%") { model.actualSize() }
                        .help("Actual size")
                }
                .buttonStyle(.borderless)
                .fixedSize()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
        .onChange(of: model.sourceID) { model.translate() }
        .onChange(of: model.targetID) {
            model.translate()
            model.onTargetChosen?(model.targetID)
        }
    }

    private func pane(_ title: String, _ view: PDFView) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 5)
            PDFHost(view: view)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Tour (for App Review's screen recording)

extension TranslateModel {
    /// Types `text` onto the first page at `point`, as the Text tool would.
    func tourType(_ text: String, at point: CGPoint) {
        guard let page = original.page(at: 0) else { return }
        let box = TextBoxes.make(text, at: point, size: 12, color: .black)
        page.addAnnotation(box)
        selected = box
        left.annotationsChanged(on: page)
        redrawMirror()
    }

    /// Places a typed signature on the first page at `point`.
    func tourSign(_ name: String, at point: CGPoint) {
        guard let page = original.page(at: 0),
              let image = Signatures.image(typed: name, color: Ink.swatches[0].color) else { return }
        putSignature(image, on: page, at: point)
    }

    /// Saves the signed & locked copy to `url` (no save panel), and says so.
    func tourSaveLocked(to url: URL) {
        try? FileManager.default.removeItem(at: url)
        do {
            try Signatures.writeLocked(original, to: url, title: url.deletingPathExtension().lastPathComponent)
            status = "Saved \(url.lastPathComponent): answers and signature are part of the pages now, and the file is locked against editing."
            signedCopy = url
        } catch {
            status = error.localizedDescription
        }
    }
}
