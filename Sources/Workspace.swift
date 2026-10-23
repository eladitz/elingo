// One window for every PDF you open: the file list on the left, the selected file's two pages on the right.
// Each file keeps its own answers, signature and translation; all of them translate as soon as they're
// added, so the next one is ready when you get to it.

import SwiftUI
import PDFKit

@MainActor
final class Workspace: ObservableObject {
    static var current: Workspace?

    @Published var files: [TranslateModel] = []
    @Published var selected: URL?
    let translator = Translator()
    weak var window: NSWindow?

    var model: TranslateModel? { files.first { $0.url == selected } ?? files.first }

    /// Adds the PDFs to the open window (making one if there's none) and shows the first of them.
    static func open(_ urls: [URL]) {
        let workspace = current.flatMap { $0.window?.isVisible == true ? $0 : nil } ?? {
            let workspace = Workspace()
            let size = NSScreen.main.map { NSSize(width: min(1600, $0.visibleFrame.width - 60), height: min(960, $0.visibleFrame.height - 50)) }
                ?? NSSize(width: 1400, height: 860)
            workspace.window = Windows.show("Elingo", size: size, WorkspaceView(workspace: workspace))
            current = workspace
            return workspace
        }()
        workspace.add(urls)
        workspace.window?.makeKeyAndOrderFront(nil)
    }

    func add(_ urls: [URL]) {
        var failed: [String] = []
        var first: URL?
        for url in urls {
            if let known = files.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                first = first ?? known.url
                continue
            }
            guard let model = TranslateModel(url: url, translator: translator) else {
                failed.append(url.lastPathComponent)
                continue
            }
            model.window = window
            model.onTargetChosen = { [weak self, weak model] id in
                for other in self?.files ?? [] where other !== model && other.targetID != id {
                    other.targetID = id
                    other.translate()
                }
            }
            files.append(model)
            first = first ?? url
        }
        if let first { select(first) }
        if !failed.isEmpty {
            NSAlert(error: TranslateError("Couldn't open \(failed.joined(separator: ", ")) as a PDF.")).runModal()
        }
    }

    func select(_ url: URL) {
        window?.makeFirstResponder(nil)   // finish the field being typed in before switching
        selected = url
        // Once the file's views are in the window, fit them (unless you'd zoomed that file yourself).
        DispatchQueue.main.async { [weak self] in
            if let model = self?.model, model.fitting { model.fitWidth() }
        }
        window?.title = files.count > 1 ? "Elingo — \(url.lastPathComponent) (\(index + 1) of \(files.count))" : "Elingo — \(url.lastPathComponent)"
    }

    private var index: Int { files.firstIndex { $0.url == selected } ?? 0 }

    func step(_ by: Int) {
        guard !files.isEmpty else { return }
        let next = index + by
        guard files.indices.contains(next) else { return NSSound.beep() }
        select(files[next].url)
    }

    func remove(_ model: TranslateModel) {
        guard let i = files.firstIndex(where: { $0 === model }) else { return }
        files.remove(at: i)
        if files.isEmpty { window?.close(); return }
        if selected == model.url { select(files[min(i, files.count - 1)].url) }
        else { select(selected ?? files[0].url) }
    }
}

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 0) {
            FileList(workspace: workspace)
                .frame(width: 230)
            Divider()
            if let model = workspace.model {
                TranslatePDFView(model: model)
                    .id(model.url)   // fresh views per file, so each keeps its own scroll and zoom
            } else {
                Color.clear
            }
            TranslatorHost(translator: workspace.translator)
        }
    }
}

private struct FileList: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var dropping = Flag()

    var body: some View {
        VStack(spacing: 0) {
            Text(workspace.files.count == 1 ? "1 file" : "\(workspace.files.count) files").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
            List(selection: Binding(get: { workspace.selected ?? workspace.files.first?.url }, set: { if let url = $0 { workspace.select(url) } })) {
                ForEach(workspace.files, id: \.url) { model in
                    FileRow(model: model)
                        .tag(model.url)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.url]) }
                            if let signed = model.signedCopy {
                                Button("Show Signed Copy in Finder") { NSWorkspace.shared.activateFileViewerSelecting([signed]) }
                            }
                            Divider()
                            Button("Remove from List") { workspace.remove(model) }
                        }
                }
            }
            .listStyle(.sidebar)
            Text("Drop more PDFs here to add them")
                .font(.system(size: 11)).foregroundStyle(dropping.on ? AnyShapeStyle(accent) : AnyShapeStyle(.tertiary))
                .padding(.top, 6)
            HStack {
                Button { workspace.step(-1) } label: { Image(systemName: "chevron.up") }
                    .help("Previous file (⌘[)")
                Button { workspace.step(1) } label: { Label("Next File", systemImage: "chevron.down") }
                    .help("Next file (⌘])")
                Spacer()
                Button { (NSApp.delegate as? AppDelegate)?.openDocument(nil) } label: { Image(systemName: "plus") }
                    .help("Add more PDFs")
            }
            .padding(10)
        }
        .background(.background.secondary)
        .overlay {
            if dropping.on {
                RoundedRectangle(cornerRadius: 10).strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping.on) { providers in
            loadDroppedURLs(providers) { urls in
                let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
                if pdfs.isEmpty { NSSound.beep() } else { workspace.add(pdfs) }
            }
            return true
        }
    }
}

private struct FileRow: View {
    @ObservedObject var model: TranslateModel

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: model.original.page(at: 0)?.thumbnail(of: NSSize(width: 64, height: 84), for: .mediaBox) ?? NSImage())
                .resizable().aspectRatio(contentMode: .fit).frame(width: 30, height: 40)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.quaternary))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.url.deletingPathExtension().lastPathComponent).lineLimit(3).truncationMode(.middle)
                    .help(model.url.lastPathComponent)
                HStack(spacing: 4) {
                    if model.signedCopy != nil {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("Signed copy saved")
                    } else if model.busy {
                        ProgressView().controlSize(.mini)
                        Text("Translating…")
                    } else {
                        Text(subtitle)
                    }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        let pages = model.original.pageCount == 1 ? "1 page" : "\(model.original.pageCount) pages"
        return model.detected.map { "\(Translator.name($0)) · \(pages)" } ?? pages
    }
}
