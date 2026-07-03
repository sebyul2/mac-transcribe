import Foundation

/// One-way simultaneous interpretation over the long-form transcript stream.
///
/// Structure comes from the audio, not the text: LongFormTranscriber's
/// voice-activity detector reports a break whenever flowing speech goes
/// silent for half a second — a far sharper utterance boundary than the
/// recognizer's punctuation (withheld for seconds) or text inactivity (which
/// misfires on recognition lag). At each break the in-progress tail is
/// force-completed, the utterance ends (new line in the log), and translation
/// context stops crossing the boundary, so consecutive speakers are neither
/// glued into one endless sentence nor translated as one voice.
///
/// Rendering uses the standard re-translation pattern for live captions:
/// - Completed sentences are translated once and frozen, so the display
///   doesn't flicker.
/// - The still-spoken tail is re-translated on a short throttle so the screen
///   keeps up with speech.
///
/// Translation is a two-tier hybrid:
/// - Apple's on-device Translation framework (tens of milliseconds) puts a
///   draft on screen almost instantly and drives the fast tail refresh.
/// - The LLM (~1-2 s, prompt context within the utterance, better quality)
///   replaces each sentence's draft as its result lands and freezes it.
/// When the on-device model isn't available for the pair, the LLM serves both
/// roles, with streamed partials filling the draft gap.
final class InterpreterEngine {
    /// English name of the target language, interpolated into the LLM prompt.
    var targetLanguage = "English"
    /// Delivered on the main thread after every change: the full translated
    /// log (transcript window; one line per utterance/speaker turn) and the
    /// caption pieces (subtitle overlay — only the newest sentences +
    /// in-progress tail; `isFinal` distinguishes the LLM's frozen result from
    /// fast drafts so the overlay can tint them).
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
    /// Last-resort cut: a tail this long is force-completed even without any
    /// pause or punctuation, so the quality pass can never be starved for
    /// tens of seconds by a speaker (or soundtrack) that simply doesn't stop.
    private let maxTailLength = 60
    /// Drives tail re-translation between feeds (a tail spoken just before a
    /// pause must still be translated even though no new feed() arrives).
    private var tailTimer: Timer?
    /// How many preceding sentences (same utterance only) ride along as LLM
    /// prompt context.
    private let contextSentences = 2

    /// Sentence breaks imposed by voice-activity silence, applied on top of
    /// punctuation-based splitting as prefixes of the raw tail. Stored with
    /// their normalized key so a match survives punctuation that the
    /// recognizer back-fills later.
    private var forcedBreaks: [(text: String, key: String)] = []
    /// Normalized keys of sentences that END an utterance (a speaker pause
    /// followed them). Line breaks in the log and context barriers for the
    /// translator.
    private var utteranceEndKeys: Set<String> = []

    func reset() {
        gen &+= 1
        finals.removeAll()
        drafts.removeAll()
        pending.removeAll()
        draftPending.removeAll()
        lastFullText = ""
        stableKeys.removeAll()
        tailTranslation = nil
        tailSeq = 0
        tailAppliedSeq = 0
        tailInFlightCount = 0
        lastRequestedTail = ""
        lastTailRequestAt = .distantPast
        forcedBreaks.removeAll()
        utteranceEndKeys.removeAll()
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

    // MARK: - Inputs

    /// Full accumulated transcript from the recognizer (main thread), plus
    /// how many leading characters are finalized (stable). Single "\n"s are
    /// sentence pauses, "\n\n"s are speaker-turn pauses — both detected from
    /// the recognizer's word timing (see LongFormTranscriber).
    func feed(_ fullText: String, stableLength: Int) {
        lastFullText = fullText
        // Only sentences that lie entirely inside the finalized prefix get
        // the LLM quality pass: their boundaries are exact and will never be
        // re-drawn, so each is translated exactly once. Volatile sentences
        // (forced cuts included) would be re-segmented on finalization and
        // translated again — pure duplicate spend.
        stableKeys = Set(rawSplit(String(fullText.prefix(stableLength))).completed.map(Self.normalizedKey))
        markUtteranceEnds()
        pruneForcedBreaks()
        startTailTimerIfNeeded()
        processTranscript()
    }

    /// Normalized keys of sentences inside the finalized transcript prefix.
    private var stableKeys: Set<String> = []

    /// "\n\n" = speaker-turn boundary: mark the sentence that closes each
    /// turn so the log breaks lines there and translation context never
    /// crosses it. Single "\n" sentence pauses do NOT break context — one
    /// speaker's consecutive sentences still inform each other's translation.
    private func markUtteranceEnds() {
        let turns = lastFullText.components(separatedBy: "\n\n")
        guard turns.count > 1 else { return }
        for turn in turns.dropLast() {
            let parts = rawSplit(turn)
            if let last = parts.tail ?? parts.completed.last {
                utteranceEndKeys.insert(Self.normalizedKey(last))
            }
        }
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
            // Restricted to stable (finalized) sentences whenever drafts have
            // another source — volatile boundaries get re-drawn on
            // finalization and would be paid for twice. Without on-device
            // translation the LLM must draft volatile sentences too.
            guard finals[key] == nil, !pending.contains(key),
                  stableKeys.contains(key) || !onDeviceReady else { continue }
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

    /// The sentences immediately before `index`, joined, plus their joined
    /// translations — but never across an utterance boundary: the pause means
    /// the speaker (and voice) likely changed, and carrying the previous
    /// speaker's words as context makes the LLM translate separate remarks as
    /// one continuous thought. Translations attach only when every context
    /// sentence has one (a partial pairing would misalign the prompt).
    private func promptContext(before index: Int, in completed: [String]) -> (String?, String?) {
        var previous: [String] = []
        for sentence in completed[..<index].reversed() {
            if utteranceEndKeys.contains(Self.normalizedKey(sentence)) { break }
            previous.insert(sentence, at: 0)
            if previous.count == contextSentences { break }
        }
        guard !previous.isEmpty else { return (nil, nil) }
        let translated = previous.compactMap { translatedText(for: $0) }
        return (
            previous.joined(separator: " "),
            translated.count == previous.count ? translated.joined(separator: " ") : nil
        )
    }

    // MARK: - Forced breaks (voice-activity cuts)

    /// Drops forced breaks that no longer line up with the transcript — the
    /// recognizer re-drew the text beyond punctuation differences. Matching is
    /// done in normalized space so punctuation the recognizer back-fills after
    /// the cut doesn't invalidate the break.
    private func pruneForcedBreaks() {
        var tail = rawSplit(lastFullText).tail
        var kept: [(text: String, key: String)] = []
        for forced in forcedBreaks {
            guard let t = tail, let (head, rest) = Self.consumeNormalizedPrefix(of: t, key: forced.key) else { break }
            kept.append((head, forced.key))
            tail = rest.isEmpty ? nil : rest
        }
        forcedBreaks = kept
    }

    /// If `text` starts with the content of `key` (ignoring whitespace and
    /// punctuation), returns that leading sentence — including any trailing
    /// punctuation the recognizer added — and the remainder. Nil when the
    /// recognizer rewrote the words themselves.
    private static func consumeNormalizedPrefix(of text: String, key: String) -> (head: String, rest: String)? {
        var keyIterator = key.makeIterator()
        var nextKey = keyIterator.next()
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if !(ch.isWhitespace || ch.isPunctuation) {
                guard let expected = nextKey, ch == expected else { return nil }
                nextKey = keyIterator.next()
            }
            index = text.index(after: index)
            if nextKey == nil {
                // Key consumed — absorb trailing punctuation/space into the head.
                while index < text.endIndex, text[index].isWhitespace || text[index].isPunctuation {
                    index = text.index(after: index)
                }
                let head = String(text[..<index]).trimmingCharacters(in: .whitespaces)
                let rest = String(text[index...]).trimmingCharacters(in: .whitespaces)
                return (head, rest)
            }
        }
        return nil
    }

    // MARK: - Tail re-translation

    private func startTailTimerIfNeeded() {
        guard tailTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkTailOverrun()
            self?.maybeTranslateTail()
        }
        RunLoop.main.add(timer, forMode: .common)
        tailTimer = timer
    }

    /// Cut a runaway tail into a sentence (no utterance mark — the speaker is
    /// still going) so translation keeps flowing through continuous speech.
    private func checkTailOverrun() {
        let parts = split(lastFullText)
        guard let tail = parts.tail, tail.count >= maxTailLength else { return }
        forcedBreaks.append((tail, Self.normalizedKey(tail)))
        processTranscript()
    }

    private func maybeTranslateTail() {
        let parts = split(lastFullText)
        guard let tail = parts.tail, tail.count >= tailMinLength else { return }
        // Watchdog: if both slots have been stuck for 10 s, a response was
        // lost (dead stream, dropped continuation) — reclaim them rather than
        // silently freezing the caption for the rest of the session.
        if tailInFlightCount >= maxTailInFlight,
           Date().timeIntervalSince(lastTailRequestAt) > 10 {
            tailInFlightCount = 0
        }
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
    /// live tail, one line per utterance so speaker turns read as dialogue.
    /// Source text is never shown — mixed-language captions read worse than a
    /// brief gap while a translation is in flight. (A sentence whose
    /// translations all failed falls back to its source in the feed path, so
    /// content can't silently vanish.)
    var displayText: String {
        let parts = split(lastFullText)
        var lines: [String] = []
        var currentLine: [String] = []
        for sentence in parts.completed {
            if let translated = translatedText(for: sentence) {
                currentLine.append(translated)
            }
            if utteranceEndKeys.contains(Self.normalizedKey(sentence)), !currentLine.isEmpty {
                lines.append(currentLine.joined(separator: " "))
                currentLine = []
            }
        }
        if let tail = parts.tail, let t = tailTranslation, tail.hasPrefix(t.source) {
            currentLine.append(t.text)
        }
        if !currentLine.isEmpty { lines.append(currentLine.joined(separator: " ")) }
        return lines.joined(separator: "\n")
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

    /// Newline is a terminator too: LongFormTranscriber inserts one at every
    /// speech pause it detects from the recognizer's audio timestamps, so an
    /// utterance completes even when the recognizer withholds punctuation.
    private static let terminators: Set<Character> = [".", "?", "!", "。", "？", "！", "\n"]

    /// Punctuation-based split plus the forced (silence-based) breaks applied
    /// to the tail, in order.
    private func split(_ text: String) -> (completed: [String], tail: String?) {
        var (completed, tail) = rawSplit(text)
        for forced in forcedBreaks {
            guard let t = tail, let (head, rest) = Self.consumeNormalizedPrefix(of: t, key: forced.key) else { break }
            completed.append(head)
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
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { completed.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        return (completed, tail.isEmpty ? nil : tail)
    }
}
