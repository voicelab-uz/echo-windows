import AppKit
import ApplicationServices
import VoiceLabCore

/// Owns the configured dictation event tap. Installation and teardown run on the main actor.
@MainActor
final class GlobalShortcut {
    private var state: ShortcutEventTapState?
    private var source: CFRunLoopSource?
    private var generation = UUID()
    private var selection: DictationShortcut?
    private let fnPolicy = FnKeyPolicy()
    var isRegistered: Bool {
        guard let tap = state?.tap, let source else { return false }
        return CFMachPortIsValid(tap) && CFRunLoopSourceIsValid(source)
            && CGEvent.tapIsEnabled(tap: tap)
    }

    func register(
        selection: DictationShortcut,
        onPressedChange: @escaping @MainActor (Bool) -> Void,
        action: @escaping @MainActor () -> Void
    ) throws {
        if isRegistered, self.selection == selection {
            if selection.isFn { try fnPolicy.acquire() }
            return
        }
        // A session transition can invalidate an otherwise retained event tap.
        // Keep ownership of the Fn preference when rebuilding the same binding.
        invalidateEventTap()
        if self.selection != selection { try fnPolicy.release() }
        guard AccessibilityAccess.current.isGranted else {
            throw VoiceLabError.storage(
                "Global shortcut uchun System Settings → Privacy & Security → Accessibility bo‘limida Echo’ni yoqing."
            )
        }
        let id = generation
        let state = ShortcutEventTapState(selection: selection) { [weak self] pressed in
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                onPressedChange(pressed)
                if pressed { action() }
            }
        }
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask,
                callback: shortcutEventTapCallback,
                userInfo: Unmanaged.passUnretained(state).toOpaque()
            )
        else {
            throw VoiceLabError.storage(
                "Shortcutni ulab bo‘lmadi. Accessibility ruxsatini tekshiring va qayta ulang.")
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw VoiceLabError.storage("Shortcutni kuzatish ishga tushmadi. Qayta urinib ko‘ring.")
        }
        state.tap = tap
        self.state = state
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.selection = selection
        do {
            if selection.isFn { try fnPolicy.acquire() }
        } catch {
            try? unregister()
            throw error
        }
    }

    func unregister() throws {
        invalidateEventTap()
        selection = nil
        try fnPolicy.release()
    }

    /// Drop stale key state and queued callbacks before locking or after waking.
    /// The Fn preference stays owned until a different binding or clean teardown.
    func invalidateEventTap() {
        generation = UUID()
        if let tap = state?.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        state = nil
    }
}

// A nonisolated C entry point prevents Swift from inferring MainActor isolation.
private func shortcutEventTapCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
    _ context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let context else { return Unmanaged.passUnretained(event) }
    let state = Unmanaged<ShortcutEventTapState>.fromOpaque(context).takeUnretainedValue()
    return state.handle(type, event: event)
}

/// C callback state, confined to the main CFRunLoop (including creation/teardown).
/// Only the Sendable callback crosses into Swift concurrency; no actor assertion
/// runs inside the Quartz callback. Only matching shortcut events are consumed; key repeats never toggle dictation.
final class ShortcutEventTapState {
    var tap: CFMachPort?
    private var pressed = false
    private let selection: DictationShortcut
    private let onChange: @Sendable (Bool) -> Void

    init(selection: DictationShortcut, onChange: @escaping @Sendable (Bool) -> Void) {
        self.selection = selection
        self.onChange = onChange
    }

    func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if pressed {
                pressed = false
                onChange(false)
            }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let modifiers = event.flags.rawValue & UInt64(DictationShortcut.modifierMask.rawValue)
        if let key = selection.modifierKey {
            // A lone modifier key only reports through flagsChanged. The device-specific
            // bit tells the left and right keys apart; the press must not be part of a chord.
            guard type == .flagsChanged, keyCode == key.keyCode else { return Unmanaged.passUnretained(event) }
            let down = event.flags.rawValue & key.deviceFlag != 0
            let others = modifiers & ~UInt64(key.flag.rawValue)
            guard pressed || (down && others == 0) else { return Unmanaged.passUnretained(event) }
            if down != pressed {
                pressed = down
                onChange(down)
            }
            // Only Fn is swallowed; other modifiers keep reaching the system so chords stay intact.
            return selection.isFn ? nil : Unmanaged.passUnretained(event)
        }
        guard keyCode == selection.keyCode else { return Unmanaged.passUnretained(event) }
        if type == .keyUp, pressed {
            pressed = false
            onChange(false)
            return nil
        }
        if type == .keyDown, pressed { return nil }
        if type == .keyDown, modifiers == selection.modifiers {
            if !pressed && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                pressed = true
                onChange(true)
            }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
