import AppKit

private final class Presses: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func append(_ value: Bool) { lock.withLock { values.append(value) } }
    var snapshot: [Bool] { lock.withLock { values } }
}

@main
struct GlobalShortcutRegression {
    @MainActor static func main() throws {
        func event(_ key: CGKeyCode, flags: CGEventFlags = [], repeatKey: Bool = false) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
            return event
        }
        let presses = Presses()
        var state = ShortcutEventTapState(selection: .fn) { presses.append($0) }
        let down = event(63, flags: .maskSecondaryFn), up = event(63)
        precondition(state.handle(.flagsChanged, event: down) == nil)
        _ = state.handle(.flagsChanged, event: down)
        precondition(presses.snapshot == [true], "Repeated Fn flags must not toggle twice")

        // Sleep can swallow key-up. Rebuilding on return must accept the very
        // first press, without requiring the user to press Fn twice.
        state = ShortcutEventTapState(selection: .fn) { presses.append($0) }
        _ = state.handle(.flagsChanged, event: down)
        _ = state.handle(.flagsChanged, event: up)
        precondition(presses.snapshot == [true, true, false])
        for disabled in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            _ = state.handle(.flagsChanged, event: down)
            _ = state.handle(disabled, event: down)
            _ = state.handle(.flagsChanged, event: down)
            _ = state.handle(.flagsChanged, event: up)
            precondition(Array(presses.snapshot.suffix(4)) == [true, false, true, false])
        }
        let count = presses.snapshot.count
        precondition(state.handle(.flagsChanged, event: event(63, flags: [.maskSecondaryFn, .maskCommand])) != nil)
        precondition(state.handle(.keyDown, event: event(0)) != nil)
        precondition(presses.snapshot.count == count, "Unrelated keys must pass through")

        let customPresses = Presses()
        let custom = DictationShortcut(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue, keyLabel: "Space")
        let customState = ShortcutEventTapState(selection: custom) { customPresses.append($0) }
        _ = customState.handle(.keyDown, event: event(49, flags: .maskControl))
        _ = customState.handle(.keyDown, event: event(49, flags: .maskControl, repeatKey: true))
        _ = customState.handle(.keyUp, event: event(49))
        precondition(customPresses.snapshot == [true, false])
        let shortcut = GlobalShortcut()
        precondition(!shortcut.isRegistered)
        shortcut.invalidateEventTap()
        shortcut.invalidateEventTap()
        precondition(!shortcut.isRegistered, "Repeated suspension must be safe")
        print("PASS: Fn missing release on sleep, duplicate presses, disabled tap recovery, unrelated keys, custom shortcut and repeated suspension")
    }
}
