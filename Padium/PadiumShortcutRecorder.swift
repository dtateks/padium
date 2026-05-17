import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

/// SwiftUI recorder that replaces `KeyboardShortcuts.Recorder` for every
/// Padium gesture slot.
///
/// The library recorder is fed by an in-process `NSEvent` monitor, so any
/// chord already claimed by a global hotkey — Spotlight (⌘Space),
/// Mission Control (⌃↑), App Exposé, the active app's main menu, another
/// daemon's CGEventTap, or even Padium's own previously-stored shortcut
/// — is intercepted before the recorder ever sees it, and the chord
/// "cannot be recorded". On top of that, the library blocks
/// `isTakenBySystem` / `takenByMainMenu` chords with modal alerts.
///
/// Padium's contract is the opposite: while a recorder is active, ALL
/// active keyboard shortcuts (system, other apps, Padium itself) MUST be
/// isolated so the chord lands here, and Padium MUST always be allowed to
/// override conflicting bindings. So we install a head-inserted
/// `.cghidEventTap` for the duration of capture, swallow every key event
/// globally, build the `Shortcut` from the CGEvent ourselves, and persist
/// it through the public `KeyboardShortcuts.setShortcut(_:for:)` API
/// (which bypasses the library recorder's modal gates).
struct PadiumShortcutRecorder: NSViewRepresentable {
    let shortcutName: KeyboardShortcuts.Name
    let onChange: (KeyboardShortcuts.Shortcut?) -> Void

    init(
        for name: KeyboardShortcuts.Name,
        onChange: @escaping (KeyboardShortcuts.Shortcut?) -> Void = { _ in }
    ) {
        self.shortcutName = name
        self.onChange = onChange
    }

    func makeNSView(context: Context) -> PadiumRecorderField {
        PadiumRecorderField(shortcutName: shortcutName, onChange: onChange)
    }

    func updateNSView(_ nsView: PadiumRecorderField, context: Context) {
        nsView.update(shortcutName: shortcutName, onChange: onChange)
    }
}

@MainActor
final class PadiumRecorderField: NSSearchField, NSSearchFieldDelegate {
    private static let minimumWidth: CGFloat = 130

    private(set) var shortcutName: KeyboardShortcuts.Name
    private var onChange: (KeyboardShortcuts.Shortcut?) -> Void

    private var canBecomeKey = false
    private var cancelButton: NSButtonCell?
    private nonisolated(unsafe) var shortcutsNameChangeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var windowDidResignKeyObserver: NSObjectProtocol?
    private nonisolated(unsafe) var windowDidBecomeKeyObserver: NSObjectProtocol?

    // CGEventTap state — owned on the main run loop.
    private nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?

    init(
        shortcutName: KeyboardShortcuts.Name,
        onChange: @escaping (KeyboardShortcuts.Shortcut?) -> Void
    ) {
        self.shortcutName = shortcutName
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: 24))
        self.delegate = self
        self.placeholderString = "Record Shortcut"
        self.alignment = .center
        (cell as? NSSearchFieldCell)?.searchButtonCell = nil
        self.wantsLayer = true
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        self.cancelButton = (cell as? NSSearchFieldCell)?.cancelButtonCell
        refreshStringValue()

        shortcutsNameChangeObserver = NotificationCenter.default.addObserver(
            forName: PadiumNotification.keyboardShortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let changed = notification.userInfo?["name"] as? KeyboardShortcuts.Name
            MainActor.assumeIsolated {
                guard let self else { return }
                if changed == nil || changed == self.shortcutName {
                    self.refreshStringValue()
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit {
        if let obs = shortcutsNameChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = windowDidResignKeyObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = windowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        // Inline tap teardown — deinit is nonisolated under Swift 6 and
        // CGEvent.tapEnable / CFRunLoop APIs are thread-safe.
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
    }

    override var canBecomeKeyView: Bool { canBecomeKey }

    override var intrinsicContentSize: CGSize {
        var size = super.intrinsicContentSize
        size.width = Self.minimumWidth
        return size
    }

    private var showsCancelButton: Bool {
        get { (cell as? NSSearchFieldCell)?.cancelButtonCell != nil }
        set { (cell as? NSSearchFieldCell)?.cancelButtonCell = newValue ? cancelButton : nil }
    }

    func update(
        shortcutName: KeyboardShortcuts.Name,
        onChange: @escaping (KeyboardShortcuts.Shortcut?) -> Void
    ) {
        self.onChange = onChange
        guard shortcutName != self.shortcutName else { return }
        self.shortcutName = shortcutName
        refreshStringValue()
    }

    private func refreshStringValue() {
        let shortcut = KeyboardShortcuts.getShortcut(for: shortcutName)
        stringValue = shortcut.map { "\($0)" } ?? ""
        showsCancelButton = !stringValue.isEmpty
    }

    override func viewDidMoveToWindow() {
        guard let window else {
            if let obs = windowDidResignKeyObserver {
                NotificationCenter.default.removeObserver(obs)
                windowDidResignKeyObserver = nil
            }
            if let obs = windowDidBecomeKeyObserver {
                NotificationCenter.default.removeObserver(obs)
                windowDidBecomeKeyObserver = nil
            }
            endRecording()
            return
        }
        windowDidResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endRecording()
                self.window?.makeFirstResponder(nil)
            }
        }
        windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preventBecomingKey() }
        }
        preventBecomingKey()
    }

    private func preventBecomingKey() {
        canBecomeKey = false
        DispatchQueue.main.async { [weak self] in self?.canBecomeKey = true }
    }

    override func becomeFirstResponder() -> Bool {
        guard window != nil else { return false }
        let ok = super.becomeFirstResponder()
        guard ok else { return ok }
        placeholderString = "Press Shortcut…"
        showsCancelButton = !stringValue.isEmpty
        hideCaret()
        // `ShortcutHotKeyGuard` already keeps every gesture slot disabled
        // at the Carbon level; library `isPaused` is internal so we rely
        // on the guard + the global event tap below for isolation.
        installEventTap()
        return ok
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endRecording()
    }

    private func endRecording() {
        teardownEventTap()
        placeholderString = "Record Shortcut"
        showsCancelButton = !stringValue.isEmpty
        restoreCaret()
    }

    // MARK: - Caret hide/restore (mirrors library behaviour)

    private func hideCaret() {
        (currentEditor() as? NSTextView)?.insertionPointColor = .clear
    }

    private func restoreCaret() {
        (currentEditor() as? NSTextView)?.insertionPointColor = .textColor
    }

    // MARK: - CGEventTap

    private func installEventTap() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let field = Unmanaged<PadiumRecorderField>.fromOpaque(refcon)
                .takeUnretainedValue()
            return field.handleTap(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            // Accessibility not granted yet, or tap creation refused. Fall
            // back to releasing focus so the user can grant permission and
            // retry rather than sit on a dead recorder.
            PadiumLogger.shortcut.error("PadiumShortcutRecorder failed to create event tap")
            window?.makeFirstResponder(nil)
            return
        }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = src
    }

    private func teardownEventTap() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Runs on the main run loop (we attached the tap source there).
    /// Returning `nil` consumes the event globally — so system hotkeys,
    /// other apps, and Padium itself never see the chord during capture.
    private nonisolated func handleTap(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let nsFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            .intersection(.deviceIndependentFlagsMask)

        // Escape with no modifiers → cancel capture, keep prior value.
        if nsFlags.isEmpty, keyCode == kVK_Escape {
            MainActor.assumeIsolated {
                self.window?.makeFirstResponder(nil)
            }
            return nil
        }

        // Delete / Backspace with no modifiers → clear binding.
        if nsFlags.isEmpty,
           keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
            MainActor.assumeIsolated {
                self.commit(shortcut: nil)
            }
            return nil
        }

        // Require a non-shift modifier OR a function/F-key, matching the
        // library's "shift alone doesn't work as a global hotkey" rule.
        let isFunctionLikeKey = keyCode == kVK_F1 || keyCode == kVK_F2
            || keyCode == kVK_F3 || keyCode == kVK_F4 || keyCode == kVK_F5
            || keyCode == kVK_F6 || keyCode == kVK_F7 || keyCode == kVK_F8
            || keyCode == kVK_F9 || keyCode == kVK_F10 || keyCode == kVK_F11
            || keyCode == kVK_F12 || keyCode == kVK_F13 || keyCode == kVK_F14
            || keyCode == kVK_F15 || keyCode == kVK_F16 || keyCode == kVK_F17
            || keyCode == kVK_F18 || keyCode == kVK_F19 || keyCode == kVK_F20

        let hasRealModifier = !nsFlags.subtracting([.shift, .capsLock, .function]).isEmpty
        guard hasRealModifier || isFunctionLikeKey else {
            // Swallow lone keys so neither the system nor the frontmost app
            // reacts mid-recording (no surprise text input, no menu trigger).
            return nil
        }

        // Force-build the Shortcut from carbon codes directly — Padium
        // always overrides, no isTakenBySystem / takenByMainMenu modals.
        let carbonModifiers = nsFlags.subtracting(.function).carbonFlags
        let shortcut = KeyboardShortcuts.Shortcut(
            carbonKeyCode: keyCode,
            carbonModifiers: carbonModifiers
        )
        MainActor.assumeIsolated {
            self.commit(shortcut: shortcut)
        }
        return nil
    }

    private func commit(shortcut: KeyboardShortcuts.Shortcut?) {
        // Public API: persists into UserDefaults and posts
        // `shortcutByNameDidChange`. `ShortcutHotKeyGuard` then immediately
        // disables the Carbon hotkey registration so Padium never owns the
        // chord at the OS level.
        KeyboardShortcuts.setShortcut(shortcut, for: shortcutName)
        refreshStringValue()
        onChange(shortcut)
        window?.makeFirstResponder(nil)
    }
}

// MARK: - Carbon modifier translation
//
// `KeyboardShortcuts.Shortcut(carbonModifiers:)` normalises via
// `NSEvent.ModifierFlags(carbon:)`, so we need the AppKit→Carbon mapping
// without depending on the library's internal extension.
private extension NSEvent.ModifierFlags {
    var carbonFlags: Int {
        var result = 0
        if contains(.command)   { result |= cmdKey }
        if contains(.option)    { result |= optionKey }
        if contains(.control)   { result |= controlKey }
        if contains(.shift)     { result |= shiftKey }
        return result
    }
}
