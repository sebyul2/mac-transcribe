import Cocoa

/// Small window for choosing the dictation trigger key on external keyboards.
/// The Apple Fn key (⌃Fn hold / ⌃⇧Fn lock) always works; this key is the
/// stand-in for keyboards without an Apple Fn: hold it to dictate, hold it
/// with Shift to toggle a locked (long-form) recording.
final class KeySettingsWindowController: NSWindowController, NSWindowDelegate {
    private let currentKeyLabel = NSTextField(labelWithString: "")
    private let changeButton = NSButton()
    private let resetButton = NSButton()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")

    /// The monitor whose capture mode we borrow while recording a new key.
    var fnMonitor: FnKeyMonitor?
    /// Called after the trigger key changed so the app can re-apply it.
    var onTriggerChanged: (() -> Void)?

    private var capturing = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Trigger Key"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "External-keyboard trigger key:")
        title.frame = NSRect(x: 20, y: 146, width: 240, height: 22)
        content.addSubview(title)

        currentKeyLabel.frame = NSRect(x: 260, y: 146, width: 140, height: 22)
        currentKeyLabel.font = .boldSystemFont(ofSize: 13)
        content.addSubview(currentKeyLabel)

        changeButton.title = "Change…"
        changeButton.bezelStyle = .rounded
        changeButton.frame = NSRect(x: 20, y: 104, width: 110, height: 30)
        changeButton.target = self
        changeButton.action = #selector(changeTapped)
        content.addSubview(changeButton)

        resetButton.title = "Reset to Right Ctrl"
        resetButton.bezelStyle = .rounded
        resetButton.frame = NSRect(x: 140, y: 104, width: 160, height: 30)
        resetButton.target = self
        resetButton.action = #selector(resetTapped)
        content.addSubview(resetButton)

        hintLabel.frame = NSRect(x: 20, y: 16, width: 380, height: 80)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.stringValue = """
        Hold the trigger key to dictate; add Shift to start/stop a long-form \
        recording. The Apple keyboard's ⌃Fn / ⌃⇧Fn always works as well.
        Pick a key you don't use for anything else — Right Ctrl, Right Option \
        or F13–F19 work well. Pressing another key while the trigger is held \
        cancels the dictation, so normal shortcuts stay usable.
        """
        content.addSubview(hintLabel)

        refresh()
    }

    private func refresh() {
        let key = Settings.shared.triggerKey
        currentKeyLabel.stringValue = FnKeyMonitor.keyName(page: key.page, usage: key.usage)
        changeButton.title = capturing ? "Press any key…" : "Change…"
        changeButton.isEnabled = !capturing
        resetButton.isEnabled = !capturing
    }

    @objc private func changeTapped() {
        guard let fnMonitor else { return }
        capturing = true
        refresh()
        fnMonitor.captureNextKey = { [weak self] page, usage in
            guard let self else { return }
            self.capturing = false
            Settings.shared.triggerKey = (page, usage)
            self.onTriggerChanged?()
            self.refresh()
        }
    }

    @objc private func resetTapped() {
        Settings.shared.triggerKey = (0x07, 0xE4)
        onTriggerChanged?()
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        // Abandon a pending capture so a later key press doesn't rebind.
        fnMonitor?.captureNextKey = nil
        capturing = false
    }

    func showWindow() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
