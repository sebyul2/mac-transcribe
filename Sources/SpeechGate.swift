import Foundation

/// Decides WHEN translated text is handed to the TTS, ahead of DeepL's own
/// confirmation.
///
/// DeepL Voice delivers the target transcript as CONCLUDED text (final,
/// append-only) plus a TENTATIVE tail (rewritten wholesale as more audio
/// arrives). Speaking only concluded text is safe but late: DeepL concludes a
/// sentence seconds after the captions already show it, which is the bulk of
/// the voice's lag behind the subtitles. This gate speaks EARLY from the
/// tentative tail — a prefix that ends at a sentence boundary and has
/// survived unchanged for `stabilityWindow` is considered settled and spoken
/// immediately.
///
/// Consistency is tracked by character count against the concluded stream,
/// never by re-matching text. The concluded stream only ever grows (the
/// caller folds dead sessions into a base prefix on reconnect), so a count
/// is a coordinate that can't be invalidated. Once something was spoken it
/// is never re-spoken; when the server later concludes DIFFERENT text for a
/// stretch already voiced, the mismatch is skipped silently — corrections
/// belong to the captions, which update instantly, not to the voice.
///
/// Main-thread only (matching SpeechOutput, which it feeds).
final class SpeechGate {
    /// Receives each newly speakable piece of text (= speechOutput.enqueue).
    var speak: ((String) -> Void)?
    /// When false, only concluded deltas pass (the pre-gate behavior).
    var earlySpeech = true

    /// Chars of the concluded stream (base included) already handed to speak().
    /// Invariant: equals the stream's length after every update().
    private var spokenConcluded = 0
    /// The tentative prefix already spoken, awaiting its conclusion.
    private var spokenAhead = ""
    /// Sentence-bounded tentative text being watched for stability.
    private var candidate = ""
    private var candidateSince = Date()
    /// Fires the candidate when updates stop arriving — a speaker pausing is
    /// exactly when the tentative text is most settled and most overdue.
    private var fireTimer: DispatchWorkItem?

    /// Early-speak events not yet concluded, for conclude-lag measurement:
    /// how much sooner the voice ran versus waiting for the server.
    private var pendingLagMarks: [(chars: Int, at: Date)] = []

    /// How long a sentence-bounded tentative prefix must stay unchanged
    /// before it is trusted aloud.
    private let stabilityWindow: TimeInterval = 1.0
    /// Ignore near-empty candidates (a lone "네." can wait for company).
    private let minChars = 4

    // MARK: - Lifecycle

    /// Session start: forget everything.
    func reset() {
        spokenConcluded = 0
        spokenAhead = ""
        pendingLagMarks = []
        clearCandidate()
    }

    /// The session died mid-flight: its tentative text will never conclude
    /// (the reconnected session starts a fresh transcript on the folded
    /// base), so the spoken-ahead account is written off. `spokenConcluded`
    /// stays valid — the caller's base folding keeps that stream append-only.
    func tentativeInvalidated() {
        spokenAhead = ""
        pendingLagMarks = []
        clearCandidate()
    }

    // MARK: - Input

    /// Feed every target-transcript update here. `concludedStream` is the
    /// full concluded text including any reconnect base; `tentative` is the
    /// current unstable tail.
    func update(concludedStream: String, tentative: String) {
        settleConcluded(concludedStream)
        guard earlySpeech else { return }
        considerTentative(tentative)
    }

    // MARK: - Concluded settlement

    /// Reconciles concluded growth against what was already spoken ahead:
    /// spoken chars are skipped by count, only the unspoken remainder is
    /// voiced. Divergence (server concluded different text than we spoke)
    /// is logged and swallowed — never re-spoken.
    private func settleConcluded(_ stream: String) {
        guard stream.count > spokenConcluded else { return }
        let delta = String(stream.dropFirst(spokenConcluded))
        spokenConcluded = stream.count

        if delta.count <= spokenAhead.count {
            if !spokenAhead.hasPrefix(delta) {
                SpeechService.diag("gate divergence: \(delta.count) concluded chars differ from early-spoken text")
            }
            logConcludeLag(consumed: delta.count)
            spokenAhead.removeFirst(delta.count)
        } else {
            if !spokenAhead.isEmpty, !delta.hasPrefix(spokenAhead) {
                SpeechService.diag("gate divergence: conclusion rewrote \(spokenAhead.count) early-spoken chars")
            }
            logConcludeLag(consumed: spokenAhead.count)
            let unspoken = String(delta.dropFirst(spokenAhead.count))
            spokenAhead = ""
            speak?(unspoken)
        }
    }

    /// Pops lag marks covered by `consumed` early-spoken chars and logs how
    /// far ahead of the conclusion each spoke.
    private func logConcludeLag(consumed: Int) {
        var remaining = consumed
        while remaining > 0, let mark = pendingLagMarks.first {
            guard mark.chars <= remaining else {
                pendingLagMarks[0].chars -= remaining
                break
            }
            remaining -= mark.chars
            pendingLagMarks.removeFirst()
            let ms = Int(Date().timeIntervalSince(mark.at) * 1000)
            SpeechService.diag("gate conclude-lag=\(ms)ms (spoke \(mark.chars) chars that far ahead)")
        }
    }

    // MARK: - Tentative early speech

    private func considerTentative(_ tentative: String) {
        // Re-anchor when the tentative was revised below the spoken frontier:
        // adopt the new text as "spoken" by count (skip policy — the old
        // version is already out of the speakers).
        if !tentative.hasPrefix(spokenAhead) {
            SpeechService.diag("gate tentative revised under \(spokenAhead.count) early-spoken chars")
            spokenAhead = String(tentative.prefix(spokenAhead.count))
        }

        let unspoken = String(tentative.dropFirst(spokenAhead.count))
        let newCandidate = Self.sentenceBoundedPrefix(of: unspoken)
        if newCandidate != candidate {
            clearCandidate()
            candidate = newCandidate
            candidateSince = Date()
        }
        guard candidate.count >= minChars else { return }

        let elapsed = Date().timeIntervalSince(candidateSince)
        if elapsed >= stabilityWindow {
            fire()
        } else if fireTimer == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.fireTimer = nil
                if self.candidate.count >= self.minChars { self.fire() }
            }
            fireTimer = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (stabilityWindow - elapsed), execute: work)
        }
    }

    private func fire() {
        let stableMs = Int(Date().timeIntervalSince(candidateSince) * 1000)
        SpeechService.diag("gate early-speak chars=\(candidate.count) stable=\(stableMs)ms")
        spokenAhead += candidate
        pendingLagMarks.append((chars: candidate.count, at: Date()))
        let text = candidate
        clearCandidate()
        speak?(text)
    }

    private func clearCandidate() {
        candidate = ""
        fireTimer?.cancel()
        fireTimer = nil
    }

    // MARK: - Sentence boundary

    /// The longest prefix of `text` ending at a sentence boundary (empty when
    /// there is none). A half-width '.' only counts when followed by
    /// whitespace, end-of-text, or a closing quote/bracket — "3.5" and
    /// "U.S." must not be cut. Trailing closers ride along with the sentence.
    static func sentenceBoundedPrefix(of text: String) -> String {
        let hard: Set<Character> = ["。", "．", "？", "！", "?", "!", "…", "\n"]
        let closers: Set<Character> = ["\"", "'", "」", "』", ")", "]", "»", "\u{201D}", "\u{2019}"]
        var cut: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            var isBoundary = hard.contains(ch)
            if ch == "." {
                let next = text.index(after: i)
                isBoundary = next == text.endIndex
                    || text[next].isWhitespace || closers.contains(text[next])
            }
            if isBoundary {
                var end = text.index(after: i)
                while end < text.endIndex, closers.contains(text[end]) {
                    end = text.index(after: end)
                }
                cut = end
                i = end
            } else {
                i = text.index(after: i)
            }
        }
        guard let cut else { return "" }
        return String(text[..<cut])
    }
}
