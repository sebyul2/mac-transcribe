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
    /// Delivered on the main thread after every change: the full translated
    /// log (for the transcript window) and the caption tail (for the subtitle
    /// overlay — only the newest sentence + in-progress tail, so captions
    /// never reach back into old dialogue while fresh translations are still
    /// in flight).
    var onDisplay: ((_ full: String, _ caption: String) -> Void)?

    /// Normalized completed sentence → frozen translation. Keys strip
    /// whitespace and punctuation because the recognizer keeps re-drawing
    /// sentence boundaries (especially Chinese punctuation arrives late); a
    /// raw-text key would miss the cache on every such wobble and re-translate
    /// sentences that were already on screen.
    private var translations: [String: String] = [:]
    private var pending: Set<String> = []
    private var lastFullText = ""
    /// Bumped on reset() so late callbacks from a previous session are ignored.
    private var gen = 0

    /// On-device translator; used whenever the session came up successfully.
    private let onDevice = AppleTranslator()
    private var onDeviceReady = false

    /// Tail (in-progress sentence) re-translation state. Requests overlap —
    /// up to `maxTailInFlight` fly concurrently and a sequence number keeps
    /// only the newest result on screen — so a slow response never blocks the
    /// next refresh.
    private var tailTranslation: (source: String, text: String)?
    private var tailSeq = 0
    private var tailAppliedSeq = 0
    private var tailInFlightCount = 0
    private var lastRequestedTail = ""
    private var lastTailRequestAt = Date.distantPast
    private let maxTailInFlight = 2
    /// How often the unfinished tail may be re-translated. On-device requests
    /// cost tens of milliseconds, so they can run nearly per-update; LLM round
    /// trips take ~1 s, so overlapping requests are spaced out a little
    /// (streamed partials fill the gap).
    private var tailInterval: TimeInterval { onDeviceReady ? 0.25 : 0.45 }
    /// Don't bother translating a tail shorter than this many characters.
    private let tailMinLength = 4
    /// Fires while a session runs so a tail spoken just before a pause still
    /// gets translated even though no new feed() arrives.
    private var tailTimer: Timer?
    /// How many preceding sentences ride along as LLM prompt context.
    private let contextSentences = 2

    func reset() {
        gen &+= 1
        translations.removeAll()
        pending.removeAll()
        lastFullText = ""
        tailTranslation = nil
        tailSeq = 0
        tailAppliedSeq = 0
        tailInFlightCount = 0
        lastRequestedTail = ""
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
        // Translate each newly completed sentence, with its preceding
        // sentences (and their translations, when known) as context. Streamed
        // partials show up immediately and the final result overwrites them.
        for (index, sentence) in parts.completed.enumerated() {
            let key = Self.normalizedKey(sentence)
            guard translations[key] == nil, !pending.contains(key) else { continue }
            pending.insert(key)
            let (context, contextTranslation) = promptContext(before: index, in: parts.completed)
            requestTranslation(
                of: sentence,
                context: context,
                contextTranslation: contextTranslation,
                onPartial: { [weak self] _, partial in
                    self?.translations[key] = partial
                },
                apply: { [weak self] _, translated in
                    self?.translations[key] = translated
                }
            )
        }
        maybeTranslateTail()
        emit()
    }

    /// Cache key for a sentence: content only, ignoring whitespace and
    /// punctuation, so late-arriving or re-drawn punctuation still hits.
    private static func normalizedKey(_ sentence: String) -> String {
        let stripped = sentence.filter { !$0.isWhitespace && !$0.isPunctuation }
        return stripped.isEmpty ? sentence : stripped
    }

    /// The last few sentences before `index`, joined, plus their joined
    /// translations (only when every one is already translated — a partial
    /// pairing would misalign the prompt).
    private func promptContext(before index: Int, in completed: [String]) -> (String?, String?) {
        let previous = completed[..<index].suffix(contextSentences)
        guard !previous.isEmpty else { return (nil, nil) }
        let translated = previous.compactMap { translations[Self.normalizedKey($0)] }
        return (
            previous.joined(separator: " "),
            translated.count == previous.count ? translated.joined(separator: " ") : nil
        )
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
        guard tailInFlightCount < maxTailInFlight else { return }
        guard lastRequestedTail != tail, tailTranslation?.source != tail else { return }
        guard Date().timeIntervalSince(lastTailRequestAt) >= tailInterval else { return }

        tailSeq += 1
        let seq = tailSeq
        tailInFlightCount += 1
        lastRequestedTail = tail
        lastTailRequestAt = Date()
        let (context, contextTranslation) = promptContext(before: parts.completed.count, in: parts.completed)
        let myGen = gen
        requestTranslation(
            of: tail,
            context: context,
            contextTranslation: contextTranslation,
            isFragment: true,
            onPartial: { [weak self] source, partial in
                guard let self, seq >= self.tailAppliedSeq else { return }
                self.tailAppliedSeq = seq
                self.tailTranslation = (source, partial)
            },
            apply: { [weak self] source, translated in
                guard let self, myGen == self.gen else { return }
                self.tailInFlightCount -= 1
                // Overlapping requests may complete out of order; an older
                // response must never replace a newer tail on screen.
                if seq >= self.tailAppliedSeq {
                    self.tailAppliedSeq = seq
                    self.tailTranslation = (source, translated)
                }
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
        contextTranslation: String?,
        isFragment: Bool = false,
        onPartial: ((String, String) -> Void)? = nil,
        apply: @escaping (String, String) -> Void
    ) {
        let myGen = gen

        func finish(_ translated: String?) {
            DispatchQueue.main.async { [weak self] in
                guard let self, myGen == self.gen else { return }
                self.pending.remove(Self.normalizedKey(text))
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
    /// Source text is never shown — mixed-language captions read worse than a
    /// sub-second gap while a translation is in flight. (A failed translation
    /// still falls back to its source via apply(), so content can't vanish.)
    var displayText: String {
        let parts = split(lastFullText)
        var pieces = parts.completed.compactMap { translations[Self.normalizedKey($0)] }
        if let tail = parts.tail, let t = tailTranslation, tail.hasPrefix(t.source) {
            pieces.append(t.text)
        }
        return pieces.joined(separator: " ")
    }

    /// What the subtitle overlay shows: the newest completed sentence's
    /// translation (when it has arrived) plus the live tail. Deliberately NOT
    /// a suffix of displayText — there, sentences whose translations are still
    /// in flight drop out, so the "last two sentences" would reach back into
    /// old dialogue and captions would jump between past and present.
    var captionText: String {
        let parts = split(lastFullText)
        var pieces: [String] = []
        if let last = parts.completed.last, let translated = translations[Self.normalizedKey(last)] {
            pieces.append(translated)
        }
        if let tail = parts.tail, let t = tailTranslation, tail.hasPrefix(t.source) {
            pieces.append(t.text)
        }
        return pieces.joined(separator: " ")
    }

    private func emit() {
        onDisplay?(displayText, captionText)
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
