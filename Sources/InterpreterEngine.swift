import Foundation

/// One-way simultaneous interpretation over the long-form transcript stream,
/// using the standard re-translation pattern for live captions:
///
/// - Completed sentences are translated once (with the preceding sentence and
///   its translation as context for pronoun/terminology consistency) and then
///   frozen, so the display doesn't flicker.
/// - The still-spoken tail is re-translated on a short throttle so the screen
///   keeps up with speech; while a newer tail is in flight, the last tail
///   translation is shown with the freshly spoken original appended.
/// - Prompts are minimal — no glossary, low effort — because latency wins here.
final class InterpreterEngine {
    /// English name of the target language, interpolated into the prompt.
    var targetLanguage = "English"
    /// Combined display text, delivered on the main thread.
    var onDisplay: ((String) -> Void)?

    /// Completed sentence → frozen translation.
    private var translations: [String: String] = [:]
    private var pending: Set<String> = []
    private var lastFullText = ""
    /// Bumped on reset() so late callbacks from a previous session are ignored.
    private var gen = 0

    /// Tail (in-progress sentence) re-translation state.
    private var tailTranslation: (source: String, text: String)?
    private var tailInFlight = false
    private var lastTailRequestAt = Date.distantPast
    /// How often the unfinished tail may be re-translated.
    private let tailInterval: TimeInterval = 1.2
    /// Don't bother translating a tail shorter than this many characters.
    private let tailMinLength = 4
    /// Fires while a session runs so a tail spoken just before a pause still
    /// gets translated even though no new feed() arrives.
    private var tailTimer: Timer?

    func reset() {
        gen &+= 1
        translations.removeAll()
        pending.removeAll()
        lastFullText = ""
        tailTranslation = nil
        tailInFlight = false
        lastTailRequestAt = .distantPast
        tailTimer?.invalidate()
        tailTimer = nil
    }

    /// Full accumulated transcript from the recognizer (main thread).
    func feed(_ fullText: String) {
        lastFullText = fullText
        startTailTimerIfNeeded()

        let parts = split(fullText)
        // Translate each newly completed sentence, with its predecessor (and
        // that predecessor's translation, when known) as context.
        for (index, sentence) in parts.completed.enumerated() {
            guard translations[sentence] == nil, !pending.contains(sentence) else { continue }
            pending.insert(sentence)
            let previous = index > 0 ? parts.completed[index - 1] : nil
            requestTranslation(of: sentence, context: previous) { [weak self] sentence, translated in
                self?.translations[sentence] = translated
            }
        }
        maybeTranslateTail()
        emit()
    }

    // MARK: - Tail re-translation

    private func startTailTimerIfNeeded() {
        guard tailTimer == nil else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.maybeTranslateTail()
        }
        RunLoop.main.add(timer, forMode: .common)
        tailTimer = timer
    }

    private func maybeTranslateTail() {
        let parts = split(lastFullText)
        guard let tail = parts.tail, tail.count >= tailMinLength else { return }
        guard !tailInFlight else { return }
        guard tailTranslation?.source != tail else { return }
        guard Date().timeIntervalSince(lastTailRequestAt) >= tailInterval else { return }

        tailInFlight = true
        lastTailRequestAt = Date()
        let context = parts.completed.last
        let myGen = gen
        requestTranslation(of: tail, context: context, isFragment: true) { [weak self] source, translated in
            guard let self, myGen == self.gen else { return }
            self.tailInFlight = false
            self.tailTranslation = (source, translated)
            // The tail may have grown while this was in flight; check again.
            self.maybeTranslateTail()
        }
    }

    private func requestTranslation(
        of text: String,
        context: String?,
        isFragment: Bool = false,
        apply: @escaping (String, String) -> Void
    ) {
        let myGen = gen
        let contextTranslation = context.flatMap { translations[$0] }
        LLMRefiner.translate(
            text,
            to: targetLanguage,
            context: context,
            contextTranslation: contextTranslation,
            isFragment: isFragment
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, myGen == self.gen else { return }
                self.pending.remove(text)
                switch result {
                case .success(let translated):
                    let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                    apply(text, trimmed.isEmpty ? text : trimmed)
                case .failure:
                    // Keep the original visible rather than blocking the feed.
                    apply(text, text)
                }
                self.emit()
            }
        }
    }

    // MARK: - Display

    /// Frozen sentence translations plus the best available tail rendering.
    var displayText: String {
        let parts = split(lastFullText)
        var pieces = parts.completed.map { translations[$0] ?? $0 }
        if let tail = parts.tail {
            if let t = tailTranslation, tail.hasPrefix(t.source) {
                // Show the translated portion plus whatever was spoken since.
                let grown = String(tail.dropFirst(t.source.count)).trimmingCharacters(in: .whitespaces)
                pieces.append(grown.isEmpty ? t.text : "\(t.text) \(grown)")
            } else {
                pieces.append(tail)
            }
        }
        return pieces.joined(separator: " ")
    }

    private func emit() {
        onDisplay?(displayText)
    }

    // MARK: - Sentence splitting

    private static let terminators: Set<Character> = [".", "?", "!", "。", "？", "！"]

    /// Splits into completed sentences and the in-progress tail (nil when the
    /// text ends on a sentence terminator).
    private func split(_ text: String) -> (completed: [String], tail: String?) {
        var completed: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if Self.terminators.contains(ch) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { completed.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        return (completed, tail.isEmpty ? nil : tail)
    }
}
