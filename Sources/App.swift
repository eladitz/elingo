// Elingo: open a PDF in any language, fill it in and sign it, while a mirrored copy beside it shows every
// passage translated into your language. Translation is Apple's, on this Mac; nothing is uploaded.

import SwiftUI
import UniformTypeIdentifiers
import PDFKit

let accent = Color(red: 0.22, green: 0.45, blue: 0.95)

/// Built for the Mac App Store (`./build.sh appstore`): sandboxed, and the Store does the updating.
enum Distribution {
    #if APPSTORE
    static let appStore = true
    #else
    static let appStore = false
    #endif
}

@MainActor
enum Windows {
    private static var open: [NSWindow] = []

    @discardableResult
    static func show<V: View>(_ title: String, size: NSSize, _ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(size)
        window.center()
        open.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated { open.removeAll { $0 === note.object as? NSWindow } }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openedFiles = false
    private var welcome: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        if devCommand() { return }
        // Finder's right-click ▸ Translate with Elingo (under Quick Actions or Services).
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        Donation.usageLine = { "You've saved \($0) documents with it so far." }
        Donation.start()
        #if !APPSTORE
        Updater.start()   // the App Store does the updating there
        #endif
        // Files double-clicked or dropped on the icon arrive just after launch; only greet if none did.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.openedFiles else { return }
            self.showWelcome()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { Donation.recordDay() }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedFiles = true
        open(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWelcome() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func open(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { return }
        welcome?.close()
        pdfs.forEach(NSDocumentController.shared.noteNewRecentDocumentURL)
        Workspace.open(pdfs)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    private func showWelcome() {
        if let welcome, welcome.isVisible { return welcome.makeKeyAndOrderFront(nil) }
        welcome = Windows.show("Elingo", size: NSSize(width: 520, height: 360), WelcomeView(open: { [weak self] in self?.openDocument(nil) },
                                                                                             drop: { [weak self] urls in self?.open(urls) }))
    }

    @objc func translateFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        openedFiles = true
        open(urls)
    }

    @objc func website(_ sender: Any?) { NSWorkspace.shared.open(URL(string: "https://ai.itzkin.com/elingo.html")!) }
    @objc func donate(_ sender: Any?) { NSWorkspace.shared.open(Donation.page) }
    @objc func checkForUpdates(_ sender: Any?) { Task { await Updater.check(manual: true) } }
    @objc func zoomIn(_ sender: Any?) { Workspace.current?.model?.zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { Workspace.current?.model?.zoom(by: 1 / 1.25) }
    @objc func fitWidth(_ sender: Any?) { Workspace.current?.model?.fitWidth() }
    @objc func actualSize(_ sender: Any?) { Workspace.current?.model?.actualSize() }
    @objc func nextFile(_ sender: Any?) { Workspace.current?.step(1) }
    @objc func previousFile(_ sender: Any?) { Workspace.current?.step(-1) }

    /// Development aids, no window shown unless asked:
    ///   --export <in.pdf> <out.pdf> <language>    translate and save the mirrored copy
    ///   --lock <in.pdf> <out.pdf> [signature.png]  sign (bottom right of the last page) and save locked
    ///   --snapshot <out.png> <in.pdf>...           open the window, then capture it
    private func devCommand() -> Bool {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--tour"), i + 2 < args.count {
            Tour.run(form: URL(fileURLWithPath: args[i + 1]), output: URL(fileURLWithPath: args[i + 2]))
            return true
        }
        if let i = args.firstIndex(of: "--export"), i + 3 < args.count, let doc = PDFDocument(url: URL(fileURLWithPath: args[i + 1])) {
            Task {
                let mirror = Mirror(doc)
                guard let source = mirror.detectLanguage() else { print("no text"); exit(1) }
                print("detected", source.minimalIdentifier)
                let translator = Translator()
                for page in 0..<doc.pageCount {
                    let texts = mirror.passages(onPage: page).map(\.text)
                    do {
                        let out = try await translator.translate(texts, from: source, to: Locale.Language(identifier: args[i + 3]))
                        for (a, b) in zip(texts, out) { print("·", a, "→", b) }
                        mirror.apply(out, onPage: page)
                    } catch { print("error", error.localizedDescription); exit(1) }
                }
                do { try mirror.export(to: URL(fileURLWithPath: args[i + 2])) } catch { print(error); exit(1) }
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--lock"), i + 2 < args.count, let doc = PDFDocument(url: URL(fileURLWithPath: args[i + 1])) {
            if i + 3 < args.count, let image = NSImage(contentsOfFile: args[i + 3]), let page = doc.page(at: doc.pageCount - 1) {
                let box = page.bounds(for: .mediaBox)
                page.addAnnotation(SignatureAnnotation(image: image, bounds: CGRect(x: box.maxX - 230, y: box.minY + 60, width: 170, height: 170 * image.size.height / image.size.width)))
            }
            // ELINGO_TEXT="Muster|✓": text boxes down the first page, as if typed with the Text tool.
            if let texts = ProcessInfo.processInfo.environment["ELINGO_TEXT"], let page = doc.page(at: 0) {
                for (n, text) in texts.split(separator: "|").enumerated() {
                    page.addAnnotation(TextBoxes.make(String(text), at: CGPoint(x: 205, y: 667 - CGFloat(n) * 40), size: 12, color: .black))
                }
            }
            do { try Signatures.writeLocked(doc, to: URL(fileURLWithPath: args[i + 2]), title: "Test") } catch { print(error); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count {
            Workspace.open(args[(i + 2)...].map { URL(fileURLWithPath: $0) })
            if let text = ProcessInfo.processInfo.environment["ELINGO_PLACE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { Workspace.current?.model?.addTestText(text) }
            }
            // ELINGO_ZOOM=2: zoom by that much just before the capture, to check zooming and the sync.
            if let factor = ProcessInfo.processInfo.environment["ELINGO_ZOOM"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Workspace.current?.model?.zoom(by: factor) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (ProcessInfo.processInfo.environment["ELINGO_SNAP_DELAY"].flatMap(Double.init) ?? 15)) {
                if let window = Workspace.current?.window {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-o", "-l", String(window.windowNumber), args[i + 1]]
                    try? p.run()
                    p.waitUntilExit()
                }
                exit(0)
            }
            return true
        }
        return false
    }

    private func buildMenus() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem?]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.compactMap { $0 }.forEach(menu.addItem)
            let holder = NSMenuItem()
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        _ = add("Elingo", [
            item("About Elingo", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            Distribution.appStore ? nil : item("Check for Updates…", #selector(checkForUpdates(_:)), target: self),
            .separator(),
            item("Elingo Website", #selector(website(_:)), target: self),
            item("Support Elingo on Ko-fi…", #selector(donate(_:)), target: self),
            .separator(),
            item("Hide Elingo", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Elingo", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = add("File", [
            item("Open…", #selector(openDocument(_:)), "o", target: self),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        _ = add("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        _ = add("Go", [
            item("Next File", #selector(nextFile(_:)), "]", target: self),
            item("Previous File", #selector(previousFile(_:)), "[", target: self),
        ])
        _ = add("View", [
            item("Zoom In", #selector(zoomIn(_:)), "+", target: self),
            item("Zoom Out", #selector(zoomOut(_:)), "-", target: self),
            item("Fit to Width", #selector(fitWidth(_:)), "0", target: self),
            item("Actual Size", #selector(actualSize(_:)), "0", [.command, .option], target: self),
        ])
        let window = add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}

struct WelcomeView: View {
    let open: () -> Void
    let drop: ([URL]) -> Void
    @ObservedObject private var hovering = Flag()

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("Drop a PDF here").font(.title2.weight(.semibold))
            Text("Fill it in and sign it on the left. On the right, the same pages in your language.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 360)
            Button("Open PDF…", action: open).buttonStyle(.borderedProminent).tint(accent).keyboardShortcut("o")
            Text("Translation runs on this Mac. Nothing is uploaded.").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(hovering.on ? accent : .clear, style: StrokeStyle(lineWidth: 2, dash: [6])).padding(10))
        .onDrop(of: [.fileURL], isTargeted: $hovering.on) { providers in
            loadDroppedURLs(providers, then: drop)
            return true
        }
    }
}

/// Collects every dropped file first, so several PDFs arrive together (one window, one batch).
func loadDroppedURLs(_ providers: [NSItemProvider], then done: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async { if let url { urls.append(url) }; group.leave() }
        }
    }
    group.notify(queue: .main) { done(urls) }
}

/// Stands in for @State, whose macro the Command Line Tools can't build.
final class Flag: ObservableObject {
    @Published var on = false
}

@main
enum Entry {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
