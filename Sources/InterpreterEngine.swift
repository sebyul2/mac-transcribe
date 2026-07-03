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
///
/// Translation backend, fastest first:
/// - Apple's on-device Translation framework when the language pair's model is
///   installed — tens of milliseconds per request, so the throttle tightens.
/// - Otherwise the configured LLM with zero reasoning effort and streamed
///   partials (words render as SSE deltas arrive instead of ~2 s later).
final class InterpreterEngine {
    /// English name of the target language, interpolated into the LLM prompt.
    var targetLanguage = "English"
    /// Combined display text, delivered on the main thread.
    var onDisplay: ((String) -> Void)?

    /// Completed sentence → frozen translation.
    private var translations: [String: String] = [:]
    private var pending: Set<String> = []
    private var lastFullText = ""
    /// Bumped on reset() so late callbacks from a previous session are ignored.
    private var gen = 0

    /// On-device translator; used whenever the session came up successfully.
    private let onDevice = AppleTranslator()
    private var onDeviceReady = false

    /// Tail (in-progress sentence) re-translation state.
    private var tailTranslation: (source: String, text: String)?
    private var tailInFlight = false
    private var lastTailRequestAt = Date.distantPast
    /// How often the unfinished tail may be re-translated. On-device requests
    /// cost tens of milliseconds, so they can run nearly per-update; LLM round
    /// trips take ~1 s, so they are spaced out (streamed partials fill the gap).
    private var tailInterval: TimeInterval { onDeviceReady ? 0.25 : 0.6 }
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

    /// Bring up the on-device session for this pair; until (and unless) it
    /// reports ready, requests go to the LLM. Call teardown() after the session.
    func prepareOnDevice(source: Locale.Language, target: Locale.Language) {
        onDeviceReady = false
        onDevice.start(source: source, target: target) { [weak self] ready in
            self?.onDeviceReady = ready
        }
    }

    func teardown() {
        onDevice.stop()
        onDeviceReady = false
    }

    /// Maps the stored target-language prompt string to the framework language.
    static func localeLanguage(forPrompt prompt: String) -> Locale.Language {
        switch prompt {
        case "Korean": return Locale.Language(identifier: "ko")
        case "Japanese": return Locale.Language(identifier: "ja")
        case "Simplified Chinese": return Locale.Language(identifier: "zh-Hans")
        default: return Locale.Language(identifier: "en")
        }
    }

    /// Full accumulated transcript from the recognizer (main thread).
    func feed(_ fullText: String) {
        lastFullText = fullText
        startTailTimerIfNeeded()

        let parts = split(fullText)
        // Translate each newly completed sentence, with its predecessor (and
        // that predecessor's translation, when known) as context. Streamed
        // partials show up immediately and the final result overwrites them.
        for (index, sentence) in parts.completed.enumerated() {
            guard translations[sentence] == nil, !pending.contains(sentence) else { continue }
            pending.insert(sentence)
            let previous = index > 0 ? parts.completed[index - 1] : nil
            requestTranslation(
                of: sentence,
                context: previous,
                onPartial: { [weak self] sentence, partial in
                    self?.translations[sentence] = partial
                },
                apply: { [weak self] sentence, translated in
                    self?.translations[sentence] = translated
                }
            )
        }
        maybeTranslateTail()
        emit()
    }

    // MARK: - Tail re-translation

    private func startTailTimerIfNeeded() {
        guard tailTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
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
        requestTranslation(
            of: tail,
            context: context,
            isFragment: true,
            onPartial: { [weak self] source, partial in
                self?.tailTranslation = (source, partial)
            },
            apply: { [weak self] source, translated in
                guard let self, myGen == self.gen else { return }
                self.tailInFlight = false
                self.tailTranslation = (source, translated)
                // The tail may have grown while this was in flight; check again.
                self.maybeTranslateTail()
            }
        )
    }

    /// Routes one translation to the fastest available backend. `onPartial`
    /// and `apply` are both invoked on the main thread, guarded by the
    /// generation token; `apply` always fires exactly once at the end.
    private func requestTranslation(
        of text: String,
        context: String?,
        isFragment: Bool = false,
        onPartial: ((String, String) -> Void)? = nil,
        apply: @escaping (String, String) -> Void
    ) {
        let myGen = gen

        func finish(_ translated: String?) {
            DispatchQueue.main.async { [weak self] in
                guard let self, myGen == self.gen else { return }
                self.pending.remove(text)
                let trimmed = translated?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // Keep the original visible rather than blocking the feed.
                apply(text, trimmed.isEmpty ? text : trimmed)
                self.emit()
            }
        }

        if onDeviceReady {
            onDevice.translate(text) { translated in
                finish(translated)
            }
            return
        }

        let contextTranslation = context.flatMap { translations[$0] }
        LLMRefiner.translate(
            text,
            to: targetLanguage,
            context: context,
            contextTranslation: contextTranslation,
            isFragment: isFragment,
            onPartial: onPartial.map { deliver in
                { partial in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, myGen == self.gen else { return }
                        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        deliver(text, trimmed)
                        self.emit()
                    }
                }
            }
        ) { result in
            switch result {
            case .success(let translated): finish(translated)
            case .failure: finish(nil)
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
