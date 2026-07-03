import Foundation

/// One-way simultaneous interpretation over the long-form transcript stream.
///
/// The unit of translation is the speaker TURN, not the sentence. The
/// transcriber marks turns with "\n\n" (real speech pauses found in the
/// recognizer's word timing) and sentences with "\n"; translating a turn as
/// one piece lets the model see the sentences together — no more fragments
/// like a Korean sentence split before its final particle — and costs fewer
/// requests than sentence-by-sentence.
///
/// Rendering follows the professional live-caption pattern:
/// - Closed turns are translated once, with the previous turn as context,
///   and frozen (white).
/// - The open (still-spoken) turn is re-translated whole by the LLM on a
///   ~1 s throttle; only the newest response ever renders (dimmed).
/// - Whatever tail the LLM hasn't covered yet is drafted by Apple's
///   on-device translator (~100 ms) so captions track speech in real time.
/// When the on-device model is unavailable the LLM's streamed partials fill
/// that gap instead.
final class InterpreterEngine {
    /// English name of the target language, interpolated into the LLM prompt.
    var targetLanguage = "English"
    /// Delivered on the main thread after every change: the full translated
    /// log (one line per speaker turn) and the caption pieces (the newest
    /// turns; `isFinal` marks frozen LLM results so the overlay can promote
    /// them from dimmed to white).
    var onDisplay: ((_ full: String, _ caption: [(text: String, isFinal: Bool)]) -> Void)?
    /// How many trailing turn lines captions may show.
    static let captionTurns = 2

    // MARK: - State

    /// Closed turn key → frozen LLM translation.
    private var frozen: [String: String] = [:]
    /// Closed turn key → best draft while its quality pass is in flight
    /// (inherited from the open-turn translation, or on-device).
    private var drafts: [String: String] = [:]
    private var frozenPending: Set<String> = []
    private var draftPending: Set<String> = []

    /// Latest LLM translation of the open turn (sourceKey is normalized).
    private var openTranslation: (sourceKey: String, text: String)?
    private var openSeq = 0
    private var openAppliedSeq = 0
    private var openInFlightCount = 0
    private var lastRequestedOpenKey = ""
    private var lastOpenRequestAt = Date.distantPast
    private let maxOpenInFlight = 2
    private let openInterval: TimeInterval = 1.0

    /// On-device draft of the tail the LLM hasn't covered yet.
    private var tailTranslation: (source: String, text: String)?
    private var tailInFlight = false
    private var lastTailRequestAt = Date.distantPast
    private let tailInterval: TimeInterval = 0.2
    private let tailMinLength = 2

    private var lastFullText = ""
    /// Bumped on reset() so late callbacks from a previous session are ignored.
    private var gen = 0
    private let onDevice = AppleTranslator()
    private var onDeviceReady = false
    /// Re-drives open-turn/tail translation between feeds, so speech right
    /// before a pause still gets translated.
    private var timer: Timer?

    func reset() {
        gen &+= 1
        frozen.removeAll()
        drafts.removeAll()
        frozenPending.removeAll()
        draftPending.removeAll()
        openTranslation = nil
        openSeq = 0
        openAppliedSeq = 0
        openInFlightCount = 0
        lastRequestedOpenKey = ""
        lastOpenRequestAt = .distantPast
        tailTranslation = nil
        tailInFlight = false
        lastTailRequestAt = .distantPast
        lastFullText = ""
        timer?.invalidate()
        timer = nil
    }

    /// Bring up the on-device session for this pair; until (and unless) it
    /// reports ready, the LLM's streamed partials cover the tail. Call
    /// teardown() after the session.
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

    // MARK: - Input

    /// Full accumulated transcript (main thread). "\n\n" separates speaker
    /// turns, "\n" sentences; both only ever appear in finalized text, so a
    /// closed turn's boundaries never change. `stableLength` is unused —
    /// turn boundaries carry the stability information themselves.
    func feed(_ fullText: String, stableLength: Int) {
        lastFullText = fullText
        startTimerIfNeeded()
        processTurns()
    }

    // MARK: - Turn parsing

    /// Closed turns (their "\n\n" terminator has been written, so they are
    /// finalized and immutable) and the still-open last turn.
    private func parseTurns(_ text: String) -> (closed: [String], open: String?) {
        var parts = text.components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
        let endsClosed = text.hasSuffix("\n\n")
        var open: String? = nil
        if !endsClosed, let last = parts.popLast() {
            open = last.isEmpty ? nil : last
        }
        let closed = parts.filter { Self.isSubstantial($0) }
        if let o = open, !Self.isSubstantial(o) { open = nil }
        return (closed, open)
    }

    /// Cache key: content only, ignoring whitespace and punctuation, so
    /// late-arriving or re-drawn punctuation still hits.
    private static func normalizedKey(_ text: String) -> String {
        let stripped = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        return stripped.isEmpty ? text : stripped
    }

    /// Whether text carries anything worth translating or showing — bare
    /// "." scraps from silences do not.
    private static func isSubstantial(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// If `text`'s content starts with `key` (whitespace/punctuation
    /// ignored), returns the remainder after it; nil on a content mismatch.
    private static func remainderAfterNormalizedPrefix(of text: String, key: String) -> String? {
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
                while index < text.endIndex, text[index].isWhitespace || text[index].isPunctuation {
                    index = text.index(after: index)
                }
                return String(text[index...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Translation orchestration

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let (_, open) = self.parseTurns(self.lastFullText)
            self.maybeTranslateOpen(open)
            self.maybeTranslateTail(open)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func processTurns() {
        let (closed, open) = parseTurns(lastFullText)

        for (index, turn) in closed.enumerated() {
            let key = Self.normalizedKey(turn)
            guard frozen[key] == nil else { continue }

            // The turn just closed: inherit the open-turn translation as its
            // draft so the caption never blanks while the final pass runs.
            if drafts[key] == nil, let ot = openTranslation, ot.sourceKey == key {
                drafts[key] = ot.text
            }
            // On-device draft as a fallback when there is nothing to inherit.
            if onDeviceReady, drafts[key] == nil, !draftPending.contains(key) {
                draftPending.insert(key)
                requestOnDevice(turn) { [weak self] draft in
                    guard let self else { return }
                    self.draftPending.remove(key)
                    if let draft, self.frozen[key] == nil { self.drafts[key] = draft }
                }
            }

            // Quality pass: one request per closed turn, previous turn as
            // context, frozen on arrival.
            guard !frozenPending.contains(key) else { continue }
            frozenPending.insert(key)
            let previous = index > 0 ? closed[index - 1] : nil
            let previousTranslation = previous.flatMap { frozen[Self.normalizedKey($0)] }
            requestLLM(
                turn,
                context: previous,
                contextTranslation: previousTranslation,
                onPartial: onDeviceReady ? nil : { [weak self] partial in
                    self?.drafts[key] = partial
                },
                completion: { [weak self] final in
                    guard let self else { return }
                    self.frozenPending.remove(key)
                    // Keep the draft (or the source) over losing the line.
                    self.frozen[key] = final ?? self.drafts[key] ?? turn
                }
            )
        }

        maybeTranslateOpen(open)
        maybeTranslateTail(open)
        emit()
    }

    /// Whole-turn re-translation of the open turn: the LLM sees everything
    /// said so far in this turn, so its output reads as one coherent piece.
    /// Requests overlap up to `maxOpenInFlight`, and a sequence number drops
    /// out-of-order responses.
    private func maybeTranslateOpen(_ open: String?) {
        guard let open, open.count >= tailMinLength else { return }
        // Watchdog: reclaim slots if responses were lost (dead stream).
        if openInFlightCount >= maxOpenInFlight,
           Date().timeIntervalSince(lastOpenRequestAt) > 10 {
            openInFlightCount = 0
        }
        guard openInFlightCount < maxOpenInFlight else { return }
        let key = Self.normalizedKey(open)
        guard key != lastRequestedOpenKey, openTranslation?.sourceKey != key else { return }
        guard Date().timeIntervalSince(lastOpenRequestAt) >= openInterval else { return }

        openSeq += 1
        let seq = openSeq
        openInFlightCount += 1
        lastRequestedOpenKey = key
        lastOpenRequestAt = Date()
        let (closed, _) = parseTurns(lastFullText)
        let previous = closed.last
        let previousTranslation = previous.flatMap { frozen[Self.normalizedKey($0)] }

        requestLLM(
            open,
            context: previous,
            contextTranslation: previousTranslation,
            isFragment: true,
            // Continuation, not retranslation: the previous on-screen text is
            // in the prompt with orders to reuse its wording verbatim, so the
            // caption extends instead of being erased and rewritten (and the
            // register can't flip between polite and casual every round).
            previousOpenTranslation: openTranslation?.text,
            onPartial: { [weak self] partial in
                guard let self, seq >= self.openAppliedSeq else { return }
                self.openAppliedSeq = seq
                self.applyOpenTranslation(key: key, text: partial)
            },
            completion: { [weak self] translated in
                guard let self else { return }
                self.openInFlightCount -= 1
                if let translated, seq >= self.openAppliedSeq {
                    self.openAppliedSeq = seq
                    self.applyOpenTranslation(key: key, text: translated)
                }
                // The turn may have grown while this was in flight.
                let (_, nowOpen) = self.parseTurns(self.lastFullText)
                self.maybeTranslateOpen(nowOpen)
            }
        )
    }

    private func applyOpenTranslation(key: String, text: String) {
        // Hard stability guard: if the model ignored the reuse instruction
        // and rewrote most of what is already on screen, keep the screen —
        // the frozen pass will deliver the polished version once the turn
        // closes. (Streamed partials are exempt while shorter than the
        // previous text; they are still catching up to it.)
        if let previous = openTranslation?.text {
            // A shorter text is a streamed partial still catching up to what
            // is already shown — replacing would make the caption shrink and
            // regrow every round.
            if text.count < previous.count { return }
            if previous.count > 20 {
                let common = zip(previous, text).prefix { $0 == $1 }.count
                if common < previous.count / 2 { return }
            }
        }
        openTranslation = (key, text)
        // The LLM now covers everything the tail draft covered.
        if let t = tailTranslation,
           Self.remainderAfterNormalizedPrefix(of: key, key: Self.normalizedKey(t.source)) != nil {
            tailTranslation = nil
        }
    }

    /// On-device draft of whatever the open turn contains beyond what the
    /// LLM's latest response covered — this is what makes captions track
    /// speech in real time between ~1 s LLM rounds.
    private func maybeTranslateTail(_ open: String?) {
        guard onDeviceReady, let open else { return }
        let remainder: String
        if let ot = openTranslation,
           let rest = Self.remainderAfterNormalizedPrefix(of: open, key: ot.sourceKey) {
            remainder = rest
        } else {
            remainder = open
        }
        guard remainder.count >= tailMinLength, Self.isSubstantial(remainder) else { return }
        if tailInFlight, Date().timeIntervalSince(lastTailRequestAt) > 10 { tailInFlight = false }
        guard !tailInFlight, tailTranslation?.source != remainder else { return }
        guard Date().timeIntervalSince(lastTailRequestAt) >= tailInterval else { return }

        tailInFlight = true
        lastTailRequestAt = Date()
        requestOnDevice(remainder) { [weak self] translated in
            guard let self else { return }
            self.tailInFlight = false
            if let translated { self.tailTranslation = (remainder, translated) }
            let (_, nowOpen) = self.parseTurns(self.lastFullText)
            self.maybeTranslateTail(nowOpen)
        }
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
        previousOpenTranslation: String? = nil,
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
            previousTranslation: previousOpenTranslation,
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

    /// One line per speaker turn: frozen LLM translations in white, the open
    /// turn (and any closed turn still waiting on its quality pass) dimmed.
    /// Source text is never shown — mixed-language captions read worse than
    /// a sub-second gap while a translation is in flight.
    private var displayLines: [(text: String, isFinal: Bool)] {
        let (closed, open) = parseTurns(lastFullText)
        var lines: [(String, Bool)] = []
        for turn in closed {
            let key = Self.normalizedKey(turn)
            if let final = frozen[key] {
                lines.append((final, true))
            } else if let draft = drafts[key] {
                lines.append((draft, false))
            }
        }
        if let open {
            var piece = ""
            if let ot = openTranslation,
               Self.remainderAfterNormalizedPrefix(of: open, key: ot.sourceKey) != nil {
                piece = ot.text
            }
            if let t = tailTranslation {
                piece += piece.isEmpty ? t.text : " " + t.text
            }
            if Self.isSubstantial(piece) { lines.append((piece, false)) }
        }
        return lines
    }

    var displayText: String {
        displayLines.map { $0.text }.joined(separator: "\n")
    }

    var captionPieces: [(text: String, isFinal: Bool)] {
        Array(displayLines.suffix(Self.captionTurns))
    }

    private func emit() {
        onDisplay?(displayText, captionPieces)
    }
}
