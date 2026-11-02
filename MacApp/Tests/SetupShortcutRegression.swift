@main
struct SetupShortcutRegression {
    static func main() {
        var validation = SetupShortcutValidation()
        precondition(!validation.isValidated)
        // Enter, Space, letters, F1, and unrelated modifiers must never pass the check.
        for code: UInt16 in [36, 49, 0, 122, 56] {
            precondition(!validation.receive(keyCode: code, functionDown: false, isFocused: true))
            precondition(!validation.receive(keyCode: code, functionDown: true, isFocused: true))
        }
        precondition(!validation.isValidated && !validation.isPressed)
        precondition(!validation.receive(keyCode: 63, functionDown: false, isFocused: true), "Key-up alone cannot validate.")
        precondition(!validation.receive(keyCode: 63, functionDown: true, isFocused: false), "Background input cannot validate.")
        precondition(!validation.isValidated)

        precondition(validation.receive(keyCode: 63, functionDown: true, isFocused: true))
        precondition(validation.isPressed && validation.isValidated, "Only a focused Fn press unlocks Continue.")
        precondition(!validation.receive(keyCode: 63, functionDown: true, isFocused: true), "A held key triggers only once.")
        precondition(!validation.receive(keyCode: 63, functionDown: false, isFocused: true))
        precondition(!validation.isPressed && validation.isValidated)
        precondition(validation.receive(keyCode: 63, functionDown: true, isFocused: true), "A second press can replay the shimmer.")
        precondition(!validation.receive(keyCode: 63, functionDown: true, isFocused: false))
        precondition(!validation.isPressed && validation.isValidated, "Focus loss releases the key without losing validation.")
        validation.release()
        precondition(validation.isValidated, "Returning from the next page preserves validation.")
        print("PASS: Fn-only validation, unrelated keys, key-up, focus loss, held/repeated presses, and retained success.")
    }
}
