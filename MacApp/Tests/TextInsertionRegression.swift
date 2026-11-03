import AppKit
import Foundation

@MainActor
private final class FakeInsertionEnvironment: TextInsertionEnvironment {
    var state: InsertionFocus = .ready(nil)
    var clipboard = "Original clipboard"
    var revision = 0
    var copyCount = 0
    var restoreCount = 0
    var pasteCount = 0
    var packets: [[UInt16]] = []
    var pauses: [Int] = []
    var textReads: [Bool] = []
    var pasteAvailable = true
    var onPause: ((Int) async throws -> Void)?
    var onType: (() -> Void)?

    func focus(for target: ExternalTextTarget, readText: Bool) -> InsertionFocus {
        textReads.append(readText)
        return state
    }
    func copy(_ text: String) -> InsertionClipboardLease? {
        let old = clipboard
        clipboard = text
        revision += 1
        copyCount += 1
        return InsertionClipboardLease(changeCount: revision, previousItems: [[.string: Data(old.utf8)]])
    }
    func owns(_ lease: InsertionClipboardLease) -> Bool { revision == lease.changeCount }
    func restore(_ lease: InsertionClipboardLease) {
        guard owns(lease), let data = lease.previousItems?.first?[.string] else { return }
        clipboard = String(decoding: data, as: UTF8.self)
        revision += 1
        restoreCount += 1
    }
    func postPaste() -> Bool {
        guard pasteAvailable else { return false }
        precondition(pauses.contains(80), "Clipboard must settle before Cmd+V")
        pasteCount += 1
        return true
    }
    func postUnicode(_ units: [UInt16]) -> Bool {
        packets.append(units)
        onType?()
        return true
    }
    func pause(milliseconds: Int) async throws {
        pauses.append(milliseconds)
        try await onPause?(milliseconds)
    }
}

@main
struct TextInsertionRegression {
    @MainActor static func main() async {
        let target = ExternalTextTarget(processID: 123)

        do {
            let terminal = ExternalTextTarget(processID: 123, isTerminalSurface: true)
            let env = FakeInsertionEnvironment()
            env.state = .ready(.init(value: "shell$", selection: NSRange(location: 6, length: 0)))
            var redraw = 0
            env.onPause = { _ in
                redraw += 1
                let output = "OpenCode redraw \(redraw)"
                env.state = .ready(.init(value: output, selection: NSRange(location: output.utf16.count, length: 0)))
            }
            let outcome = await TextInsertionManager(environment: env).insert("Explain this code", into: terminal)
            precondition(outcome == .sent && env.pasteCount == 1 && env.packets.isEmpty)
            precondition(env.pauses == [80, 1200] && env.clipboard == "Explain this code")
            precondition(env.textReads.allSatisfy { !$0 } && env.restoreCount == 0)
            print("PASS: terminal redraws do not prevent paste, add shell whitespace or restore clipboard before acknowledgement.")
        }
        for focus in [InsertionFocus.changed, .blocked] {
            let terminal = ExternalTextTarget(processID: 123, isTerminalSurface: true)
            let env = FakeInsertionEnvironment()
            env.onPause = { _ in env.state = focus }
            let outcome = await TextInsertionManager(environment: env).insert("Private text", into: terminal)
            precondition(outcome == .copied && env.pasteCount == 0 && env.packets.isEmpty)
        }
        print("PASS: terminal support preserves focus and secure-input checks.")
        do {
            for bundle in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"] {
                precondition(InsertionSurface.isTerminal(bundleID: bundle, role: "AXTextArea"))
                precondition(!InsertionSurface.isTerminal(bundleID: bundle, role: "AXTextField"))
            }
            precondition(!InsertionSurface.isTerminal(bundleID: "com.google.Chrome", role: "AXTextArea"))
            precondition(!InsertionSurface.isTerminal(bundleID: nil, role: "AXTextArea"))
            print("PASS: terminal search fields and browser editors retain normal text validation.")
        }

        do {
            let env = FakeInsertionEnvironment()
            let outcome = await TextInsertionManager(environment: env).insert("Salom", into: target)
            precondition(outcome == .sent && env.pasteCount == 1 && env.packets.isEmpty)
            precondition(env.pauses == [80, 1200] && env.clipboard == "Salom")
            print("PASS: missing AX text does not block paste; 80ms delay and no blind retry.")
        }
        do {
            let env = FakeInsertionEnvironment()
            env.state = .ready(.init(value: "Hi", selection: NSRange(location: 2, length: 0)))
            env.onPause = { ms in
                if env.pasteCount > 0 {
                    env.state = .ready(.init(value: "Hi there", selection: NSRange(location: 8, length: 0)))
                }
            }
            let outcome = await TextInsertionManager(environment: env).insert("there", into: target)
            precondition(outcome == .confirmed && env.restoreCount == 1)
            precondition(env.clipboard == "Original clipboard")
            print("PASS: spacing, AX verification, then clipboard restoration.")
        }
        do {
            let env = FakeInsertionEnvironment()
            env.state = .ready(.init(value: "", selection: NSRange(location: 0, length: 0)))
            env.onPause = { ms in
                if env.pasteCount > 0 {
                    env.state = .ready(.init(value: "Salom", selection: NSRange(location: 5, length: 0)))
                    _ = env.copy("User's new clipboard")
                }
            }
            _ = await TextInsertionManager(environment: env).insert("Salom", into: target)
            precondition(env.restoreCount == 0 && env.clipboard == "User's new clipboard")
            print("PASS: successful insertion never overwrites a newer clipboard.")
        }
        do {
            let env = FakeInsertionEnvironment()
            env.state = .ready(.init(value: "Before", selection: NSRange(location: 6, length: 0)))
            let outcome = await TextInsertionManager(environment: env).insert("after", into: target)
            precondition(outcome == .sent && env.packets.isEmpty && env.restoreCount == 0)
            precondition(env.clipboard == " after")
            print("PASS: stale AX value after paste is not treated as rejection.")
        }
        do {
            let env = FakeInsertionEnvironment()
            env.state = .ready(.init(value: "Before", selection: NSRange(location: 6, length: 0)))
            env.onPause = { _ in
                env.state =
                    env.pasteCount == 0
                    ? .ready(.init(value: "Before", selection: NSRange(location: 0, length: 6)))
                    // Replacing the whole field leaves nothing before the cursor, so the
                    // dictation is fitted as a sentence start: "after" → "After".
                    : .ready(.init(value: "After", selection: NSRange(location: 5, length: 0)))
            }
            let outcome = await TextInsertionManager(environment: env).insert("after", into: target)
            precondition(outcome == .confirmed && env.pasteCount == 1 && env.packets.isEmpty)
            precondition(env.copyCount == 2 && env.clipboard == "Original clipboard")
            print(
                "PASS: same-field selection settles before a single paste; original clipboard survives rebasing."
            )
        }
        for focus in [InsertionFocus.changed, .blocked, .temporarilyUnavailable] {
            let env = FakeInsertionEnvironment()
            env.onPause = { _ in env.state = focus }
            let outcome = await TextInsertionManager(environment: env).insert("Salom", into: target)
            precondition(outcome == .copied && env.pasteCount == 0 && env.packets.isEmpty)
        }
        print("PASS: focus/secure-input changes during the delay prevent all events.")
        do {
            let env = FakeInsertionEnvironment()
            env.onPause = { _ in _ = env.copy("User copy") }
            let outcome = await TextInsertionManager(environment: env).insert("Salom", into: target)
            precondition(outcome == .interrupted && env.pasteCount == 0 && env.clipboard == "User copy")
            print("PASS: intervening clipboard changes cancel paste.")
        }
        do {
            let env = FakeInsertionEnvironment()
            env.pasteAvailable = false
            let outcome = await TextInsertionManager(environment: env).insert("Özbek 👩🏽‍💻", into: target)
            precondition(outcome == .sent && env.pasteCount == 0 && !env.packets.isEmpty)
            precondition(String(decoding: env.packets.flatMap { $0 }, as: UTF16.self) == "Özbek 👩🏽‍💻")
            precondition(env.clipboard == "Original clipboard")
            print("PASS: safe Unicode fallback only when no paste events were posted.")
        }
        do {
            let env = FakeInsertionEnvironment()
            env.pasteAvailable = false
            let outcome = await TextInsertionManager(environment: env).insert(
                "Text", into: target, method: .pasteboard)
            precondition(outcome == .copied && env.packets.isEmpty)
            print("PASS: paste-only mode does not type.")
        }
        do {
            let env = FakeInsertionEnvironment()
            let text =
                "O‘zbekcha ş ğ ö, Русский, 中文, e\u{301}, 👨‍👩‍👧‍👦\n" + "a" + String(repeating: "\u{301}", count: 30)
            let outcome = await TextInsertionManager(environment: env).insert(
                text, into: target, method: .typing)
            precondition(outcome == .sent && env.copyCount == 0 && env.pasteCount == 0)
            precondition(env.packets.allSatisfy { !$0.isEmpty && $0.count <= 20 })
            precondition(String(decoding: env.packets.flatMap { $0 }, as: UTF16.self) == text)
            precondition(env.packets.allSatisfy { Array(String(decoding: $0, as: UTF16.self).utf16) == $0 })
            print("PASS: Unicode typing preserves multilingual UTF-16, emoji, long clusters and newlines.")
        }
        do {
            let env = FakeInsertionEnvironment()
            env.onType = { env.state = .changed }
            let outcome = await TextInsertionManager(environment: env).insert(
                "Long text", into: target, method: .typing)
            precondition(outcome == .interrupted && env.packets.count == 1 && env.copyCount == 0)
            print("PASS: typing stops when focus changes; no full-text replay.")
        }
        for cancelAt in [80, 1200] {
            let env = FakeInsertionEnvironment()
            env.onPause = { ms in if ms == cancelAt { throw CancellationError() } }
            let outcome = await TextInsertionManager(environment: env).insert("Text", into: target)
            precondition(outcome == (cancelAt == 80 ? .cancelled : .interrupted))
            precondition(env.pasteCount == (cancelAt == 80 ? 0 : 1))
            precondition(env.restoreCount == 0 && env.packets.isEmpty)
        }
        print("PASS: cancellation before/after paste does not replay or restore too soon.")
        do {
            let env = FakeInsertionEnvironment()
            let manager = TextInsertionManager(environment: env)
            env.onPause = { ms in
                if ms == 80 {
                    let second = await manager.insert("Second", into: target)
                    precondition(second == .busy)
                }
            }
            _ = await manager.insert("First", into: target)
            precondition(env.copyCount == 1 && env.pasteCount == 1 && env.clipboard == "First")
            print("PASS: reentrant insertion cannot interleave clipboard transactions.")
        }
        do {
            let env = FakeInsertionEnvironment()
            env.state = .temporarilyUnavailable
            env.onPause = { _ in env.state = .ready(nil) }
            let outcome = await TextInsertionManager(environment: env).insert("Text", into: target)
            precondition(outcome == .sent && env.pauses == [80, 80, 1200])
            print("PASS: brief missing focus recovers before posting.")
        }
        do {
            let env = FakeInsertionEnvironment()
            let manager = TextInsertionManager(environment: env)
            for _ in 0..<30 {
                env.state = .ready(.init(value: "Previous", selection: NSRange(location: 8, length: 0)))
                let oldPasteCount = env.pasteCount
                var ticks = 0
                env.onPause = { _ in
                    ticks += 1
                    if env.pasteCount > oldPasteCount {
                        env.state = .ready(.init(value: "Next", selection: NSRange(location: 4, length: 0)))
                    } else if ticks <= 4 {
                        env.state = .temporarilyUnavailable  // Cmd+A/Delete is still held.
                    } else {
                        env.state = .ready(.init(value: "", selection: NSRange(location: 0, length: 0)))
                    }
                }
                let result = await manager.insert("Next", into: target)
                precondition(result == .confirmed && env.pasteCount == oldPasteCount + 1)
                precondition(env.clipboard == "Original clipboard")
            }
            precondition(env.pasteCount == 30 && env.packets.isEmpty)
            print(
                "PASS: 30 rapid paste/delete cycles recover from held modifiers and delayed empty-field snapshots."
            )
        }
        do {
            let env = FakeInsertionEnvironment()
            env.state = .ready(.init(value: "", selection: NSRange(location: 0, length: 0)))
            env.onPause = { _ in
                if env.pasteCount > 0 {
                    env.state = .ready(.init(value: "Quick", selection: NSRange(location: 5, length: 0)))
                }
            }
            let result = await TextInsertionManager(environment: env).insert("Quick", into: target)
            precondition(result == .confirmed && env.pauses == [80, 80])
            print(
                "PASS: readable confirmation completes in 160ms instead of an unconditional 1.2-second wait.")
        }
        do {
            let env = FakeInsertionEnvironment()
            var edits = 0
            env.onPause = { _ in
                edits += 1
                let text = String(repeating: "x", count: edits)
                env.state = .ready(.init(value: text, selection: NSRange(location: edits, length: 0)))
            }
            let result = await TextInsertionManager(environment: env).insert("Pending", into: target)
            precondition(result == .copied && env.pasteCount == 0 && env.pauses.count == 16)
            print(
                "PASS: continuous user edits stop at the bounded preparation deadline without posting input.")
        }
        do {
            let env = FakeInsertionEnvironment()
            env.onPause = { _ in env.state = .changed }
            let result = await TextInsertionManager(environment: env).insert("Private", into: target)
            precondition(result == .copied && env.pasteCount == 0)
            let next = await TextInsertionManager(environment: env).insert("Next", into: target)
            precondition(next == .copied && env.pasteCount == 0)
            print("PASS: recovery never inserts into another app or field.")
        }
        do {
            let original = InsertionFieldIdentity(identifier: "composer", role: "AXTextArea")
            precondition(original.matchesReplacement(.init(identifier: "composer", role: "AXTextArea")))
            precondition(!original.matchesReplacement(.init(identifier: "search", role: "AXTextArea")))
            precondition(!original.matchesReplacement(.init(identifier: "composer", role: "AXTextField")))
            precondition(
                !InsertionFieldIdentity(identifier: "", role: "AXTextArea").matchesReplacement(
                    .init(identifier: "", role: "AXTextArea")))
            print(
                "PASS: recreated editors match only a stable nonempty ID and role, never geometry or contents."
            )
        }
        print("All text insertion regressions passed; no real input events or clipboard changes.")
    }
}
