import Foundation

/// Live translation for locked sessions.
///
/// The design is the published, production-proven recipe for streaming
/// machine translation over a translator that cannot decode incrementally
/// (an LLM API):
///
///  * **Re-translation** (Arivazhagan et al. 2020 — the approach Google's
///    streaming translation shipped): every request translates the current
///    full text of ONE utterance from scratch. Requests are stateless, so a
///    slow or lost response can never corrupt anything — the next response
///    simply supersedes it. While a request is in flight, source changes only
///    mark the utterance dirty; at most one request runs and at most one is
///    pending (conflation), so the request rate self-paces to the model's
///    latency.
///  * **Local agreement** (Liu et al. 2020), with the trailing word masked:
///    the prefix that two consecutive hypotheses agree on is rendered white
///    (committed), the rest dimmed. Commitment is monotonic within an
///    utterance, so a word that turned white never flickers back.
///
/// Segmentation is not this engine's job: the transcriber already emits one
/// utterance per line (see LongFormTranscriber). The LAST line is the open
/// utterance — still being spoken, re-translated on every change; earlier
/// lines are sealed. Sealing hands the open hypothesis over as the line's
/// PROVISIONAL translation (so nothing on screen ever regresses to source
/// text), and the definitive pass then re-translates the finished sentence
/// fresh — free of the verbatim-reuse chaining that keeps live hypotheses
/// stable but locks in wordings chosen when the sentence was half-spoken.
/// Quality comes from that pass; the live loop only keeps the screen
/// current. A sealed utterance that scrolled past before its definitive
/// pass could run keeps its hypothesis and is dropped from the queue:
/// translating speech nobody can see anymore only delays the words they can.
///
/// Everything here runs on the main thread; LLM completions are bounced back
/// to it. No locks, no shared mutable state.
final class TranslationEngine {
    /// English name of the target language, used verbatim in the prompt.
    var targetLanguage = "English"

    /// Fired on every display change: the full translated log (for the
    /// transcript window) and styled caption pieces (white = committed,
    /// dimmed = still-moving hypothesis). Main thread.
    var onDisplay: ((_ transcript: String, _ caption: [(text: String, isFinal: Bool)]) -> Void)?

    private struct Utterance {
        let source: String
        var translation: String?
        /// The translation is a hypothesis whose source snapshot didn't quite
        /// cover the sealed text (it grew a few characters between the last
        /// re-translation and the seal). Shown as-is — a near-complete
        /// translation must never regress to source text on screen — but the
        /// catch-up pump still owes this line a definitive pass.
        var isProvisional = false
        /// Failed catch-up attempts; the line is abandoned after a couple so
        /// a dead network can't spin the pump forever on one utterance.
        var attempts = 0
    }

    /// Sealed utterances in order. Only ever appended.
    private var sealed: [Utterance] = []

    // Open-utterance state (re-translation + local agreement).
    private var openSource = ""
    /// Latest hypothesis for the open utterance and the exact source text it
    /// translated — when that source seals unchanged, the hypothesis IS the
    /// final translation and no extra request is needed.
    private var openHypothesis = ""
    private var openHypothesisSource = ""
    /// Committed (white) length of openHypothesis, in characters. Monotonic.
    private var openCommitted = 0

    private var openInFlight = false
    private var openDirty = false
    /// Consecutive failed requests for the current open utterance; retries
    /// stop after a few and re-arm when the source changes.
    private var openFailures = 0
    private var sealedInFlight = false

    /// Only the newest sealed utterances get a definitive pass; anything
    /// older has scrolled off the caption already, and its provisional
    /// hypothesis (when it has one) is good enough for the log.
    private let sealedCatchUpWindow = 2

    /// Bumped by reset()/teardown() so responses from a previous session are
    /// dropped instead of folded into the new one.
    private var generation = 0

    /// Session start: forget everything, invalidate in-flight responses.
    func reset() {
        generation &+= 1
        sealed.removeAll()
        clearOpen()
        openInFlight = false
        sealedInFlight = false
    }

    /// Session end: invalidate in-flight responses; keep nothing running.
    func teardown() {
        generation &+= 1
        openInFlight = false
        sealedInFlight = false
    }

    /// Feeds the transcriber's full accumulated text (one utterance per line;
    /// a trailing newline means the last utterance was sealed and nothing new
    /// has been spoken yet).
    func feed(_ text: String, stableLength: Int) {
        let hasOpen = !text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let newOpen = hasOpen ? (lines.popLast() ?? "") : ""

        // Absorb newly sealed utterances. A single final can seal several
        // lines at once (sentence-by-sentence sealing of a long blob).
        let sealedBefore = sealed.count
        while sealed.count < lines.count {
            let source = lines[sealed.count]
            var utterance = Utterance(source: source, translation: nil)
            // Carry the open hypothesis over as this line's provisional
            // translation whenever their sources are prefix-related. Exact
            // coverage is rare — the source usually grows a few characters
            // between the last re-translation and the seal — and losing the
            // hypothesis here is what made lines regress to source text on
            // screen. The catch-up pump replaces it with a definitive
            // full-sentence translation either way.
            if !openHypothesis.isEmpty, !openHypothesisSource.isEmpty,
               source.hasPrefix(openHypothesisSource) || openHypothesisSource.hasPrefix(source) {
                utterance.translation = openHypothesis
                utterance.isProvisional = true
                // Consume it: a hypothesis must not duplicate across several
                // lines when one blob seals sentence by sentence.
                openHypothesis = ""
                openHypothesisSource = ""
            }
            sealed.append(utterance)
        }
        if sealed.count > sealedBefore {
            // The utterance we were re-translating is sealed; whatever comes
            // next is a fresh one with fresh agreement state.
            clearOpen()
            pumpSealed()
        }

        if newOpen != openSource {
            openSource = newOpen
            openFailures = 0
            scheduleOpen()
        }
        render()
    }

    // MARK: - Open utterance (re-translation loop)

    private func clearOpen() {
        openSource = ""
        openHypothesis = ""
        openHypothesisSource = ""
        openCommitted = 0
        openDirty = false
        openFailures = 0
        // openInFlight stays: it mirrors a real network request, whose
        // completion still needs to land (and may resolve a sealed line).
    }

    private func scheduleOpen() {
        // One or two characters is recognizer noise more often than speech;
        // the next revision will requalify it.
        guard openSource.count >= 2 else { return }
        if openInFlight {
            openDirty = true
            return
        }
        fireOpen()
    }

    /// The last couple of utterances before `index` (or the tail when nil),
    /// joined as translation context. Live transcripts fragment heavily —
    /// "그것", "讨论会" — and one fragment of context is routinely too little
    /// to disambiguate the next one.
    private func contextWindow(before index: Int? = nil) -> (source: String, translation: String?)? {
        let end = index ?? sealed.count
        let window = sealed[max(0, end - 2)..<end]
        guard !window.isEmpty else { return nil }
        let translation = window.compactMap { $0.translation }.joined(separator: "\n")
        return (
            window.map { $0.source }.joined(separator: "\n"),
            translation.isEmpty ? nil : translation
        )
    }

    private func fireOpen() {
        openInFlight = true
        openDirty = false
        let snapshot = openSource
        let gen = generation
        let context = contextWindow()
        LLMRefiner.translate(
            snapshot,
            to: targetLanguage,
            context: context?.source,
            contextTranslation: context?.translation,
            isFragment: true,
            previousTranslation: openHypothesis.isEmpty ? nil : openHypothesis
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.openInFlight = false
                switch result {
                case .success(let translation):
                    self.accept(
                        hypothesis: translation.trimmingCharacters(in: .whitespacesAndNewlines),
                        for: snapshot)
                    if self.openDirty { self.fireOpen() }
                case .failure(let error):
                    SpeechService.diag("translate open FAILED: \(error.localizedDescription)")
                    // A swallowed failure left the utterance untranslated
                    // until its source next changed — which never happens
                    // once the speaker pauses. Retry with backoff, but stop
                    // after a few: against an outage (rate limit, no
                    // network) endless retries only burn quota. A source
                    // change re-arms the counter.
                    self.openFailures += 1
                    guard self.openFailures <= 4 else { return }
                    let delay = min(5.0, 0.8 * pow(2, Double(self.openFailures - 1)))
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, gen == self.generation, !self.openInFlight,
                              !self.openSource.isEmpty else { return }
                        self.fireOpen()
                    }
                }
            }
        }
    }

    private func accept(hypothesis: String, for source: String) {
        guard !hypothesis.isEmpty else { return }
        // A response for a source that sealed mid-flight resolves that line
        // (checked first: an exact sealed match beats a fuzzy open match).
        if let i = sealed.lastIndex(where: { $0.source == source && $0.translation == nil }) {
            sealed[i].translation = hypothesis
        } else if !source.isEmpty, !openSource.isEmpty,
                  openSource.hasPrefix(source) || source.hasPrefix(openSource) {
            // Still the same utterance — grown, or revised shorter by the
            // recognizer. Fold into the agreement state either way: a
            // slightly stale hypothesis on screen beats no caption at all.
            let agreed = Self.agreedLength(previous: openHypothesis, current: hypothesis)
            openCommitted = min(max(openCommitted, agreed), hypothesis.count)
            openHypothesis = hypothesis
            openHypothesisSource = source
        } else {
            return // stale response for text that no longer exists anywhere
        }
        render()
    }

    /// Local agreement with a one-word mask: how many characters of `current`
    /// both hypotheses agree on, pulled back to the last word boundary so a
    /// half-typed word never commits. Spaceless scripts (CJK) mask a fixed
    /// few characters instead.
    private static func agreedLength(previous: String, current: String) -> Int {
        guard !previous.isEmpty else { return 0 }
        let a = Array(previous), b = Array(current)
        var i = 0
        while i < min(a.count, b.count), a[i] == b[i] { i += 1 }
        if let lastSpace = b[..<i].lastIndex(where: { $0.isWhitespace }) {
            return lastSpace + 1
        }
        return max(0, i - 3)
    }

    // MARK: - Sealed utterances (definitive pass)

    /// Every sealed utterance owes one definitive translation: the whole,
    /// finished sentence, translated fresh — no verbatim-reuse instruction
    /// chaining it to hypotheses made while the sentence was half-spoken, and
    /// a notch more reasoning. This is where translation QUALITY comes from;
    /// the open-utterance loop only keeps the screen current. One request at
    /// a time, newest first; older gaps are abandoned (see class comment).
    private func pumpSealed() {
        guard !sealedInFlight else { return }
        guard let i = sealed.indices.reversed().first(where: {
            (sealed[$0].translation == nil || sealed[$0].isProvisional) && sealed[$0].attempts < 2
        }), i >= sealed.count - sealedCatchUpWindow else { return }
        sealedInFlight = true
        let gen = generation
        let source = sealed[i].source
        let context = contextWindow(before: i)
        LLMRefiner.translate(
            source,
            to: targetLanguage,
            context: context?.source,
            contextTranslation: context?.translation,
            effort: "low"
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.sealedInFlight = false
                switch result {
                case .success(let translation):
                    let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty,
                       let j = self.sealed.lastIndex(where: { $0.source == source }) {
                        self.sealed[j].translation = trimmed
                        self.sealed[j].isProvisional = false
                        self.render()
                    }
                case .failure(let error):
                    SpeechService.diag("translate sealed FAILED: \(error.localizedDescription)")
                    if let j = self.sealed.lastIndex(where: { $0.source == source }) {
                        self.sealed[j].attempts += 1
                    }
                }
                self.pumpSealed()
            }
        }
    }

    // MARK: - Rendering

    private func render() {
        // Transcript window: the full session log. An untranslated sealed
        // line keeps its source text — information is never dropped there.
        var log = sealed.map { $0.translation ?? $0.source }
        if !openHypothesis.isEmpty { log.append(openHypothesis) }
        let transcript = log.joined(separator: "\n")

        // Caption: a rolling window of the newest lines, three at a time
        // like broadcast captions. A line leaves only by scrolling off the
        // top when a newer one arrives — never by vanishing mid-read — and a
        // partially translated line (a provisional hypothesis) stays up
        // until its definitive translation replaces it in place. Source
        // text never appears here.
        var caption: [(text: String, isFinal: Bool)] = []
        let sealedSlots = openHypothesis.isEmpty ? 3 : 2
        for translation in sealed.compactMap({ $0.translation }).suffix(sealedSlots) {
            caption.append((translation + "\n", true))
        }
        if !openHypothesis.isEmpty {
            let chars = Array(openHypothesis)
            let cut = min(openCommitted, chars.count)
            if cut > 0 { caption.append((String(chars[..<cut]), true)) }
            if cut < chars.count { caption.append((String(chars[cut...]), false)) }
        }
        onDisplay?(transcript, caption)
    }
}
