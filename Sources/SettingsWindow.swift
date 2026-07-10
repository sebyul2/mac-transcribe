import Cocoa
import UniformTypeIdentifiers

/// The app's single settings window, organized into tabs:
///
///  - **General**     — recognition language, trigger keys, silence auto-stop
///  - **Translation** — live translation, source/target languages, subtitles
///  - **Meeting**      — audio source, automatic meeting notes
///  - **Engine**       — the LLM provider/model/account/glossary (refinement,
///                       meeting notes, and translation all run through it)
///
/// General/Translation/Meeting controls persist immediately and fire
/// `onSettingsChanged` so a running session and the menu bar update live. The
/// Engine tab keeps an explicit Save (provider/model are chosen, tested, then
/// committed) plus a Test button.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Injected so the General tab can capture new trigger keys.
    var fnMonitor: FnKeyMonitor?
    /// Fired after a trigger-key binding changes, so the app re-applies it.
    var onTriggerChanged: (() -> Void)?
    /// Fired after any non-Engine setting changes, so the app applies it live
    /// (subtitle overlay, translation languages) and rebuilds the menu.
    var onSettingsChanged: (() -> Void)?

    // General
    private let recognitionPopup = NSPopUpButton()
    private let shortKeyLabel = NSTextField(labelWithString: "")
    private let shortChangeButton = NSButton()
    private let longKeyLabel = NSTextField(labelWithString: "")
    private let longChangeButton = NSButton()
    private let longClearButton = NSButton()
    private let autoStopCheck = NSButton(checkboxWithTitle: "Auto-stop on sustained silence", target: nil, action: nil)

    // Translation
    private let liveTranslationCheck = NSButton(checkboxWithTitle: "Enable Live Translation for locked recordings", target: nil, action: nil)
    private let sourceLangPopup = NSPopUpButton()
    private let targetLangPopup = NSPopUpButton()
    private let subtitleCheck = NSButton(checkboxWithTitle: "Show subtitle overlay at the bottom of the screen", target: nil, action: nil)

    // Meeting
    private let micRadio = NSButton(radioButtonWithTitle: "Microphone", target: nil, action: nil)
    private let systemRadio = NSButton(radioButtonWithTitle: "System audio (what the Mac plays)", target: nil, action: nil)
    private let meetingNotesCheck = NSButton(checkboxWithTitle: "Generate meeting notes after a recording", target: nil, action: nil)
    private let notesProviderPopup = NSPopUpButton()

    // DeepL
    private let deeplEnabledCheck = NSButton(checkboxWithTitle: "Use DeepL for Live Translation (instead of Engine)", target: nil, action: nil)
    private let deeplKeyField = NSSecureTextField()
    private let deeplSourcePopup = NSPopUpButton()
    private let deeplTargetPopup = NSPopUpButton()
    private let deeplStatusLabel = NSTextField(labelWithString: "")

    // Engine (LLM)
    private let providerPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let modelField = NSTextField()
    private let baseURLField = NSTextField()
    private let baseURLLabel = NSTextField(labelWithString: "API Base URL:")
    private var apiKeyLabel: NSTextField!
    private let apiKeyStatusLabel = NSTextField(labelWithString: "")
    private let chatgptAuthButton = NSButton()
    private let glossaryStatusLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    /// Trigger-key capture target while the General tab is recording a key.
    private enum CaptureTarget { case none, short, long }
    private var capturing: CaptureTarget = .none

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Transcribe Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildUI()
        loadValues()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let tabView = NSTabView(frame: content.bounds)
        tabView.autoresizingMask = [.width, .height]
        tabView.addTabViewItem(makeTab("General", build: buildGeneralTab))
        tabView.addTabViewItem(makeTab("Translation", build: buildTranslationTab))
        tabView.addTabViewItem(makeTab("Meeting", build: buildMeetingTab))
        tabView.addTabViewItem(makeTab("DeepL", build: buildDeepLTab))
        tabView.addTabViewItem(makeTab("Engine", build: buildEngineTab))
        content.addSubview(tabView)
    }

    private func makeTab(_ title: String, build: (NSView) -> Void) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let view = NSView()
        build(view)
        item.view = view
        return item
    }

    // MARK: Layout helpers

    /// Right-aligned field label. `y` is measured from the top of the tab.
    private func label(_ title: String, top: CGFloat, in view: NSView, width: CGFloat = 120) -> NSTextField {
        let l = NSTextField(labelWithString: title)
        l.frame = NSRect(x: 20, y: tabHeight - top - 22, width: width, height: 22)
        l.alignment = .right
        view.addSubview(l)
        return l
    }
    private func place(_ v: NSView, x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat = 26, in view: NSView) {
        v.frame = NSRect(x: x, y: tabHeight - top - h, width: w, height: h)
        view.addSubview(v)
    }
    /// Usable height inside a tab (window minus the tab strip/chrome).
    private let tabHeight: CGFloat = 360
    private let fieldX: CGFloat = 150
    private let fieldW: CGFloat = 300

    // MARK: - General tab

    private func buildGeneralTab(_ view: NSView) {
        _ = label("Recognition:", top: 24, in: view)
        recognitionPopup.target = self
        recognitionPopup.action = #selector(recognitionChanged)
        for lang in RecognitionLanguage.allCases {
            recognitionPopup.addItem(withTitle: lang.displayName)
            recognitionPopup.lastItem?.representedObject = lang.rawValue
        }
        place(recognitionPopup, x: fieldX, top: 22, w: fieldW, in: view)
        let recNote = NSTextField(labelWithString: "Language spoken for speech-to-text (dictation and recordings).")
        recNote.font = .systemFont(ofSize: 11); recNote.textColor = .secondaryLabelColor
        place(recNote, x: fieldX, top: 52, w: fieldW, h: 16, in: view)

        // Trigger keys.
        _ = label("Dictation key:", top: 92, in: view)
        shortKeyLabel.font = .boldSystemFont(ofSize: 13)
        place(shortKeyLabel, x: fieldX, top: 92, w: 120, h: 22, in: view)
        shortChangeButton.bezelStyle = .rounded
        shortChangeButton.title = "Change…"
        shortChangeButton.target = self
        shortChangeButton.action = #selector(changeShortTapped)
        place(shortChangeButton, x: fieldX + 130, top: 90, w: 130, in: view)

        _ = label("Long-form key:", top: 128, in: view)
        longKeyLabel.font = .boldSystemFont(ofSize: 13)
        place(longKeyLabel, x: fieldX, top: 128, w: 120, h: 22, in: view)
        longChangeButton.bezelStyle = .rounded
        longChangeButton.title = "Change…"
        longChangeButton.target = self
        longChangeButton.action = #selector(changeLongTapped)
        place(longChangeButton, x: fieldX + 130, top: 126, w: 130, in: view)
        longClearButton.bezelStyle = .rounded
        longClearButton.title = "Clear"
        longClearButton.target = self
        longClearButton.action = #selector(clearLongTapped)
        place(longClearButton, x: fieldX + 130, top: 160, w: 130, in: view)

        let keyNote = NSTextField(wrappingLabelWithString:
            "Hold the dictation key to talk; add Shift to toggle a long-form recording. "
            + "To register a combo, hold the modifiers and press the key. The Apple ⌃Fn / ⌃⇧Fn always works too.")
        keyNote.font = .systemFont(ofSize: 11); keyNote.textColor = .secondaryLabelColor
        place(keyNote, x: 20, top: 196, w: 440, h: 48, in: view)

        autoStopCheck.target = self
        autoStopCheck.action = #selector(autoStopChanged)
        place(autoStopCheck, x: 20, top: 256, w: 440, h: 20, in: view)
        let autoStopNote = NSTextField(labelWithString: "Ends a session automatically after a long silence.")
        autoStopNote.font = .systemFont(ofSize: 11); autoStopNote.textColor = .secondaryLabelColor
        place(autoStopNote, x: 40, top: 278, w: 420, h: 16, in: view)
    }

    // MARK: - Translation tab

    private func buildTranslationTab(_ view: NSView) {
        liveTranslationCheck.target = self
        liveTranslationCheck.action = #selector(liveTranslationChanged)
        place(liveTranslationCheck, x: 20, top: 24, w: 440, h: 20, in: view)
        let liveNote = NSTextField(wrappingLabelWithString:
            "When on, a locked recording shows live-translated captions instead of transcribing; "
            + "only the original conversation is saved. Requires the Engine to be configured.")
        liveNote.font = .systemFont(ofSize: 11); liveNote.textColor = .secondaryLabelColor
        place(liveNote, x: 40, top: 46, w: 420, h: 32, in: view)

        _ = label("Source:", top: 96, in: view)
        sourceLangPopup.target = self
        sourceLangPopup.action = #selector(sourceLangChanged)
        for lang in TranslationLanguage.sources {
            sourceLangPopup.addItem(withTitle: lang.display)
            sourceLangPopup.lastItem?.representedObject = lang.prompt
        }
        place(sourceLangPopup, x: fieldX, top: 94, w: fieldW, in: view)

        _ = label("Target:", top: 132, in: view)
        targetLangPopup.target = self
        targetLangPopup.action = #selector(targetLangChanged)
        for lang in TranslationLanguage.targets {
            targetLangPopup.addItem(withTitle: lang.display)
            targetLangPopup.lastItem?.representedObject = lang.prompt
        }
        place(targetLangPopup, x: fieldX, top: 132, w: fieldW, in: view)

        let langNote = NSTextField(wrappingLabelWithString:
            "Translate from the source language into the target. Source is separate from the "
            + "recognition language above — leave it on Auto-detect for mixed-language meetings.")
        langNote.font = .systemFont(ofSize: 11); langNote.textColor = .secondaryLabelColor
        place(langNote, x: 20, top: 168, w: 440, h: 40, in: view)

        subtitleCheck.target = self
        subtitleCheck.action = #selector(subtitleChanged)
        place(subtitleCheck, x: 20, top: 224, w: 440, h: 20, in: view)
    }

    // MARK: - Meeting tab

    private func buildMeetingTab(_ view: NSView) {
        _ = label("Audio source:", top: 24, in: view)
        micRadio.target = self; micRadio.action = #selector(audioSourceChanged)
        systemRadio.target = self; systemRadio.action = #selector(audioSourceChanged)
        place(micRadio, x: fieldX, top: 22, w: fieldW, h: 20, in: view)
        place(systemRadio, x: fieldX, top: 48, w: fieldW, h: 20, in: view)
        let srcNote = NSTextField(labelWithString: "System audio (calls, videos) needs Screen Recording permission.")
        srcNote.font = .systemFont(ofSize: 11); srcNote.textColor = .secondaryLabelColor
        place(srcNote, x: fieldX, top: 74, w: fieldW, h: 16, in: view)

        meetingNotesCheck.target = self
        meetingNotesCheck.action = #selector(meetingNotesChanged)
        place(meetingNotesCheck, x: 20, top: 120, w: 440, h: 20, in: view)

        _ = label("Provider:", top: 152, in: view)
        notesProviderPopup.addItem(withTitle: "Engine (ChatGPT / OpenAI)")
        notesProviderPopup.lastItem?.representedObject = "engine"
        notesProviderPopup.addItem(withTitle: "Claude (via CLI)")
        notesProviderPopup.lastItem?.representedObject = "claude"
        notesProviderPopup.target = self
        notesProviderPopup.action = #selector(notesProviderChanged)
        place(notesProviderPopup, x: fieldX, top: 150, w: fieldW - 36, in: view)

        let infoButton = NSButton()
        infoButton.bezelStyle = .helpButton
        infoButton.title = ""
        infoButton.target = self
        infoButton.action = #selector(notesProviderInfoTapped)
        place(infoButton, x: fieldX + fieldW - 30, top: 150, w: 26, h: 26, in: view)

        let notesNote = NSTextField(wrappingLabelWithString:
            "After a recording ends, structured minutes (attendees, discussion, "
            + "decisions, action items) are generated as Markdown. Off during Live Translation.")
        notesNote.font = .systemFont(ofSize: 11); notesNote.textColor = .secondaryLabelColor
        place(notesNote, x: 20, top: 186, w: 440, h: 40, in: view)
    }

    // MARK: - DeepL tab

    private func buildDeepLTab(_ view: NSView) {
        deeplEnabledCheck.target = self
        deeplEnabledCheck.action = #selector(deeplEnabledChanged)
        place(deeplEnabledCheck, x: 20, top: 20, w: 440, h: 20, in: view)
        let enableNote = NSTextField(wrappingLabelWithString:
            "When enabled, Live Translation uses the DeepL API instead of the LLM Engine. "
            + "DeepL is faster (~200ms) and generally more natural for short utterances.")
        enableNote.font = .systemFont(ofSize: 11); enableNote.textColor = .secondaryLabelColor
        place(enableNote, x: 40, top: 42, w: 420, h: 32, in: view)

        _ = label("API Key:", top: 90, in: view)
        place(deeplKeyField, x: fieldX, top: 88, w: fieldW, in: view)
        deeplKeyField.isEditable = true; deeplKeyField.isBezeled = true
        deeplKeyField.bezelStyle = .roundedBezel
        deeplKeyField.placeholderString = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

        _ = label("Source:", top: 128, in: view)
        for lang in DeepLTranslator.sourceLanguages {
            deeplSourcePopup.addItem(withTitle: lang.display)
            deeplSourcePopup.lastItem?.representedObject = lang.code
        }
        place(deeplSourcePopup, x: fieldX, top: 126, w: fieldW, in: view)

        _ = label("Target:", top: 164, in: view)
        for lang in DeepLTranslator.targetLanguages {
            deeplTargetPopup.addItem(withTitle: lang.display)
            deeplTargetPopup.lastItem?.representedObject = lang.code
        }
        place(deeplTargetPopup, x: fieldX, top: 162, w: fieldW, in: view)

        deeplStatusLabel.alignment = .left
        deeplStatusLabel.maximumNumberOfLines = 2
        deeplStatusLabel.lineBreakMode = .byWordWrapping
        deeplStatusLabel.textColor = .secondaryLabelColor
        place(deeplStatusLabel, x: 20, top: 210, w: 440, h: 40, in: view)

        let testButton = NSButton(title: "Test", target: self, action: #selector(deeplTestTapped))
        testButton.bezelStyle = .rounded
        place(testButton, x: 260, top: 266, w: 90, h: 32, in: view)
        let saveButton = NSButton(title: "Save", target: self, action: #selector(deeplSaveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        place(saveButton, x: 360, top: 266, w: 100, h: 32, in: view)
    }

    @objc private func deeplEnabledChanged() {
        Settings.shared.deeplEnabled = deeplEnabledCheck.state == .on
        onSettingsChanged?()
    }

    @objc private func deeplSaveTapped() {
        let s = Settings.shared
        s.deeplAPIKey = deeplKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        s.deeplSourceLang = represented(deeplSourcePopup)
        s.deeplTargetLang = represented(deeplTargetPopup)
        s.deeplEnabled = deeplEnabledCheck.state == .on
        deeplStatusLabel.textColor = .systemGreen
        deeplStatusLabel.stringValue = "Saved."
        onSettingsChanged?()
    }

    @objc private func deeplTestTapped() {
        let key = deeplKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = represented(deeplTargetPopup)
        let source = represented(deeplSourcePopup)
        guard !key.isEmpty else {
            deeplStatusLabel.textColor = .systemRed
            deeplStatusLabel.stringValue = "Enter an API key first."
            return
        }
        deeplStatusLabel.textColor = .secondaryLabelColor
        deeplStatusLabel.stringValue = "Testing…"
        DeepLTranslator.translate("Hello, this is a test.", targetLang: target,
                                   sourceLang: source.isEmpty ? nil : source, apiKey: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let t):
                    self.deeplStatusLabel.textColor = .systemGreen
                    self.deeplStatusLabel.stringValue = "✓ \(t.text)"
                case .failure(let error):
                    self.deeplStatusLabel.textColor = .systemRed
                    self.deeplStatusLabel.stringValue = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Engine tab (LLM)

    private func buildEngineTab(_ view: NSView) {
        let desc = NSTextField(wrappingLabelWithString:
            "The LLM engine is used for Live Translation and Meeting Notes generation. "
            + "Configure the provider and model below, then Test to verify.")
        desc.font = .systemFont(ofSize: 11); desc.textColor = .secondaryLabelColor
        place(desc, x: 20, top: 12, w: 440, h: 30, in: view)

        func style(_ field: NSTextField, top: CGFloat) {
            place(field, x: fieldX, top: top, w: fieldW, in: view)
            field.isEditable = true; field.isSelectable = true
            field.isBezeled = true; field.bezelStyle = .roundedBezel
        }

        _ = label("Provider:", top: 50, in: view)
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        for provider in LLMProvider.all {
            providerPopup.addItem(withTitle: provider.displayName)
            providerPopup.lastItem?.representedObject = provider.id
        }
        place(providerPopup, x: fieldX, top: 48, w: fieldW, in: view)

        _ = label("Model:", top: 86, in: view)
        place(modelPopup, x: fieldX, top: 84, w: fieldW, in: view)
        style(modelField, top: 86)
        modelField.placeholderString = "gpt-4o-mini"

        baseURLLabel.stringValue = "API Base URL:"
        baseURLLabel.alignment = .right
        place(baseURLLabel, x: 20, top: 122, w: 120, h: 22, in: view)
        style(baseURLField, top: 122)
        baseURLField.placeholderString = "https://api.openai.com/v1"

        apiKeyLabel = label("Account:", top: 158, in: view)
        apiKeyStatusLabel.font = .systemFont(ofSize: 11)
        apiKeyStatusLabel.textColor = .secondaryLabelColor
        place(apiKeyStatusLabel, x: fieldX, top: 158, w: fieldW, h: 22, in: view)

        chatgptAuthButton.title = "Sign in with ChatGPT"
        chatgptAuthButton.bezelStyle = .rounded
        chatgptAuthButton.target = self
        chatgptAuthButton.action = #selector(chatgptAuthTapped)
        place(chatgptAuthButton, x: fieldX, top: 186, w: 200, h: 30, in: view)

        _ = label("Glossary:", top: 230, in: view)
        glossaryStatusLabel.font = .systemFont(ofSize: 11)
        glossaryStatusLabel.textColor = .secondaryLabelColor
        glossaryStatusLabel.lineBreakMode = .byTruncatingMiddle
        place(glossaryStatusLabel, x: fieldX, top: 230, w: 140, h: 22, in: view)
        let chooseButton = NSButton(title: "Attach…", target: self, action: #selector(chooseGlossaryTapped))
        chooseButton.bezelStyle = .rounded
        place(chooseButton, x: fieldX + 146, top: 226, w: 82, height: 28, in: view)
        let editButton = NSButton(title: "Edit", target: self, action: #selector(editGlossaryTapped))
        editButton.bezelStyle = .rounded
        place(editButton, x: fieldX + 232, top: 226, w: 68, height: 28, in: view)

        statusLabel.alignment = .left
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.textColor = .secondaryLabelColor
        place(statusLabel, x: 20, top: 274, w: 440, h: 40, in: view)

        let testButton = NSButton(title: "Test", target: self, action: #selector(testTapped))
        testButton.bezelStyle = .rounded
        place(testButton, x: 260, top: 324, w: 90, h: 32, in: view)
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        place(saveButton, x: 360, top: 324, w: 100, h: 32, in: view)
    }

    /// Convenience overload accepting a pixel height for buttons.
    private func place(_ v: NSView, x: CGFloat, top: CGFloat, w: CGFloat, height: CGFloat, in view: NSView) {
        place(v, x: x, top: top, w: w, h: height, in: view)
    }

    // MARK: - Load

    private func loadValues() {
        let s = Settings.shared
        selectByRepresented(recognitionPopup, s.language.rawValue)
        refreshTriggerKeys()
        autoStopCheck.state = s.silenceAutoStopEnabled ? .on : .off

        liveTranslationCheck.state = s.liveTranslationEnabled ? .on : .off
        selectByRepresented(sourceLangPopup, s.interpreterSourceLanguage)
        selectByRepresented(targetLangPopup, s.interpreterTargetLanguage)
        subtitleCheck.state = s.subtitleOverlayEnabled ? .on : .off

        deeplEnabledCheck.state = s.deeplEnabled ? .on : .off
        deeplKeyField.stringValue = s.deeplAPIKey
        selectByRepresented(deeplSourcePopup, s.deeplSourceLang)
        selectByRepresented(deeplTargetPopup, s.deeplTargetLang)

        micRadio.state = s.lockedAudioSourceIsSystem ? .off : .on
        systemRadio.state = s.lockedAudioSourceIsSystem ? .on : .off
        meetingNotesCheck.state = s.meetingNotesEnabled ? .on : .off
        selectByRepresented(notesProviderPopup, s.meetingNotesProvider)

        let provider = s.llmProvider
        if let index = LLMProvider.all.firstIndex(where: { $0.id == provider.id }) {
            providerPopup.selectItem(at: index)
        }
        baseURLField.stringValue = provider.isCustom ? s.llmBaseURL : provider.baseURL
        modelField.stringValue = provider.isCustom ? s.llmModel : ""
        rebuildModelPopup(selecting: s.llmModel)
        applyProviderVisibility()
        refreshAPIKeyStatus()
        refreshGlossaryStatus()
    }

    private func selectByRepresented(_ popup: NSPopUpButton, _ value: String) {
        for item in popup.itemArray where (item.representedObject as? String) == value {
            popup.select(item)
            return
        }
        if popup.numberOfItems > 0 { popup.selectItem(at: 0) }
    }

    private func represented(_ popup: NSPopUpButton) -> String {
        popup.selectedItem?.representedObject as? String ?? ""
    }

    // MARK: - General actions

    @objc private func recognitionChanged() {
        if let lang = RecognitionLanguage(rawValue: represented(recognitionPopup)) {
            Settings.shared.language = lang
        }
        onSettingsChanged?()
    }
    @objc private func autoStopChanged() {
        Settings.shared.silenceAutoStopEnabled = autoStopCheck.state == .on
        onSettingsChanged?()
    }

    private func refreshTriggerKeys() {
        let s = Settings.shared
        shortKeyLabel.stringValue = FnKeyMonitor.chordName(s.triggerKey)
        if let long = s.longTriggerKey {
            longKeyLabel.stringValue = FnKeyMonitor.chordName(long)
            longClearButton.isEnabled = capturing == .none
        } else {
            longKeyLabel.stringValue = "Trigger + Shift"
            longClearButton.isEnabled = false
        }
        shortChangeButton.title = capturing == .short ? "Press key/combo…" : "Change…"
        longChangeButton.title = capturing == .long ? "Press key/combo…" : "Change…"
        shortChangeButton.isEnabled = capturing == .none
        longChangeButton.isEnabled = capturing == .none
    }

    private func beginCapture(_ target: CaptureTarget) {
        guard let fnMonitor, capturing == .none else { return }
        capturing = target
        refreshTriggerKeys()
        fnMonitor.captureNextKey = { [weak self] chord in
            guard let self else { return }
            switch self.capturing {
            case .short: Settings.shared.triggerKey = chord
            case .long: Settings.shared.longTriggerKey = chord
            case .none: break
            }
            self.capturing = .none
            self.onTriggerChanged?()
            self.refreshTriggerKeys()
        }
    }
    @objc private func changeShortTapped() { beginCapture(.short) }
    @objc private func changeLongTapped() { beginCapture(.long) }
    @objc private func clearLongTapped() {
        Settings.shared.longTriggerKey = nil
        onTriggerChanged?()
        refreshTriggerKeys()
    }

    // MARK: - Translation actions

    @objc private func liveTranslationChanged() {
        Settings.shared.liveTranslationEnabled = liveTranslationCheck.state == .on
        // Translation needs the Engine; nudge the user there if it's not ready.
        if Settings.shared.liveTranslationEnabled && !Settings.shared.llmConfigured {
            selectTab("Engine")
        }
        onSettingsChanged?()
    }
    @objc private func sourceLangChanged() {
        Settings.shared.interpreterSourceLanguage = represented(sourceLangPopup)
        onSettingsChanged?()
    }
    @objc private func targetLangChanged() {
        Settings.shared.interpreterTargetLanguage = represented(targetLangPopup)
        onSettingsChanged?()
    }
    @objc private func subtitleChanged() {
        Settings.shared.subtitleOverlayEnabled = subtitleCheck.state == .on
        onSettingsChanged?()
    }

    // MARK: - Meeting actions

    @objc private func audioSourceChanged() {
        Settings.shared.lockedAudioSourceIsSystem = systemRadio.state == .on
        onSettingsChanged?()
    }
    @objc private func meetingNotesChanged() {
        Settings.shared.meetingNotesEnabled = meetingNotesCheck.state == .on
        let provider = represented(notesProviderPopup)
        let needsEngine = provider != "claude"
        if Settings.shared.meetingNotesEnabled && needsEngine && !Settings.shared.llmConfigured {
            selectTab("Engine")
        }
        onSettingsChanged?()
    }

    @objc private func notesProviderChanged() {
        Settings.shared.meetingNotesProvider = represented(notesProviderPopup)
        onSettingsChanged?()
    }

    @objc private func notesProviderInfoTapped() {
        let alert = NSAlert()
        alert.messageText = "Meeting Notes Provider"
        alert.informativeText = """
        Engine (ChatGPT / OpenAI)
        Engine 탭에서 설정한 LLM으로 회의록을 생성합니다. ChatGPT 구독(OAuth) 또는 OpenAI API 키가 필요합니다.

        Claude (via CLI)
        로컬에 설치된 Claude Code CLI(`claude -p`)를 사용합니다. Claude Max/Pro 구독으로 동작하며 별도 API 키가 필요 없습니다.

        사전 준비:
        1. Claude Code 설치 (claude.ai/download)
        2. 터미널에서 `claude` 실행 → 로그인
        3. 이 설정에서 Claude 선택

        Claude CLI가 설치되지 않았거나 로그인되지 않은 상태면 회의록 생성이 실패하고, 전사 원문은 그대로 보존됩니다.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func selectTab(_ identifier: String) {
        guard let tabView = window?.contentView?.subviews.compactMap({ $0 as? NSTabView }).first else { return }
        tabView.selectTabViewItem(withIdentifier: identifier)
    }

    // MARK: - Glossary

    private func refreshGlossaryStatus() {
        let s = Settings.shared
        let count = s.glossaryTerms.count
        if count > 0 {
            glossaryStatusLabel.stringValue = "✓ \(count) terms — \(s.glossaryURL.lastPathComponent)"
            glossaryStatusLabel.textColor = .systemGreen
        } else {
            glossaryStatusLabel.stringValue = "None (optional)"
            glossaryStatusLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func chooseGlossaryTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.message = "Choose a glossary text file (one term per line; \"wrong -> right\" maps a mis-transcription)"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Settings.shared.glossaryURL = url
            self?.refreshGlossaryStatus()
        }
    }

    @objc private func editGlossaryTapped() {
        let url = Settings.shared.glossaryURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let template = """
            # Mac Transcribe glossary — one term per line.
            # Lines starting with # are comments.
            # Map a frequent mis-transcription with:  wrong -> right
            # Examples:
            # Vigloo
            # 스푼라디오
            # jooq -> jOOQ
            """
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Engine (LLM) actions

    private var selectedProvider: LLMProvider {
        LLMProvider.provider(id: represented(providerPopup).isEmpty ? "custom" : represented(providerPopup))
    }

    private func refreshAPIKeyStatus() {
        if selectedProvider.proto == .chatgpt {
            apiKeyLabel.stringValue = "Account:"
            if ChatGPTOAuth.shared.isSignedIn {
                apiKeyStatusLabel.stringValue = "✓ Signed in with ChatGPT"
                apiKeyStatusLabel.textColor = .systemGreen
                chatgptAuthButton.title = "Sign out"
            } else {
                apiKeyStatusLabel.stringValue = "✗ Not signed in"
                apiKeyStatusLabel.textColor = .systemRed
                chatgptAuthButton.title = "Sign in with ChatGPT"
            }
            return
        }
        apiKeyLabel.stringValue = "API Key:"
        let name = Settings.apiKeyEnvName
        if Settings.shared.llmAPIKeyIsSet {
            apiKeyStatusLabel.stringValue = "✓ Set via $\(name)"
            apiKeyStatusLabel.textColor = .systemGreen
        } else {
            apiKeyStatusLabel.stringValue = "✗ Not set ($\(name) or ~/.config/macwhisper/.env)"
            apiKeyStatusLabel.textColor = .systemRed
        }
    }

    @objc private func chatgptAuthTapped() {
        if ChatGPTOAuth.shared.isSignedIn {
            ChatGPTOAuth.shared.signOut()
            refreshAPIKeyStatus()
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "Signed out."
            return
        }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Complete the sign-in in your browser…"
        ChatGPTOAuth.shared.signIn { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshAPIKeyStatus()
                switch result {
                case .success:
                    self.statusLabel.textColor = .systemGreen
                    self.statusLabel.stringValue = "Signed in ✓"
                case .failure(let error):
                    self.statusLabel.textColor = .systemRed
                    self.statusLabel.stringValue = "Sign-in failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func rebuildModelPopup(selecting model: String) {
        modelPopup.removeAllItems()
        let provider = selectedProvider
        modelPopup.addItems(withTitles: provider.models)
        if provider.models.contains(model) {
            modelPopup.selectItem(withTitle: model)
        } else if let first = provider.models.first {
            modelPopup.selectItem(withTitle: first)
        }
    }

    private func applyProviderVisibility() {
        let custom = selectedProvider.isCustom
        modelPopup.isHidden = custom
        modelField.isHidden = !custom
        baseURLField.isEditable = custom
        baseURLField.isSelectable = custom
        baseURLField.textColor = custom ? .labelColor : .secondaryLabelColor
        chatgptAuthButton.isHidden = selectedProvider.proto != .chatgpt
    }

    @objc private func providerChanged() {
        let provider = selectedProvider
        if provider.isCustom {
            if baseURLField.stringValue.isEmpty { baseURLField.stringValue = Settings.shared.llmBaseURL }
            if modelField.stringValue.isEmpty { modelField.stringValue = Settings.shared.llmModel }
        } else {
            baseURLField.stringValue = provider.baseURL
            rebuildModelPopup(selecting: provider.defaultModel)
        }
        applyProviderVisibility()
        refreshAPIKeyStatus()
        statusLabel.stringValue = ""
    }

    private func currentConfig() -> (provider: LLMProvider, baseURL: String, model: String, key: String) {
        let provider = selectedProvider
        let key = Settings.shared.llmAPIKey
        if provider.isCustom {
            let base = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return (provider, base, model, key)
        }
        let model = modelPopup.titleOfSelectedItem ?? provider.defaultModel
        return (provider, provider.baseURL, model, key)
    }

    @objc private func saveTapped() {
        let cfg = currentConfig()
        let s = Settings.shared
        s.llmProviderID = cfg.provider.id
        if cfg.provider.isCustom { s.llmBaseURL = cfg.baseURL }
        s.llmModel = cfg.model
        refreshAPIKeyStatus()
        statusLabel.textColor = .systemGreen
        statusLabel.stringValue = "Saved."
        onSettingsChanged?()
    }

    @objc private func testTapped() {
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Testing…"
        let cfg = currentConfig()
        LLMRefiner.request(text: "Hello", baseURL: cfg.baseURL, apiKey: cfg.key, model: cfg.model, proto: cfg.provider.proto) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let output):
                    self.statusLabel.textColor = .systemGreen
                    self.statusLabel.stringValue = "Success ✓  Response: \(output)"
                case .failure(let error):
                    self.statusLabel.textColor = .systemRed
                    self.statusLabel.stringValue = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        fnMonitor?.captureNextKey = nil
        capturing = .none
    }

    func showWindow() {
        loadValues()
        statusLabel.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
