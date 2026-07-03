import AVFoundation
import Foundation
import ScreenCaptureKit
import Speech

/// Long-form transcription for locked (meeting-style) recordings, built on the
/// macOS 26 SpeechAnalyzer / SpeechTranscriber API.
///
/// Unlike SFSpeechRecognizer — a dictation API that treats sustained silence as
/// a failed utterance and kills the task — SpeechAnalyzer is designed for long,
/// continuous audio: silence is simply "no results yet", so a session can idle
/// through a quiet pre-meeting stretch indefinitely. No segment-restart chain,
/// no error backoff.
///
/// The raw audio is simultaneously written to `audioBackupURL` (AAC) so even a
/// total transcription failure can never lose the capture itself.
final class LongFormTranscriber {
    /// Real-time normalized RMS level in 0...1 for the waveform HUD.
    var onLevel: ((Float) -> Void)?
    /// Full accumulated transcript (finalized + volatile tail), on main.
    var onTranscript: ((String) -> Void)?
    /// Final transcript once the session fully drains, on main. Fires exactly once.
    var onFinished: ((String) -> Void)?
    /// When set, every captured buffer is also written to this file (AAC).
    var audioBackupURL: URL?

    /// Where the session captures audio from.
    enum AudioSource { case microphone, systemAudio }
    /// Set before start(). System audio uses ScreenCaptureKit (Screen
    /// Recording permission) and hears what the computer plays — for
    /// interpreting calls and videos.
    var audioSource: AudioSource = .microphone

    /// Transient status for the UI (e.g. "downloading model…"), on main.
    var onStatus: ((String) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var scStream: SCStream?
    private var scOutput: SystemAudioOutput?
    private var backupFile: AVAudioFile?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private var finalizedText = ""
    private var volatileText = ""
    private var isRunning = false
    private var didFinish = false
    private let stateLock = NSLock()
    private var lastLevelDispatchAt = Date.distantPast

    /// Loudest level seen this session — distinguishes "nobody spoke" from
    /// "speech happened but transcription failed" when the transcript is empty.
    private(set) var sessionPeakLevel: Float = 0

    private var combinedTranscript: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        if volatileText.isEmpty { return finalizedText }
        return finalizedText + volatileText
    }

    /// Session generation. Bumped on every start() so a stale async pipeline —
    /// a run() still awaiting model download, a superseded results task, the
    /// stop() fallback timer — can never touch a newer session. Rapid Fn
    /// mashing previously let those overlap and trap inside the Speech
    /// framework (EXC_BREAKPOINT).
    private var gen = 0

    func start(language: RecognitionLanguage) {
        guard !isRunning else { return }
        gen &+= 1
        let myGen = gen
        isRunning = true
        didFinish = false
        stateLock.lock()
        finalizedText = ""
        volatileText = ""
        sessionPeakLevel = 0
        stateLock.unlock()
        tapBufferCount = 0
        Task { await run(language: language, gen: myGen) }
    }

    /// Ends the session: stops capture, lets the analyzer drain, then fires
    /// onFinished with everything transcribed so far.
    func stop() {
        let myGen = gen
        guard isRunning else {
            deliverFinish(gen: myGen)
            return
        }
        isRunning = false
        stopEngine()
        stateLock.lock()
        let builder = inputBuilder
        inputBuilder = nil
        let analyzer = self.analyzer
        stateLock.unlock()
        builder?.finish()
        onLevel?(0)
        Task {
            // Wait for the analyzer to process everything already yielded, so
            // the last words are not cut off.
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        }
        // Safety net: if the results stream never terminates, deliver anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.deliverFinish(gen: myGen)
        }
    }

    // MARK: - Session pipeline

    private func run(language: RecognitionLanguage, gen myGen: Int) async {
        SpeechService.diag("longform start lang=\(language.rawValue)")
        // The session may be stopped (or superseded) while any of the awaits
        // below are in flight; continuing to set up a dead session corrupts
        // the newer one and can trap inside the Speech framework.
        func stale() -> Bool { myGen != gen || !isRunning }
        do {
            // fastResults trades a little accuracy for much lower latency on
            // the volatile (caption) results; finals are unaffected.
            let transcriber = SpeechTranscriber(
                locale: language.locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: []
            )

            // Download the long-form model for this locale if it's missing.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                SpeechService.diag("longform downloading speech assets…")
                DispatchQueue.main.async { [weak self] in
                    self?.onStatus?("Downloading \(language.displayName) model…")
                }
                try await request.downloadAndInstall()
                DispatchQueue.main.async { [weak self] in self?.onStatus?("Model ready") }
            }
            guard !stale() else { deliverFinish(gen: myGen); return }

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                SpeechService.diag("longform FAILED: no compatible audio format")
                deliverFinish(gen: myGen)
                return
            }
            guard !stale() else { deliverFinish(gen: myGen); return }
            setPipeline(transcriber: transcriber, format: format)

            let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.start(inputSequence: stream)
            guard !stale() else {
                builder.finish()
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                deliverFinish(gen: myGen)
                return
            }
            setStream(builder: builder, analyzer: analyzer)

            startResultsTask(transcriber, gen: myGen)

            // Use the system default input as-is. Forcing the built-in mic
            // (like push-to-talk does) records silence in clamshell mode with
            // an external display — the lid mic hears nothing — and a meeting
            // setup often has a better external mic selected anyway.
            guard !stale() else { deliverFinish(gen: myGen); return }
            switch audioSource {
            case .microphone:
                try await MainActor.run { try startEngine() }
            case .systemAudio:
                try await startSystemCapture()
            }
            SpeechService.diag("longform running source=\(audioSource)")
        } catch {
            SpeechService.diag("longform FAILED: \(error)")
            stopEngine()
            deliverFinish(gen: myGen)
        }
    }

    /// Synchronous helpers so the async run() never touches the lock directly
    /// (NSLock is unavailable from async contexts in Swift 6 language mode).
    private func setPipeline(transcriber: SpeechTranscriber, format: AVAudioFormat) {
        stateLock.lock()
        self.transcriber = transcriber
        analyzerFormat = format
        stateLock.unlock()
    }

    private func setStream(builder: AsyncStream<AnalyzerInput>.Continuation, analyzer: SpeechAnalyzer) {
        stateLock.lock()
        inputBuilder = builder
        self.analyzer = analyzer
        stateLock.unlock()
    }

    private func startResultsTask(_ transcriber: SpeechTranscriber, gen myGen: Int) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, myGen == self.gen else { return }
                    let combined = self.fold(text: String(result.text.characters), isFinal: result.isFinal)
                    DispatchQueue.main.async { self.onTranscript?(combined) }
                }
            } catch {
                SpeechService.diag("longform results error: \(error)")
            }
            // Results stream ended — the analyzer has fully drained.
            self?.deliverFinish(gen: myGen)
        }
    }

    /// Merges one recognizer result into the accumulated transcript and returns
    /// the combined text. Synchronous so it is safe to call from the async
    /// results loop without touching the lock in an async context.
    private func fold(text: String, isFinal: Bool) -> String {
        stateLock.lock()
        if isFinal {
            finalizedText += text
            volatileText = ""
        } else {
            volatileText = text
        }
        stateLock.unlock()
        return combinedTranscript
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "MacWhisper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid input format"])
        }
        var boundDevice: AudioDeviceID = 0
        if let unit = inputNode.audioUnit {
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &boundDevice, &size)
        }
        SpeechService.diag("longform input \(format.sampleRate)Hz ch=\(format.channelCount) engineDevice=\(boundDevice) analyzerFormat=\(analyzerFormat.map { "\($0.sampleRate)Hz ch=\($0.channelCount)" } ?? "nil")")

        if let url = audioBackupURL {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let file = try? AVAudioFile(
                forWriting: url, settings: settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            stateLock.lock()
            backupFile = file
            stateLock.unlock()
            SpeechService.diag("longform audio backup \(file == nil ? "FAILED" : "recording") -> \(url.lastPathComponent)")
        }

        if let fmt = analyzerFormat, fmt != format {
            // A silent fallback to unconverted buffers would feed the analyzer
            // a format it did not ask for — fail loudly instead.
            guard let conv = AVAudioConverter(from: format, to: fmt) else {
                throw NSError(domain: "MacWhisper", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "cannot convert \(format.sampleRate)Hz to analyzer format \(fmt.sampleRate)Hz"])
            }
            stateLock.lock()
            converter = conv
            stateLock.unlock()
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private var tapBufferCount = 0
    /// Serial queue for the audio backup: AVAudioFile.write is blocking disk
    /// I/O and must never run on the real-time audio tap thread, where its
    /// latency causes glitches and frame drops.
    private let backupQueue = DispatchQueue(label: "macwhisper.audio-backup", qos: .utility)

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        // Snapshot the shared state under the lock; these properties are
        // mutated from the session pipeline on other threads.
        stateLock.lock()
        let backup = backupFile
        let builder = inputBuilder
        let converter = self.converter
        let analyzerFormat = self.analyzerFormat
        stateLock.unlock()

        if let backup, let copy = Self.copyBuffer(buffer) {
            // Copy first — the engine reuses the tap buffer after this block
            // returns — then write off the audio thread.
            backupQueue.async { try? backup.write(from: copy) }
        }

        // Waveform level, throttled to ~50 Hz.
        let level = Self.level(from: buffer)
        stateLock.lock()
        if level > sessionPeakLevel { sessionPeakLevel = level }
        stateLock.unlock()
        tapBufferCount += 1
        if tapBufferCount <= 3 || tapBufferCount % 500 == 0 {
            SpeechService.diag("longform tap #\(tapBufferCount) level=\(level) frames=\(buffer.frameLength)")
        }
        let now = Date()
        if now.timeIntervalSince(lastLevelDispatchAt) >= 0.02 {
            lastLevelDispatchAt = now
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }

        guard let builder else { return }
        if let converter, let analyzerFormat {
            let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
            guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var fed = false
            var convError: NSError?
            converter.convert(to: converted, error: &convError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if convError == nil, converted.frameLength > 0 {
                builder.yield(AnalyzerInput(buffer: converted))
            }
        } else {
            builder.yield(AnalyzerInput(buffer: buffer))
        }
    }

    /// Captures the computer's own audio output via ScreenCaptureKit and
    /// feeds it through the same pipeline as the microphone tap. Requires the
    /// Screen Recording permission (prompted on first use).
    private func startSystemCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "MacWhisper", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "no display for system-audio capture"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        // Video is unavoidable in the API; keep it as cheap as possible and
        // simply never attach a video output.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5)

        // Open the backup file against the capture format.
        if let url = audioBackupURL,
           let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let file = try? AVAudioFile(
                forWriting: url, settings: settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            setBackupFile(file)
            SpeechService.diag("longform audio backup \(file == nil ? "FAILED" : "recording") -> \(url.lastPathComponent) (system audio)")
        }

        let output = SystemAudioOutput { [weak self] buffer in
            self?.processCaptured(buffer)
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "macwhisper.system-audio"))
        try await stream.startCapture()
        setSystemStream(stream, output: output)
    }

    /// Synchronous lock helpers so async code never touches NSLock directly.
    private func setBackupFile(_ file: AVAudioFile?) {
        stateLock.lock()
        backupFile = file
        stateLock.unlock()
    }

    private func setSystemStream(_ stream: SCStream, output: SystemAudioOutput) {
        stateLock.lock()
        scStream = stream
        scOutput = output
        stateLock.unlock()
    }

    /// Shared per-buffer pipeline for the system-audio path: backup, level,
    /// convert, and yield to the analyzer. Mirrors the mic tap.
    private func processCaptured(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let backup = backupFile
        let builder = inputBuilder
        let analyzerFormat = self.analyzerFormat
        // Lazily create a converter for the capture format if it differs from
        // what the analyzer asked for.
        if converter == nil, let fmt = analyzerFormat, fmt != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: fmt)
        }
        let converter = self.converter
        stateLock.unlock()

        if let backup, let copy = Self.copyBuffer(buffer) {
            backupQueue.async { try? backup.write(from: copy) }
        }

        let level = Self.level(from: buffer)
        stateLock.lock()
        if level > sessionPeakLevel { sessionPeakLevel = level }
        stateLock.unlock()
        tapBufferCount += 1
        if tapBufferCount <= 3 || tapBufferCount % 500 == 0 {
            SpeechService.diag("longform sys-audio #\(tapBufferCount) level=\(level) frames=\(buffer.frameLength)")
        }
        let now = Date()
        if now.timeIntervalSince(lastLevelDispatchAt) >= 0.02 {
            lastLevelDispatchAt = now
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }

        guard let builder else { return }
        if let converter, let analyzerFormat {
            let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
            guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var fed = false
            var convError: NSError?
            converter.convert(to: converted, error: &convError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if convError == nil, converted.frameLength > 0 {
                builder.yield(AnalyzerInput(buffer: converted))
            }
        } else {
            builder.yield(AnalyzerInput(buffer: buffer))
        }
    }

    private func stopEngine() {
        if let engine = audioEngine {
            if engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            engine.reset()
        }
        audioEngine = nil
        stateLock.lock()
        let stream = scStream
        scStream = nil
        scOutput = nil
        let file = backupFile
        backupFile = nil
        stateLock.unlock()
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        // Release the file on the backup queue, after any in-flight write.
        if let file { backupQueue.async { _ = file } }
    }

    private func deliverFinish(gen myGen: Int) {
        stateLock.lock()
        let alreadyDone = didFinish || myGen != gen
        if !alreadyDone { didFinish = true }
        stateLock.unlock()
        guard !alreadyDone else { return }
        isRunning = false
        // These are read by handleTap and stop() on other threads.
        stateLock.lock()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        analyzerFormat = nil
        let peak = sessionPeakLevel
        stateLock.unlock()
        let transcript = combinedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        SpeechService.diag("longform end chars=\(transcript.count) peak=\(peak)")
        DispatchQueue.main.async { [weak self] in self?.onFinished?(transcript) }
    }

    /// Deep-copies a PCM buffer so it can outlive the tap callback (the engine
    /// reuses tap buffers once the block returns).
    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sData = s.mData, let dData = d.mData else { return nil }
            memcpy(dData, sData, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return copy
    }

    private static func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.format.channelCount > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frames {
            let s = samples[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frames))
        return min(1.0, max(0.0, rms * 12.0))
    }
}

/// SCStreamOutput adapter turning audio sample buffers into AVAudioPCMBuffers.
private final class SystemAudioOutput: NSObject, SCStreamOutput {
    private let handler: (AVAudioPCMBuffer) -> Void

    init(handler: @escaping (AVAudioPCMBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }
        handler(pcm)
    }
}
