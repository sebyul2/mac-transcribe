import Foundation
import IOKit.hid

/// Globally monitors the Fn (Function/Globe) modifier key.
///
/// The Fn/Globe key is not delivered reliably through a CGEvent tap on modern
/// Apple Silicon keyboards — it does not report a stable keycode and does not set
/// the `.maskSecondaryFn` flag. Instead we read it directly from the keyboard's
/// HID interface, where it is exposed on the AppleVendor top-case usage page
/// (page 0xFF, usage 0x03). This requires Input Monitoring permission.
final class FnKeyMonitor {
    /// Which physical key produced a trigger event. The Apple Fn key requires
    /// Ctrl to be held (⌃Fn); a custom trigger key fires on its own.
    enum TriggerSource { case appleFn, custom }

    /// Callbacks receive the HID event capture time. Timing decisions (double-tap
    /// detection) must use it — main-queue dispatch can lag behind the hardware
    /// when the app is busy, which skews Date()-at-handling badly.
    var onFnDown: ((Date, TriggerSource) -> Void)?
    var onFnUp: ((Date) -> Void)?
    /// Fired when any real key goes down while Fn is held — the user is using
    /// Fn as a modifier (Fn+arrows, Fn+F-keys, Fn+Backspace…), not dictating.
    var onComboKeyWhileFnHeld: (() -> Void)?
    /// When set, the next key press is delivered here (for the trigger-key
    /// settings capture) instead of being processed, then cleared.
    var captureNextKey: ((_ page: UInt32, _ usage: UInt32) -> Void)?

    /// User-configurable trigger key for external keyboards (defaults to
    /// Right Ctrl). The Apple Fn key always works in addition.
    var customTrigger: (page: UInt32, usage: UInt32) = (UInt32(kHIDPage_KeyboardOrKeypad), 0xE4)

    /// Display name for a trigger key, for the settings UI.
    static func keyName(page: UInt32, usage: UInt32) -> String {
        if page == 0xFF, usage == 0x03 { return "Fn (Apple)" }
        let names: [UInt32: String] = [
            0xE0: "Left Ctrl", 0xE1: "Left Shift", 0xE2: "Left Option", 0xE3: "Left Cmd",
            0xE4: "Right Ctrl", 0xE5: "Right Shift", 0xE6: "Right Option", 0xE7: "Right Cmd",
            0x68: "F13", 0x69: "F14", 0x6A: "F15", 0x6B: "F16", 0x6C: "F17", 0x6D: "F18", 0x6E: "F19",
            0x39: "Caps Lock", 0x2C: "Space", 0x35: "`", 0x31: "\\",
        ]
        return names[usage] ?? String(format: "Key 0x%02X", usage)
    }

    private var manager: IOHIDManager?
    private var fnDown = false
    private var customDown = false
    /// Either trigger key held: Apple Fn/Globe, or the custom trigger key
    /// (Right Ctrl by default) on external keyboards without an Apple Fn.
    private var triggerDown: Bool { fnDown || customDown }

    /// AppleVendor top-case page + KeyboardFn usage that report the Globe/Fn key.
    private let fnUsagePage: UInt32 = 0xFF
    private let fnUsage: UInt32 = 0x03

    /// Whether the process is allowed to listen to HID input (Input Monitoring).
    var hasInputMonitoringAccess: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Starts monitoring. Returns true only when Input Monitoring is granted and
    /// the HID manager opened successfully.
    func start() -> Bool {
        // Prompt for Input Monitoring if it has not been granted yet. This adds the
        // app to System Settings → Privacy & Security → Input Monitoring.
        if !hasInputMonitoringAccess {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Match the keyboard (where the Fn element lives) and, defensively, any
        // device that primarily exposes the AppleVendor top-case page.
        let matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey as String: Int(fnUsagePage),
             kIOHIDDeviceUsageKey as String: Int(fnUsage)],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context = context else { return }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handle(value: value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        self.manager = manager

        NSLog("MacWhisper[Fn]: start opened=\(opened) inputMonitoring=\(hasInputMonitoringAccess)")
        return opened && hasInputMonitoringAccess
    }

    func stop() {
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)

        let pressed = IOHIDValueGetIntegerValue(value) != 0

        // Trigger-key capture for the settings window: deliver the next real
        // key press (any keyboard key or the Apple Fn) and swallow it.
        if let capture = captureNextKey, pressed {
            let isFn = page == fnUsagePage && usage == fnUsage
            let isKeyboardKey = page == UInt32(kHIDPage_KeyboardOrKeypad) && usage >= 4
            if isFn || isKeyboardKey {
                captureNextKey = nil
                DispatchQueue.main.async { capture(page, usage) }
                return
            }
        }

        if page == fnUsagePage, usage == fnUsage {
            guard pressed != fnDown else { return }
            updateTrigger(&fnDown, pressed: pressed, source: .appleFn, label: "Fn")
            return
        }

        // The configurable trigger key (Right Ctrl by default) acts as the Fn
        // substitute on external (Windows) keyboards.
        if page == customTrigger.page, usage == customTrigger.usage {
            guard pressed != customDown else { return }
            updateTrigger(&customDown, pressed: pressed, source: .custom, label: "Trigger")
            return
        }

        // Any real (non-modifier) key pressed while a trigger is down means it
        // is acting as a modifier for a shortcut. usage >= 4 skips the
        // roll-over/error codes; usage < 0xE0 excludes Ctrl/Shift/Cmd/Opt,
        // which legitimately arrive after Fn in the app's own ⌃Fn / ⌃⇧Fn
        // gestures.
        if triggerDown, page == UInt32(kHIDPage_KeyboardOrKeypad),
           usage >= 4, usage < 0xE0, pressed {
            DispatchQueue.main.async { [weak self] in
                self?.onComboKeyWhileFnHeld?()
            }
        }
    }

    /// Applies a trigger-key state change and fires down/up only when the
    /// combined trigger state actually flips, so holding Fn and the custom
    /// trigger together can't double-fire.
    private func updateTrigger(_ key: inout Bool, pressed: Bool, source: TriggerSource, label: String) {
        let before = triggerDown
        key = pressed
        let after = triggerDown
        guard before != after else { return }
        let at = Date()
        NSLog("MacWhisper[Fn]: \(label) \(pressed ? "DOWN" : "UP")")
        DispatchQueue.main.async { [weak self] in
            if after { self?.onFnDown?(at, source) } else { self?.onFnUp?(at) }
        }
    }
}
