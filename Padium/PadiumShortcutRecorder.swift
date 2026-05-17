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
/// `isTakenBySystem` / `takenByMainMenu` chords with modal alerts,
/// rejects Shift-only chords, and silently drops the Fn modifier.
///
/// Padium's contract is the opposite: while a recorder is active, ALL
/// active keyboard shortcuts (system, other apps, Padium itself) MUST be
/// isolated so the chord lands here, EVERY chord must be recordable
/// (including Shift-only and Fn-augmented), and Padium MUST always
/// override conflicting bindings. So we install a head-inserted
/// `.cghidEventTap` for the duration of capture, swallow every key event
/// globally, build the `Shortcut` from the CGEvent ourselves, persist it
/// through the public `KeyboardShortcuts.setShortcut(_:for:)` API, and
/// store the Fn bit beside it via `ShortcutRegistry.setFnModifier(_:for:)`.
struct PadiumShortcutRecorder: NSViewRepresentable {
    let slot: GestureSlot
    let onChange: () -> Void

    init(
        for slot: GestureSlot,
        onChange: @escaping () -> Void = {}
    ) {
        self.slot = slot
        self.onChange = onChange
    }

    func makeNSView(context: Context) -> PadiumRecorderField {
        PadiumRecorderField(slot: slot, onChange: onChange)
    }

    func updateNSView(_ nsView: PadiumRecorderField, context: Context) {
        nsView.update(slot: slot, onChange: onChange)
    }
}

@MainActor
final class PadiumRecorderField: NSSearchField, NSSearchFieldDelegate {
    private static let minimumWidth: CGFloat = 130
    /// Globe glyph shown in the field when the stored chord includes Fn.
    /// Plain unicode keeps rendering identical across macOS versions and
    /// avoids depending on SF Symbols image attachments inside a field.
    private static let fnGlyph = "🌐 "

    private(set) var slot: GestureSlot
    private var onChange: () -> Void
    private var shortcutName: KeyboardShortcuts.Name {
        ShortcutRegistry.name(for: slot)
    }

    private var canBecomeKey = false
    private var cancelButton: NSButtonCell?
    private nonisolated(unsafe) var shortcutsNameChangeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var windowDidResignKeyObserver: NSObjectProtocol?
    private nonisolated(unsafe) var windowDidBecomeKeyObserver: NSObjectProtocol?

    // Recording-time state — owned on the main run loop.
    private nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    /// Local NSEvent monitor that watches mouseUp while recording so a
    /// click outside the field's bounds blurs (ends) recording — matches
    /// the library recorder's exit behaviour.
    private nonisolated(unsafe) var outsideClickMonitor: Any?
    /// Set while `refreshStringValue()` is updating `stringValue` from
    /// stored state so the AppKit text-change notification it can post
    /// does not get mistaken for a user-initiated clear.
    private var isApplyingStoredValue = false

    init(slot: GestureSlot, onChange: @escaping () -> Void) {
        self.slot = slot
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

        // Watch every shortcut change so re-renders elsewhere keep this
        // field in sync. Also watch UserDefaults so the Fn flag — which
        // lives outside the library — refreshes the rendered glyph.
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
        // NSEvent.removeMonitor is documented thread-safe.
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
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

    func update(slot: GestureSlot, onChange: @escaping () -> Void) {
        self.onChange = onChange
        guard slot != self.slot else { return }
        self.slot = slot
        refreshStringValue()
    }

    private func refreshStringValue() {
        isApplyingStoredValue = true
        defer { isApplyingStoredValue = false }
        let shortcut = KeyboardShortcuts.getShortcut(for: shortcutName)
        let fn = ShortcutRegistry.fnModifier(for: slot)
        if let shortcut {
            stringValue = (fn ? Self.fnGlyph : "") + "\(shortcut)"
        } else if fn {
            // Edge case: someone wrote the Fn flag without a chord. Show
            // the glyph so the user sees the orphan state and can clear.
            stringValue = Self.fnGlyph.trimmingCharacters(in: .whitespaces)
        } else {
            stringValue = ""
        }
        showsCancelButton = !stringValue.isEmpty
    }

    /// Fires when the user clears the field via the search-field cancel
    /// button (the small X). NSSearchField's built-in cancel handler
    /// blanks `stringValue` and posts this notification — without
    /// persisting anywhere — so we have to translate it into a real
    /// `setShortcut(nil)` write or the deletion silently rolls back on
    /// the next launch.
    func controlTextDidChange(_ obj: Notification) {
        guard !isApplyingStoredValue else { return }
        showsCancelButton = !stringValue.isEmpty
        if stringValue.isEmpty {
            commit(shortcut: nil, fnModifier: false)
        }
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
        installOutsideClickMonitor()
        return ok
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endRecording()
    }

    private func endRecording() {
        teardownEventTap()
        teardownOutsideClickMonitor()
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

    // MARK: - Outside-click monitor

    /// While recording, any mouseUp inside Padium that lands outside the
    /// field's bounds blurs the field. Returning the event lets it
    /// continue to its normal target so the user's click still hits the
    /// button/control they actually intended to interact with.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            let pointInWindow = event.locationInWindow
            let pointInView = self.convert(pointInWindow, from: nil)
            // Tiny inset so a stray click on the field's own edge doesn't
            // immediately cancel.
            let allowedBounds = self.bounds.insetBy(dx: -3, dy: -3)
            if !allowedBounds.contains(pointInView) {
                self.window?.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func teardownOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
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
        let hasFn = nsFlags.contains(.function)
        // Anything outside Fn (the only flag with no Carbon equivalent)
        // counts as a "real" modifier presence. Used only to decide that
        // bare Esc / Delete are UI controls vs recordable chords.
        let nonFnModifiers = nsFlags.subtracting(.function)

        // Bare Esc → cancel capture, keep prior value.
        if nonFnModifiers.isEmpty, !hasFn, keyCode == kVK_Escape {
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(nil)
            }
            return nil
        }
        // Bare Delete / Backspace → clear binding (and the Fn flag).
        if nonFnModifiers.isEmpty, !hasFn,
           keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
            DispatchQueue.main.async { [weak self] in
                self?.commit(shortcut: nil, fnModifier: false)
            }
            return nil
        }

        // Accept everything else verbatim. Padium owns the override
        // contract, so Shift-only, Fn+key, modifierless-key, and chords
        // already taken by the system are all recordable.
        let carbonModifiers = nonFnModifiers.carbonFlags
        let shortcut = KeyboardShortcuts.Shortcut(
            carbonKeyCode: keyCode,
            carbonModifiers: carbonModifiers
        )
        DispatchQueue.main.async { [weak self] in
            self?.commit(shortcut: shortcut, fnModifier: hasFn)
        }
        return nil
    }

    private func commit(shortcut: KeyboardShortcuts.Shortcut?, fnModifier: Bool) {
        // Public API: persists into UserDefaults and posts
        // `shortcutByNameDidChange`. `ShortcutHotKeyGuard` then immediately
        // disables the Carbon hotkey registration so Padium never owns the
        // chord at the OS level.
        KeyboardShortcuts.setShortcut(shortcut, for: shortcutName)
        ShortcutRegistry.setFnModifier(fnModifier, for: slot)
        refreshStringValue()
        onChange()
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
