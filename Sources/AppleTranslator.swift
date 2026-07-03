import AppKit
import SwiftUI
import Translation

/// On-device translation via Apple's Translation framework — the fastest path
/// for interpreter mode (tens of milliseconds, offline) versus 1–2 s per LLM
/// round trip.
///
/// The framework only hands out a `TranslationSession` through the SwiftUI
/// `.translationTask` modifier, so this wrapper hosts an invisible
/// `NSHostingView` in a tiny panel and pumps translation requests into the
/// task closure through an `AsyncStream`. The panel stays fully transparent
/// unless a language model needs downloading, in which case it becomes visible
/// to anchor the system's download-approval sheet.
final class AppleTranslator {
    fileprivate struct Request {
        let text: String
        /// Called on the session task (background); hop to main yourself.
        let completion: (String?) -> Void
    }

    private var window: NSPanel?
    private var continuation: AsyncStream<Request>.Continuation?
    /// True once the language pair is confirmed installed and the session is
    /// pumping. Main-thread only.
    private(set) var isReady = false

    /// Starts a session for the pair and reports usability on the main thread.
    /// Unsupported pairs and declined model downloads report `false` — the
    /// caller falls back to LLM translation.
    func start(source: Locale.Language, target: Locale.Language, readiness: @escaping (Bool) -> Void) {
        stop()
        let (stream, continuation) = AsyncStream.makeStream(of: Request.self)
        self.continuation = continuation

        let host = TranslatorHostView(
            config: TranslationSession.Configuration(source: source, target: target),
            requests: stream,
            onNeedsDownload: { [weak self] in
                DispatchQueue.main.async { self?.setPanelVisible(true) }
            },
            onReady: { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.setPanelVisible(false)
                    self.isReady = ok
                    if !ok { self.stop() }
                    SpeechService.diag("apple-translate ready=\(ok) \(source.minimalIdentifier)->\(target.minimalIdentifier)")
                    readiness(ok)
                }
            }
        )
        let hosting = NSHostingView(rootView: host)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 72)
        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(
                x: screen.frame.midX - hosting.frame.width / 2,
                y: screen.frame.midY - hosting.frame.height / 2))
        }
        // The hosting view must live in an ordered-in window for
        // .translationTask to fire; alpha 0 keeps it invisible.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        window = panel
    }

    /// Translate one string. `completion` runs on a background queue; nil on
    /// any failure (caller keeps the original text or falls back).
    func translate(_ text: String, completion: @escaping (String?) -> Void) {
        guard isReady, let continuation else {
            completion(nil)
            return
        }
        continuation.yield(Request(text: text, completion: completion))
    }

    func stop() {
        continuation?.finish()
        continuation = nil
        isReady = false
        window?.orderOut(nil)
        window = nil
    }

    private func setPanelVisible(_ visible: Bool) {
        window?.alphaValue = visible ? 1 : 0
    }
}

/// Invisible SwiftUI host whose only job is owning the TranslationSession and
/// draining the request stream inside the task closure (the session must not
/// escape it).
private struct TranslatorHostView: View {
    let config: TranslationSession.Configuration
    let requests: AsyncStream<AppleTranslator.Request>
    let onNeedsDownload: () -> Void
    let onReady: (Bool) -> Void

    var body: some View {
        Text("Preparing on-device translation…")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
            .frame(width: 320, height: 72)
            .translationTask(config) { session in
                do {
                    let status = await LanguageAvailability().status(from: config.source ?? .init(identifier: "und"), to: config.target)
                    switch status {
                    case .installed:
                        break
                    case .supported:
                        // Model not downloaded yet — this shows a system
                        // approval sheet anchored to our (now visible) panel.
                        onNeedsDownload()
                        try await session.prepareTranslation()
                    case .unsupported:
                        onReady(false)
                        return
                    @unknown default:
                        onReady(false)
                        return
                    }
                } catch {
                    onReady(false)
                    return
                }
                onReady(true)
                for await request in requests {
                    do {
                        let response = try await session.translate(request.text)
                        request.completion(response.targetText)
                    } catch {
                        request.completion(nil)
                    }
                }
            }
    }
}
