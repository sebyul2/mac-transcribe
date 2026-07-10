import AVFoundation
import Foundation

/// Speaks translations aloud, continuously, like a simultaneous interpreter.
///
/// Why not one AVSpeechUtterance per translated line: the transcriber seals
/// a line at every ~0.8 s speech pause, so translations arrive as short
/// shards — and giving each shard its own utterance inserts the
/// synthesizer's per-utterance gap after every one, which is exactly the
/// stuttering this design replaces. Instead, arriving text accumulates in a
/// buffer, and each time the voice goes idle the WHOLE buffer is spoken as
/// one utterance: shards merge into a continuous stream, and nothing ever
/// interrupts speech mid-sentence. When the conversation outruns the voice,
/// the oldest buffered text is dropped — the same policy translation itself
/// uses (speech that scrolled past isn't worth reading).
///
/// Rendering goes through a private AVAudioEngine rather than
/// `synthesizer.speak`: the engine's mixer gain is independent of the
/// system output volume, so the optional ducking mode can pull the system
/// volume down while the voice keeps its loudness — original audio quiet
/// underneath, interpreter on top, like a real interpreter feed.
///
/// Main-thread only (matching the translation engine that feeds it).
final class SpeechOutput {
    /// Master switch; when off, enqueue() is a no-op.
    var enabled = false
    /// Duck the system output while speaking; restore when the voice idles.
    var duckOthers = false
    /// BCP 47 tag choosing the voice, e.g. "ko-KR".
    var languageTag = "ko-KR"

    /// System volume multiplier while ducked, and the compensating mixer
    /// gain. The engine's own output ALSO passes through the ducked system
    /// volume, so the boost claws the voice back toward its original
    /// loudness (0.5 × 1.8 = 0.9× perceived) while everything else drops
    /// to half. Boost is capped below the clipping range of typical TTS
    /// waveform peaks.
    private let duckFactor: Float = 0.5
    private let voiceBoost: Float = 1.8

    /// Speech rate: a touch above default reads urgent enough for live
    /// interpretation without sounding rushed (user-tuned).
    private let rate = AVSpeechUtteranceDefaultSpeechRate * 1.1

    /// Drop the oldest buffered text past this size (~30 s of speech) —
    /// beyond that the voice can never catch back up to the conversation.
    private let bufferCap = 240

    private let synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?

    private var buffer = ""
    private var speaking = false
    /// Invalidates in-flight render callbacks after a session reset.
    private var generation = 0
    /// Pending un-duck, cancelled when the next utterance starts within the
    /// grace period — without this the system volume pumps up and down in
    /// every inter-utterance gap.
    private var unduckWork: DispatchWorkItem?

    init() {
        engine.attach(player)
    }

    // MARK: - Input

    /// Adds translated text to the spoken stream. Main thread.
    func enqueue(_ text: String) {
        guard enabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        buffer += buffer.isEmpty ? trimmed : " " + trimmed
        if buffer.count > bufferCap {
            SpeechService.diag("speech backlog \(buffer.count) chars — dropping oldest")
            var tail = String(buffer.suffix(bufferCap))
            if let space = tail.firstIndex(of: " ") {
                tail = String(tail[tail.index(after: space)...])
            }
            buffer = tail
        }
        pump()
    }

    /// Session start: silence anything left from the previous session.
    func reset() {
        generation &+= 1
        buffer = ""
        speaking = false
        player.stop()
        cancelUnduck()
        SystemAudio.unduckOutput()
    }

    /// Session end: let the voice finish what it is saying, but nothing new.
    func endSession() {
        buffer = ""
    }

    // MARK: - Pipeline

    /// Speaks the whole accumulated buffer as one utterance. Buffers arriving
    /// while the voice is busy simply wait for the next pump — that is what
    /// merges shards into continuous speech.
    private func pump() {
        guard !speaking, !buffer.isEmpty else { return }
        speaking = true
        let text = buffer
        buffer = ""
        let gen = generation

        if duckOthers {
            cancelUnduck()
            SystemAudio.duckOutput(to: duckFactor)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        utterance.voice = AVSpeechSynthesisVoice(language: languageTag)

        var sawEnd = false
        synthesizer.write(utterance) { [weak self] rendered in
            // Callback thread is unspecified; scheduleBuffer is thread-safe,
            // but all state changes bounce to main.
            guard let self, let pcm = rendered as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                // End marker (can fire more than once). Chain the finish
                // callback behind everything scheduled so far.
                if sawEnd { return }
                sawEnd = true
                DispatchQueue.main.async { [weak self] in
                    self?.finishAfterScheduled(gen: gen)
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.schedule(pcm, gen: gen)
            }
        }
    }

    private func schedule(_ pcm: AVAudioPCMBuffer, gen: Int) {
        guard gen == generation else { return }
        if connectedFormat != pcm.format {
            engine.connect(player, to: engine.mainMixerNode, format: pcm.format)
            connectedFormat = pcm.format
        }
        engine.mainMixerNode.outputVolume = duckOthers ? voiceBoost : 1.0
        if !engine.isRunning {
            do { try engine.start() } catch {
                SpeechService.diag("speech engine start FAILED: \(error.localizedDescription)")
                return
            }
        }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(pcm)
    }

    /// Queues a completion marker behind all scheduled audio; fires when the
    /// utterance has fully played out.
    private func finishAfterScheduled(gen: Int) {
        guard gen == generation, let format = connectedFormat,
              let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
            speaking = false
            return
        }
        marker.frameLength = 1
        player.scheduleBuffer(marker) { [weak self] in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.speaking = false
                if self.buffer.isEmpty {
                    self.scheduleUnduck()
                } else {
                    self.pump()
                }
            }
        }
    }

    // MARK: - Ducking hysteresis

    /// Restore the system volume only after the voice has been idle for a
    /// beat — the next shard usually arrives within a second, and pumping
    /// the volume in every gap is worse than holding it down.
    private func scheduleUnduck() {
        guard duckOthers else { return }
        cancelUnduck()
        let work = DispatchWorkItem { SystemAudio.unduckOutput() }
        unduckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func cancelUnduck() {
        unduckWork?.cancel()
        unduckWork = nil
    }

    // MARK: - Voice mapping

    /// BCP 47 voice tag for a DeepL target code or an LLM prompt language name.
    static func languageTag(deepl: String, llm: String) -> String {
        let deeplMap: [String: String] = [
            "KO": "ko-KR", "JA": "ja-JP", "EN-US": "en-US", "EN-GB": "en-GB",
            "ZH-HANS": "zh-CN", "ZH-HANT": "zh-TW", "DE": "de-DE",
            "FR": "fr-FR", "ES": "es-ES", "PT-BR": "pt-BR", "RU": "ru-RU",
        ]
        if let tag = deeplMap[deepl] { return tag }
        let llmMap: [String: String] = [
            "Korean": "ko-KR", "Japanese": "ja-JP", "English": "en-US",
            "Simplified Chinese": "zh-CN", "Traditional Chinese": "zh-TW",
        ]
        return llmMap[llm] ?? "en-US"
    }
}
