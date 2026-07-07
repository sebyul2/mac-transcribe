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
/// lines are sealed — translated once and cached. A sealed utterance that
/// scrolled past before its translation could run is dropped, not queued:
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
    private var sealedInFlight = false

    /// Only the newest sealed utterances are worth translating after the
    /// fact; anything older has scrolled off the caption already.
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
            if source == openHypothesisSource, !openHypothesis.isEmpty {
                utterance.translation = openHypothesis
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

    private func fireOpen() {
        openInFlight = true
        openDirty = false
        let snapshot = openSource
        let gen = generation
        let context = sealed.last
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
                if case .success(let translation) = result {
                    self.accept(
                        hypothesis: translation.trimmingCharacters(in: .whitespacesAndNewlines),
                        for: snapshot)
                }
                if self.openDirty { self.fireOpen() }
            }
        }
    }

    private func accept(hypothesis: String, for source: String) {
        guard !hypothesis.isEmpty else { return }
        if source == openSource || (!source.isEmpty && openSource.hasPrefix(source)) {
            // Still the same utterance (possibly grown since the snapshot):
            // fold into the agreement state.
            let agreed = Self.agreedLength(previous: openHypothesis, current: hypothesis)
            openCommitted = min(max(openCommitted, agreed), hypothesis.count)
            openHypothesis = hypothesis
            openHypothesisSource = source
        } else if let i = sealed.lastIndex(where: { $0.source == source && $0.translation == nil }) {
            // Landed after its utterance sealed. A re-translation of the full
            // sealed source is exactly its final translation.
            sealed[i].translation = hypothesis
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

    // MARK: - Sealed utterances (one-shot catch-up)

    /// Translates the newest untranslated sealed utterance, one request at a
    /// time. Older gaps are abandoned on purpose (see class comment).
    private func pumpSealed() {
        guard !sealedInFlight else { return }
        guard let i = sealed.indices.reversed().first(where: { sealed[$0].translation == nil }),
              i >= sealed.count - sealedCatchUpWindow else { return }
        sealedInFlight = true
        let gen = generation
        let source = sealed[i].source
        let context = i > 0 ? sealed[i - 1] : nil
        LLMRefiner.translate(
            source,
            to: targetLanguage,
            context: context?.source,
            contextTranslation: context?.translation
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.sealedInFlight = false
                if case .success(let translation) = result,
                   let j = self.sealed.lastIndex(where: { $0.source == source && $0.translation == nil }) {
                    self.sealed[j].translation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.render()
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

        // Caption: the previous utterance's finished translation for
        // continuity, then the open hypothesis split white/dim at the
        // agreement point. Source text never appears here.
        var caption: [(text: String, isFinal: Bool)] = []
        if let last = sealed.last, let translation = last.translation {
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
