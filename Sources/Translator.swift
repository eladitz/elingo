// Apple's on-device translation (the Translation framework): free, private, ~50 languages.
// A language pair that isn't on the Mac yet is downloaded once; macOS shows its own prompt for that,
// which needs a SwiftUI view in a window to hang off (`TranslatorHost`).

import SwiftUI
import Translation

@MainActor
final class Translator: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    private var waiting: CheckedContinuation<Void, Error>?
    private var cache: [String: String] = [:]
    private var running = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    private let debug = ProcessInfo.processInfo.environment["ELINGO_DEBUG"] != nil

    static func supportedLanguages() async -> [Locale.Language] {
        var seen = Set<String>()
        return await LanguageAvailability().supportedLanguages
            .filter { seen.insert($0.minimalIdentifier).inserted }
            .sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
    }

    static func name(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier)?.capitalized(with: .current)
            ?? language.minimalIdentifier
    }

    /// Translates `texts` in one go, keeping their order. Repeats (a header on every page) are remembered.
    /// One request at a time: several files open at once all ask together, and a language download
    /// must be asked for (and answered) once, not once per file.
    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        if running { await withCheckedContinuation { queue.append($0) } } else { running = true }
        defer { if queue.isEmpty { running = false } else { queue.removeFirst().resume() } }
        let key = { (text: String) in "\(source.minimalIdentifier)>\(target.minimalIdentifier)|\(text)" }
        let missing = Array(Set(texts.filter { cache[key($0)] == nil }))
        if !missing.isEmpty {
            try await ensureInstalled(source, target)
            let session = TranslationSession(installedSource: source, target: target)
            let requests = missing.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
            for response in try await session.translations(from: requests) {
                if let i = response.clientIdentifier.flatMap(Int.init) { cache[key(missing[i])] = response.targetText }
            }
        }
        return texts.map { cache[key($0)] ?? $0 }
    }

    private func ensureInstalled(_ source: Locale.Language, _ target: Locale.Language) async throws {
        let status = await LanguageAvailability().status(from: source, to: target)
        if debug { print("availability", source.minimalIdentifier, "→", target.minimalIdentifier, status) }
        switch status {
        case .installed: return
        case .unsupported: throw TranslateError("Apple's translation can't translate \(Self.name(source)) into \(Self.name(target)) yet.")
        default:
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                waiting = c
                configuration = .init(source: source, target: target)
            }
        }
    }

    /// Called by `TranslatorHost` with a session that may download the languages (macOS asks the user).
    func prepare(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            waiting?.resume()
        } catch {
            waiting?.resume(throwing: TranslateError("The languages weren't downloaded, so this can't be translated yet."))
        }
        waiting = nil
    }
}

struct TranslateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Invisible; lives in the window so macOS has somewhere to show its language download prompt.
struct TranslatorHost: View {
    @ObservedObject var translator: Translator
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(translator.configuration) { session in await translator.prepare(session) }
    }
}
