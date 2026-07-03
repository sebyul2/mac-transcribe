import Foundation

/// One-way simultaneous interpretation over the long-form transcript stream,
/// using the standard re-translation pattern for live captions:
///
/// - Completed sentences are translated once (with the preceding sentences and
///   their translations as context for pronoun/terminology consistency) and
///   then frozen, so the display doesn't flicker.
/// - The still-spoken tail is re-translated on a short throttle so the screen
///   keeps up with speech.
/// - A tail that stops growing for a moment is force-completed: the recognizer
///   often withholds punctuation across utterance boundaries, which would
///   otherwise chain separate utterances into one endless "sentence".
///
/// Translation is a two-tier hybrid:
/// - Apple's on-device Translation framework (tens of milliseconds) puts a
///   draft on screen almost instantly and drives the fast tail refresh.
/// - The LLM (~1-2 s, prompt context, better quality) replaces each
///   sentence's draft as its result lands and is what freezes on screen.
/// When the on-device model isn't available for the pair, the LLM serves both
/// roles, with streamed partials filling the draft gap.
final class InterpreterEngine {
    /// English name of the target language, interpolated into the LLM prompt.
    var targetLanguage = "English"
    /// Delivered on the main thread after every change: the full translated
    /// log (for the transcript window) and the caption pieces (for the
    /// subtitle overlay — only the newest sentences + in-progress tail, so
    /// captions never reach back into old dialogue; `isFinal` distinguishes
    /// the LLM's frozen result from fast drafts so the overlay can tint them).
    var onDisplay: ((_ full: String, _ caption: [(text: String, isFinal: Bool)]) -> Void)?
    /// How many trailing sentences (plus the live tail) captions may show.
    static let captionSentences = 2

    /// Normalized completed sentence → LLM translation (frozen once set).
    /// Keys strip whitespace and punctuation because the recognizer keeps
    /// re-drawing sentence boundaries (Chinese punctuation especially arrives
    /// late); a raw-text key would miss the cache on every such wobble and
    /// re-translate sentences that were already on screen.
    private var finals: [String: String] = [:]
    /// Normalized sentence → fast draft (on-device result, promoted tail
    /// translation, or streamed LLM partial). Shown until finals wins.
    private var drafts: [String: String] = [:]
    private var pending: Set<String> = []
    private var draftPending: Set<String> = []
    private var lastFullText = ""
    /// Bumped on reset() so late callbacks from a previous session are ignored.
    private var gen = 0

    /// On-device translator; drafts and tail refresh whenever it came up.
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
    private var tailInterval: TimeInterval { onDeviceReady ? 0.15 : 0.45 }
    /// Don't bother translating a tail shorter than this many characters.
    private let tailMinLength = 4
    /// Ticks while a session runs: drives tail re-translation between feeds
    /// and the silence-based forced sentence breaks.
    private var tailTimer: Timer?
    /// How many preceding sentences ride along as LLM prompt context.
    private let contextSentences = 2

    /// Forced sentence breaks: tails the recognizer never punctuated but that
    /// went silent long enough to treat as finished utterances. Applied on top
    /// of punctuation-based splitting, in order, as prefixes of the raw tail.
    private var forcedSentences: [String] = []
    private var lastObservedTail = ""
    private var tailStableSince: Date?
    /// How long the tail must stay unchanged before it is force-completed.
    private let forcedBreakDelay: TimeInterval = 1.0

    func reset() {
        gen &+= 1
        finals.removeAll()
        drafts.removeAll()
        pending.removeAll()
        draftPending.removeAll()
        lastFullText = ""
        tailTranslation = nil
        tailSeq = 0
        tailAppliedSeq = 0
        tailInFlightCount = 0
        lastRequestedTail = ""
        lastTailRequestAt = .distantPast
        forcedSentences.removeAll()
        lastObservedTail = ""
        tailStableSince = nil
        tailTimer?.invalidate()
        tailTimer = nil
    }

    /// Bring up the on-device session for this pair; until (and unless) it
    /// reports ready, the LLM covers drafts too. Call teardown() afterwards.
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
        pruneForcedSentences()
        startTailTimerIfNeeded()
        processTranscript()
    }

    /// Translates whatever the current transcript needs — newly completed
    /// sentences and the tail — then re-emits the display.
    private func processTranscript() {
        let parts = split(lastFullText)
        for (index, sentence) in parts.completed.enumerated() {
            let key = Self.normalizedKey(sentence)

            // A sentence that just completed was, until this instant, the
            // tail — promote its latest tail translation to the sentence's
            // draft so the caption never waits on a fresh round trip.
            if finals[key] == nil, drafts[key] == nil,
               let t = tailTranslation, Self.normalizedKey(t.source) == key {
                drafts[key] = t.text
            }

            // Fast draft: on-device puts something readable up in ~100 ms
            // while the LLM round trip is still in flight.
            if onDeviceReady, finals[key] == nil, drafts[key] == nil, !draftPending.contains(key) {
                draftPending.insert(key)
                requestOnDevice(sentence) { [weak self] draft in
                    guard let self else { return }
                    self.draftPending.remove(key)
                    if let draft, self.finals[key] == nil { self.drafts[key] = draft }
                }
            }

            // Quality pass: the LLM result replaces the draft and freezes.
            guard finals[key] == nil, !pending.contains(key) else { continue }
            pending.insert(key)
            let (context, contextTranslation) = promptContext(before: index, in: parts.completed)
            requestLLM(
                sentence,
                context: context,
                contextTranslation: contextTranslation,
                // With a draft on screen, streamed partials would only make
                // the caption regress to a half sentence; without on-device
                // they are the draft.
                onPartial: onDeviceReady ? nil : { [weak self] partial in
                    self?.drafts[key] = partial
                },
                completion: { [weak self] final in
                    guard let self else { return }
                    self.pending.remove(key)
                    if let final {
                        self.finals[key] = final
                    } else if self.drafts[key] == nil {
                        // Both tiers failed — keep the source rather than
                        // silently dropping what was said.
                        self.finals[key] = sentence
                    }
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

    private func translatedText(for sentence: String) -> String? {
        let key = Self.normalizedKey(sentence)
        return finals[key] ?? drafts[key]
    }

    /// The last few sentences before `index`, joined, plus their joined
    /// translations (only when every one has some translation — a partial
    /// pairing would misalign the prompt).
    private func promptContext(before index: Int, in completed: [String]) -> (String?, String?) {
        let previous = completed[..<index].suffix(contextSentences)
        guard !previous.isEmpty else { return (nil, nil) }
        let translated = previous.compactMap { translatedText(for: $0) }
        return (
            previous.joined(separator: " "),
            translated.count == previous.count ? translated.joined(separator: " ") : nil
        )
    }

    // MARK: - Timer: tail refresh + forced sentence breaks

    private func startTailTimerIfNeeded() {
        guard tailTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkForcedBreak()
            self?.maybeTranslateTail()
        }
        RunLoop.main.add(timer, forMode: .common)
        tailTimer = timer
    }

    /// Force-complete a tail that has stopped growing: the speaker paused, but
    /// the recognizer withheld punctuation, so without this the next utterance
    /// would chain onto the same "sentence" indefinitely.
    private func checkForcedBreak() {
        let parts = split(lastFullText)
        guard let tail = parts.tail, tail.count >= tailMinLength else {
            tailStableSince = nil
            lastObservedTail = ""
            return
        }
        if tail != lastObservedTail {
            lastObservedTail = tail
            tailStableSince = Date()
            return
        }
        if let since = tailStableSince, Date().timeIntervalSince(since) >= forcedBreakDelay {
            forcedSentences.append(tail)
            tailStableSince = nil
            lastObservedTail = ""
            // The promoted sentence needs its quality pass right away.
            processTranscript()
        }
    }

    /// Drops forced breaks that no longer line up with the transcript — the
    /// recognizer re-drew the text, or real punctuation arrived and the raw
    /// split absorbed them.
    private func pruneForcedSentences() {
        var tail = rawSplit(lastFullText).tail
        var kept: [String] = []
        for forced in forcedSentences {
            guard let t = tail, t.hasPrefix(forced) else { break }
            kept.append(forced)
            let rest = String(t.dropFirst(forced.count)).trimmingCharacters(in: .whitespaces)
            tail = rest.isEmpty ? nil : rest
        }
        forcedSentences = kept
    }

    // MARK: - Tail re-translation

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

        // Overlapping requests may complete out of order; an older response
        // must never replace a newer tail on screen.
        let applyTail: (String?) -> Void = { [weak self] translated in
            guard let self else { return }
            self.tailInFlightCount -= 1
            if let translated, seq >= self.tailAppliedSeq {
                self.tailAppliedSeq = seq
                self.tailTranslation = (tail, translated)
            }
            // The tail may have grown while this was in flight; check again.
            self.maybeTranslateTail()
        }

        if onDeviceReady {
            requestOnDevice(tail, completion: applyTail)
            return
        }
        let (context, contextTranslation) = promptContext(before: parts.completed.count, in: parts.completed)
        requestLLM(
            tail,
            context: context,
            contextTranslation: contextTranslation,
            isFragment: true,
            onPartial: { [weak self] partial in
                guard let self, seq >= self.tailAppliedSeq else { return }
                self.tailAppliedSeq = seq
                self.tailTranslation = (tail, partial)
            },
            completion: applyTail
        )
    }

    // MARK: - Backends

    /// On-device translation. `completion` runs on the main thread with a
    /// trimmed non-empty result or nil, guarded by the generation token;
    /// emit() follows automatically.
    private func requestOnDevice(_ text: String, completion: @escaping (String?) -> Void) {
        let myGen = gen
        onDevice.translate(text) { translated in
            DispatchQueue.main.async { [weak self] in
                guard let self, myGen == self.gen else { return }
                let trimmed = translated?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                completion(trimmed.isEmpty ? nil : trimmed)
                self.emit()
            }
        }
    }

    /// LLM translation. Same contract as requestOnDevice; `onPartial`
    /// additionally streams the accumulated output as SSE deltas arrive.
    private func requestLLM(
        _ text: String,
        context: String?,
        contextTranslation: String?,
        isFragment: Bool = false,
        onPartial: ((String) -> Void)? = nil,
        completion: @escaping (String?) -> Void
    ) {
        let myGen = gen
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
                        deliver(trimmed)
                        self.emit()
                    }
                }
            }
        ) { result in
            DispatchQueue.main.async { [weak self] in
                guard let self, myGen == self.gen else { return }
                if case .success(let translated) = result {
                    let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                    completion(trimmed.isEmpty ? nil : trimmed)
                } else {
                    completion(nil)
                }
                self.emit()
            }
        }
    }

    // MARK: - Display

    /// Every sentence's best translation (LLM final, else fast draft) plus the
    /// live tail. Source text is never shown — mixed-language captions read
    /// worse than a brief gap while a translation is in flight. (A sentence
    /// whose translations all failed falls back to its source in the feed
    /// path, so content can't silently vanish.)
    var displayText: String {
        let parts = split(lastFullText)
        var pieces = parts.completed.compactMap { translatedText(for: $0) }
        if let tail = parts.tail, let t = tailTranslation, tail.hasPrefix(t.source) {
            pieces.append(t.text)
        }
        return pieces.joined(separator: " ")
    }

    /// What the subtitle overlay shows: the newest completed sentences'
    /// translations (when they have arrived) plus the live tail, each flagged
    /// with whether it is the LLM's frozen result (isFinal) or a fast draft.
    /// Deliberately NOT a suffix of displayText — there, sentences whose
    /// translations are still in flight drop out, so a "last N sentences" cut
    /// would reach back into old dialogue and captions would jump between
    /// past and present.
    var captionPieces: [(text: String, isFinal: Bool)] {
        let parts = split(lastFullText)
        var pieces: [(text: String, isFinal: Bool)] = []
        for sentence in parts.completed.suffix(Self.captionSentences) {
            let key = Self.normalizedKey(sentence)
            if let final = finals[key] {
                pieces.append((final, true))
            } else if let draft = drafts[key] {
                pieces.append((draft, false))
            }
        }
        if let tail = parts.tail, let t = tailTranslation, tail.hasPrefix(t.source) {
            pieces.append((t.text, false))
        }
        return pieces
    }

    private func emit() {
        onDisplay?(displayText, captionPieces)
    }

    // MARK: - Sentence splitting

    private static let terminators: Set<Character> = [".", "?", "!", "。", "？", "！"]

    /// Punctuation-based split plus the forced (silence-based) breaks applied
    /// to the tail, in order.
    private func split(_ text: String) -> (completed: [String], tail: String?) {
        var (completed, tail) = rawSplit(text)
        for forced in forcedSentences {
            guard let t = tail, t.hasPrefix(forced) else { break }
            completed.append(forced)
            let rest = String(t.dropFirst(forced.count)).trimmingCharacters(in: .whitespaces)
            tail = rest.isEmpty ? nil : rest
        }
        return (completed, tail)
    }

    /// Splits into completed sentences and the in-progress tail (nil when the
    /// text ends on a sentence terminator).
    private func rawSplit(_ text: String) -> (completed: [String], tail: String?) {
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
