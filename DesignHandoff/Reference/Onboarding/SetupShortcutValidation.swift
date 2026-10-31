/// Validation is driven only by the Fn modifier's physical key code, in the focused window.
struct SetupShortcutValidation {
    private(set) var isPressed = false
    private(set) var isValidated = false

    /// Returns true once per press, so held keys cannot restart the effect repeatedly.
    mutating func receive(keyCode: UInt16, functionDown: Bool, isFocused: Bool) -> Bool {
        guard isFocused else { release(); return false }
        guard keyCode == 63, isPressed != functionDown else { return false }
        isPressed = functionDown
        if functionDown { isValidated = true }
        return functionDown
    }

    mutating func release() { isPressed = false }
}
