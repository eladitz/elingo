// `--tour <form.pdf> <output folder>`: Elingo uses itself, step by step at a watchable pace, for the screen
// recording App Review asks new developers for. Everything shown is the real app doing real work; it plays
// on a plain backdrop so nothing else on the screen is in the recording, then quits.

import AppKit

@MainActor
enum Tour {
    /// The display with the menu bar: the one the recording is made of (not "the main screen", which is
    /// whichever screen the active window happens to be on).
    static var screen: NSScreen { NSScreen.screens.first! }

    private static var backdrop: NSWindow?

    static func run(form: URL, output: URL) {
        stage()
        Task {
            func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            await pause(1.5)
            Workspace.open([form])
            if let window = Workspace.current?.window {
                // On the recorded display, in front.
                let v = screen.visibleFrame.insetBy(dx: 60, dy: 40)
                window.setFrame(v, display: true)
                window.orderFrontRegardless()
            }
            await pause(7)   // detect the language and translate
            guard let model = Workspace.current?.model else { NSApp.terminate(nil); return }
            for (text, y) in [("Muster", 693.0), ("Alex", 663.0), ("01.02.1990", 633.0)] {
                model.tourType(text, at: CGPoint(x: 205, y: y))
                await pause(1.6)
            }
            model.tourSign("Alex Muster", at: CGPoint(x: 150, y: 560))
            await pause(3)
            let saved = output.appendingPathComponent(form.deletingPathExtension().lastPathComponent + " (signed).pdf")
            model.tourSaveLocked(to: saved)
            await pause(3)
            Workspace.open([saved])   // the locked result, in the file list beside the original
            await pause(5)
            NSApp.terminate(nil)
        }
    }

    /// A plain dark backdrop over the main screen, behind Elingo's windows.
    private static func stage() {
        let screen = Tour.screen
        let window = NSWindow(contentRect: screen.visibleFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.14, alpha: 1)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.level = .normal
        window.orderFrontRegardless()
        backdrop = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
