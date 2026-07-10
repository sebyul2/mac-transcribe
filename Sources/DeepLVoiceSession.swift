import AVFoundation
import Foundation

/// One DeepL Voice streaming session: raw audio in, live transcripts out.
///
/// This replaces the whole local pipeline for translation sessions — no
/// on-device recognizer, no VAD sealing, no fragment translation. Audio is
/// streamed to DeepL, which does its own ASR, sentence segmentation, and
/// translation, and answers with two parallel transcript streams (source
/// and target), each split into CONCLUDED segments (final, append-only)
/// and a TENTATIVE tail (revised as more audio arrives) — exactly the
/// white/grey caption model.
///
/// Protocol (developers.deepl.com/api-reference/voice):
///  1. POST /v3/voice/realtime with the audio format and language pair
///     → { streaming_url, token (single-use) }
///  2. Connect wss with ?token=, send `source_media_chunk` messages
///     (base64 PCM, 50–250 ms each), receive `source_transcript_update` /
///     `target_transcript_update`.
///  3. `end_of_source_media` → server finalizes → `end_of_stream`.
///
/// Sessions cap at 1 hour with a 30 s inactivity timeout; feeding live
/// capture (even silence) keeps them alive. On error the session is dead —
/// callers start a new one.
///
/// Audio arrives on the capture thread; network and parsing run on an
/// internal serial queue; callbacks fire on main.
final class DeepLVoiceSession: NSObject {
    /// Full source transcript (concluded + tentative), for the log/autosave.
    /// Fired on main whenever it changes.
    var onSourceTranscript: ((_ concluded: String, _ tentative: String) -> Void)?
    /// Target-language transcript. `concluded` is append-only; `tentative`
    /// is replaced wholesale. Fired on main.
    var onTargetTranscript: ((_ concluded: String, _ tentative: String) -> Void)?
    /// Session died (network, protocol error, server error). Fired on main.
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "macwhisper.deepl-voice")
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var closed = false

    // Audio conversion to 16 kHz mono s16le (DeepL's recommended PCM).
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    /// Pending PCM bytes; sent when ~100 ms (3200 bytes) accumulate — the
    /// low end of the protocol's 50–250 ms guidance, shaving latency.
    private var pendingAudio = Data()
    private let chunkBytes = 3200
    /// 16 kHz × 2 bytes: one second of pending audio.
    private let bytesPerSecond = 32_000
    /// Live interpretation must stay LIVE: when sending falls behind (socket
    /// handshake, network stall), everything older than this is dropped —
    /// translating the past while the present talks is worse than a gap.
    private var maxPendingBytes: Int { bytesPerSecond * 3 }
    /// Chunk pacing per the protocol (next send ≥ half the previous chunk's
    /// duration later) — catching up runs at 2× real time, never a burst.
    private var nextSendAt = Date.distantPast
    private var drainScheduled = false
    /// Keepalive: the server kills sessions idle for 30 s, and a paused
    /// video on the system-audio source stops the capture callbacks cold.
    private var lastChunkSentAt = Date()

    // Transcript accumulation (concluded is append-only per the protocol).
    private var sourceConcluded = ""
    private var sourceTentative = ""
    private var targetConcluded = ""
    private var targetTentative = ""

    // MARK: - Lifecycle

    /// Requests a session and connects. `sourceLang`/`targetLang` are DeepL
    /// codes ("ja", "ko"); empty source means auto-detect.
    func start(apiKey: String, sourceLang: String, targetLang: String) {
        queue.async { [weak self] in
            self?.requestAndConnect(apiKey: apiKey, sourceLang: sourceLang, targetLang: targetLang)
        }
    }

    /// Feeds captured audio (any format — converted internally). Safe to
    /// call from the capture thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        // Deep-copy before hopping queues: the engine reuses tap buffers.
        guard let copy = Self.copy(buffer) else { return }
        queue.async { [weak self] in
            self?.convertAndSend(copy)
        }
    }

    /// Ends the audio stream; the server finalizes remaining tentative text
    /// before the connection winds down.
    func stop() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.sendJSON(["end_of_source_media": [:]])
        }
    }

    /// Hard-closes the connection (session abandoned).
    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.closed = true
            self.webSocket?.cancel(with: .normalClosure, reason: nil)
            self.webSocket = nil
        }
    }

    // MARK: - Session setup

    private func requestAndConnect(apiKey: String, sourceLang: String, targetLang: String) {
        var body: [String: Any] = [
            "source_media_content_type": "audio/pcm;encoding=s16le;rate=16000",
            "target_languages": [targetLang.lowercased()],
            "message_format": "json",
        ]
        if !sourceLang.isEmpty {
            body["source_language"] = sourceLang.lowercased()
            body["source_language_mode"] = "fixed"
        }
        var req = URLRequest(url: URL(string: "https://api.deepl.com/v3/voice/realtime")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var streamingURL: String?
        var token: String?
        var failure: String?
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { semaphore.signal() }
            if let error { failure = error.localizedDescription; return }
            guard let data, let http = response as? HTTPURLResponse else {
                failure = "no response"; return
            }
            guard (200..<300).contains(http.statusCode) else {
                failure = "HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")"
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                failure = "bad session response"; return
            }
            streamingURL = json["streaming_url"] as? String
            token = json["token"] as? String
        }.resume()
        semaphore.wait()

        guard let streamingURL, let token,
              var components = URLComponents(string: streamingURL) else {
            fail(failure ?? "no streaming URL")
            return
        }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let wsURL = components.url else {
            fail("bad streaming URL")
            return
        }

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: wsURL)
        urlSession = session
        webSocket = ws
        ws.resume()
        SpeechService.diag("deepl voice connected \(sourceLang.isEmpty ? "auto" : sourceLang)->\(targetLang)")
        receiveLoop()
        keepaliveLoop()
        drainPending() // flush the few seconds captured during the handshake
    }

    /// Verifies an API key against the VOICE endpoint — one REST round-trip
    /// checks the key, the paid plan, and Voice access together. Used by the
    /// settings Test button.
    static func testConnection(apiKey: String, completion: @escaping (Result<String, Error>) -> Void) {
        struct TestError: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }
        var req = URLRequest(url: URL(string: "https://api.deepl.com/v3/voice/realtime")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "source_media_content_type": "audio/pcm;encoding=s16le;rate=16000",
            "target_languages": ["ko"],
        ])
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let data, let http = response as? HTTPURLResponse else {
                completion(.failure(TestError(message: "no response")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(TestError(message: "HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")))
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            completion(.success(json?["session_id"] as? String ?? "ok"))
        }.resume()
    }

    // MARK: - Sending

    private func convertAndSend(_ buffer: AVAudioPCMBuffer) {
        guard !closed else { return }
        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInputFormat = buffer.format
        }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard convError == nil, out.frameLength > 0,
              let channel = out.int16ChannelData else { return }
        pendingAudio.append(Data(bytes: channel[0], count: Int(out.frameLength) * 2))

        // Keep only the newest few seconds: audio held back by the socket
        // handshake or a network stall is stale interpretation — drop it.
        if pendingAudio.count > maxPendingBytes {
            pendingAudio.removeFirst(pendingAudio.count - maxPendingBytes)
        }
        drainPending()
    }

    /// Sends pending audio respecting the protocol's pacing rule: chunks of
    /// at most one second, the next no sooner than half the previous chunk's
    /// duration — a backlog drains at 2× real time instead of a burst the
    /// server would reject.
    private func drainPending() {
        guard !closed, webSocket != nil else { return }
        let now = Date()
        if now < nextSendAt {
            scheduleDrain(after: nextSendAt.timeIntervalSince(now))
            return
        }
        guard pendingAudio.count >= chunkBytes else { return }
        let size = min(pendingAudio.count, bytesPerSecond)
        let chunk = pendingAudio.prefix(size)
        pendingAudio.removeFirst(size)
        sendJSON(["source_media_chunk": ["data": chunk.base64EncodedString()]])
        lastChunkSentAt = now
        let duration = Double(size) / Double(bytesPerSecond)
        nextSendAt = now.addingTimeInterval(duration / 2)
        if pendingAudio.count >= chunkBytes {
            scheduleDrain(after: duration / 2)
        }
    }

    private func scheduleDrain(after delay: TimeInterval) {
        guard !drainScheduled else { return }
        drainScheduled = true
        queue.asyncAfter(deadline: .now() + max(0.02, delay)) { [weak self] in
            self?.drainScheduled = false
            self?.drainPending()
        }
    }

    /// The server times out sessions with no audio for 30 s. The system-audio
    /// source stops delivering buffers entirely when nothing plays (paused
    /// video, silence between meetings) — feed zeros so the session survives
    /// the lull and picks up instantly when sound returns.
    private func keepaliveLoop() {
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.closed else { return }
            if Date().timeIntervalSince(self.lastChunkSentAt) > 8, self.webSocket != nil {
                let silence = Data(count: self.chunkBytes) // 200 ms of s16le zeros
                self.sendJSON(["source_media_chunk": ["data": silence.base64EncodedString()]])
                self.lastChunkSentAt = Date()
            }
            self.keepaliveLoop()
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard !closed, let ws = webSocket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { [weak self] error in
            if let error {
                self?.queue.async { self?.fail("send: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Receiving

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    if !self.closed { self.receiveLoop() }
                case .failure(let error):
                    self.fail("receive: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let update = json["source_transcript_update"] as? [String: Any] {
            apply(update, concluded: &sourceConcluded, tentative: &sourceTentative)
            let (c, t) = (sourceConcluded, sourceTentative)
            DispatchQueue.main.async { [weak self] in self?.onSourceTranscript?(c, t) }
        } else if let update = json["target_transcript_update"] as? [String: Any] {
            apply(update, concluded: &targetConcluded, tentative: &targetTentative)
            let (c, t) = (targetConcluded, targetTentative)
            DispatchQueue.main.async { [weak self] in self?.onTargetTranscript?(c, t) }
        } else if json["end_of_stream"] != nil {
            SpeechService.diag("deepl voice end_of_stream")
            closed = true
            webSocket?.cancel(with: .normalClosure, reason: nil)
            webSocket = nil
        } else if let error = json["error"] as? [String: Any] {
            fail("server: \(error["error_message"] as? String ?? "\(error)")")
        }
    }

    /// Merges one transcript update: concluded segments append once; the
    /// tentative tail is replaced wholesale.
    private func apply(_ update: [String: Any], concluded: inout String, tentative: inout String) {
        for segment in update["concluded"] as? [[String: Any]] ?? [] {
            guard let text = segment["text"] as? String else { continue }
            concluded += text
        }
        tentative = (update["tentative"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }
            .joined()
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        closed = true
        SpeechService.diag("deepl voice FAILED: \(message)")
        webSocket?.cancel(with: .abnormalClosure, reason: nil)
        webSocket = nil
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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
}
