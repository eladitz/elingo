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
    private var dragging: (signature: SignatureAnnotation, corner: Bool, grab: CGPoint)?

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
        left.onMouseDown = { [weak self] page, point in self?.mouseDown(page, point) ?? false }
        left.onMouseDragged = { [weak self] page, point in self?.mouseDragged(page, point) }
        left.onMouseUp = { [weak self] in self?.dragging = nil }
        left.signatureAt = { page, point in Self.signature(on: page, at: point) }
        left.onRemove = { [weak self] signature in self?.remove(signature) }
        left.addSubview(highlights.0)
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
        guard let image = Signatures.saved else { return newSignature() }
        place(image)
    }

    func newSignature() {
        SignaturePadModel.open { [weak self] image in self?.place(image) }
    }

    private func place(_ image: NSImage) {
        placing = image
        status = "Click on the form where your signature goes."
        window?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.push()
    }

    private func allSignatures() -> [(PDFPage, SignatureAnnotation)] {
        (0..<original.pageCount).compactMap(original.page(at:)).flatMap { page in
            page.annotations.compactMap { $0 as? SignatureAnnotation }.map { (page, $0) }
        }
    }

    static func signature(on page: PDFPage, at point: CGPoint) -> SignatureAnnotation? {
        page.annotations.reversed().compactMap { $0 as? SignatureAnnotation }.first { $0.bounds.insetBy(dx: -6, dy: -6).contains(point) }
    }

    private func mouseDown(_ page: PDFPage, _ point: CGPoint) -> Bool {
        if let image = placing {
            placing = nil
            NSCursor.pop()
            let width = min(170, page.bounds(for: .mediaBox).width * 0.3)
            let height = width * image.size.height / max(image.size.width, 1)
            let signature = SignatureAnnotation(image: image, bounds: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height))
            page.addAnnotation(signature)
            status = "Signed. Drag it to move it, drag its bottom-right corner to resize, or right-click to remove it."
            redrawMirror()
            return true
        }
        guard let signature = Self.signature(on: page, at: point) else { return false }
        dragging = (signature, signature.isCorner(point), CGPoint(x: point.x - signature.bounds.minX, y: point.y - signature.bounds.minY))
        return true
    }

    private func mouseDragged(_ page: PDFPage, _ point: CGPoint) {
        guard let (signature, corner, grab) = dragging else { return }
        var b = signature.bounds
        if corner {
            let ratio = b.height / max(b.width, 1)
            let width = max(40, point.x - b.minX)
            b = CGRect(x: b.minX, y: b.maxY - width * ratio, width: width, height: width * ratio)
        } else {
            b.origin = CGPoint(x: point.x - grab.x, y: point.y - grab.y)
        }
        signature.bounds = b
        left.annotationsChanged(on: page)
        redrawMirror()
    }

    private func remove(_ signature: SignatureAnnotation) {
        signature.page?.removeAnnotation(signature)
        redrawMirror()
    }

    // MARK: Hover

    private func hover(_ page: PDFPage?, _ point: CGPoint) {
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
    var onMouseDown: ((PDFPage, CGPoint) -> Bool)?
    var onMouseDragged: ((PDFPage, CGPoint) -> Void)?
    var onMouseUp: (() -> Void)?
    var signatureAt: ((PDFPage, CGPoint) -> SignatureAnnotation?)?
    var onRemove: ((SignatureAnnotation) -> Void)?
    private var area: NSTrackingArea?
    private var grabbedPage: PDFPage?

    private func located(_ event: NSEvent, on fixed: PDFPage? = nil) -> (PDFPage, CGPoint)? {
        let p = convert(event.locationInWindow, from: nil)
        guard let page = fixed ?? page(for: p, nearest: true) else { return nil }
        return (page, convert(p, to: page))
    }

    override func mouseDown(with event: NSEvent) {
        if let (page, point) = located(event), onMouseDown?(page, point) == true {
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

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let (page, point) = located(event), let signature = signatureAt?(page, point) else { return super.menu(for: event) }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Remove Signature", action: #selector(removeSignature(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = signature
        menu.addItem(item)
        return menu
    }

    @objc private func removeSignature(_ sender: NSMenuItem) {
        if let signature = sender.representedObject as? SignatureAnnotation { onRemove?(signature) }
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
                    Button("Place My Signature") { model.placeSavedSignature() }.disabled(Signatures.saved == nil)
                    Button("New Signature…") { model.newSignature() }
                } label: {
                    Label("Sign", systemImage: "signature")
                } primaryAction: {
                    model.placeSavedSignature()
                }
                .fixedSize()
                .help("Click to place your signature; the arrow makes a new one")
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
