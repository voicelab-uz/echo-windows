import AppKit
import OSLog
import VoiceLabCore

struct InsertionTextSnapshot: Equatable {
    let value: String
    let selection: NSRange

    var precedingCharacter: Character? {
        selection.location > 0 ? (value as NSString).substring(to: selection.location).last : nil
    }
    /// Up to 200 characters before the cursor and after the selection, for fitting a
    /// dictation into the sentence it continues.
    var textBefore: String {
        String((value as NSString).substring(to: selection.location).suffix(200))
    }
    var textAfter: String {
        String((value as NSString).substring(from: selection.location + selection.length).prefix(200))
    }
    /// The dictation adjusted to this field: casing and full stop from context, then spacing.
    func fitting(_ text: String, protectedWords: Set<String>) -> String {
        TextRules.spaced(
            TextRules.fitted(text, before: textBefore, after: textAfter, protectedWords: protectedWords),
            precedingCharacter: precedingCharacter)
    }
    func replacingSelection(with text: String) -> String {
        (value as NSString).replacingCharacters(in: selection, with: text)
    }
}

enum InsertionFocus {
    case ready(InsertionTextSnapshot?)
    case temporarilyUnavailable
    case changed
    case blocked
}

@MainActor
protocol TextInsertionEnvironment {
    func focus(for target: ExternalTextTarget, readText: Bool) -> InsertionFocus
    func copy(_ text: String) -> InsertionClipboardLease?
    func owns(_ lease: InsertionClipboardLease) -> Bool
    func restore(_ lease: InsertionClipboardLease)
    /// False guarantees that neither event has been posted.
    func postPaste() -> Bool
    func postUnicode(_ units: [UInt16]) -> Bool
    func pause(milliseconds: Int) async throws
}

extension TextInsertionEnvironment {
    func focus(for target: ExternalTextTarget) -> InsertionFocus {
        focus(for: target, readText: true)
    }
}

/// Main-actor ownership protects AppKit and the clipboard. A separate busy gate
/// prevents reentrant async calls from interleaving two insertion transactions.
@MainActor
final class TextInsertionManager {
    static let shared = TextInsertionManager(environment: NativeTextInsertionEnvironment())
    /// Dictionary words that keep their capital when a dictation is fitted mid-sentence.
    static var protectedWords: Set<String> = []

    enum Outcome: Equatable {
        case confirmed, sent, copied, interrupted, busy, cancelled
        var message: String {
            switch self {
            case .confirmed: "Matn joylandi"
            case .sent: "Matn joylash uchun yuborildi"
            case .copied: "Matn nusxalandi"
            case .interrupted: "Matn joylash to‘xtatildi. Natijani tekshiring."
            case .busy: "Matn joylash band. Natijani qo‘lda nusxalang."
            case .cancelled: ""
            }
        }
    }

    private let environment: any TextInsertionEnvironment
    private var inserting = false
    private let log = Logger(subsystem: "uz.voicelab.desktop", category: "text-insertion")

    init(environment: any TextInsertionEnvironment) { self.environment = environment }

    func insert(
        _ text: String, into target: ExternalTextTarget, method: TextInsertionMethod = .automatic
    ) async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        guard !text.isEmpty else { return .confirmed }
        guard !inserting else { return .busy }
        inserting = true
        defer { inserting = false }

        var sent = false
        do {
            var before: InsertionTextSnapshot?
            var prepared = false
            var insertion = text
            var lease: InsertionClipboardLease?
            var useTyping = method == .typing

            // Each iteration checks the same app/window/field. Rebase a changing
            // selection only BEFORE sending any input, then require a stable sample.
            // This covers Cmd+A/Delete, delayed AX updates and brief modifier holds.
            for _ in 0..<16 {
                try Task.checkCancellation()
                if let lease, !environment.owns(lease) { return .interrupted }
                switch environment.focus(for: target, readText: !target.isTerminalSurface) {
                case .changed:
                    log.notice("Insertion kept on clipboard: target focus changed; pid=\(target.processID)")
                    return lease == nil ? copyOnly(text) : .copied
                case .blocked:
                    log.notice("Insertion kept on clipboard: Accessibility or secure input blocked events; pid=\(target.processID)")
                    return lease == nil ? copyOnly(text) : .copied
                case .temporarilyUnavailable:
                    prepared = false
                case .ready(let snapshot):
                    // A terminal can redraw continuously while its input retains
                    // focus. Output must neither delay paste nor add shell spaces.
                    let current = target.isTerminalSurface ? nil : snapshot
                    if prepared, current == before {
                        if useTyping { return try await type(insertion, target: target, sent: &sent) }
                        guard let lease else { return .interrupted }
                        guard environment.postPaste() else {
                            if method == .automatic {
                                environment.restore(lease)
                                return try await type(insertion, target: target, sent: &sent)
                            }
                            return .copied
                        }
                        sent = true
                        return try await verifyPaste(
                            before: before, insertion: insertion, target: target, lease: lease)
                    }
                    before = current
                    prepared = true
                    let rebased = current?.fitting(text, protectedWords: Self.protectedWords)
                        ?? TextRules.spaced(text, precedingCharacter: nil)
                    if !useTyping, lease == nil || insertion != rebased {
                        if let replacement = environment.copy(rebased) {
                            // Republishing after Delete must preserve the user's ORIGINAL
                            // clipboard, not the previous version of our own transcript.
                            lease = InsertionClipboardLease(
                                changeCount: replacement.changeCount,
                                previousItems: lease == nil ? replacement.previousItems : lease?.previousItems
                            )
                        } else if method == .automatic {
                            lease = nil
                            useTyping = true
                        } else {
                            return .interrupted
                        }
                    }
                    insertion = rebased
                }
                // Also gives Electron / web content time to observe clipboard changes.
                try await environment.pause(milliseconds: 80)
            }
            log.notice("Insertion kept on clipboard: focus/modifiers/text did not settle before deadline; pid=\(target.processID)")
            return lease == nil ? copyOnly(text) : .copied
        } catch {
            // Once an input event was posted, never replay a possibly consumed paste.
            return sent ? .interrupted : .cancelled
        }
    }

    private func verifyPaste(
        before: InsertionTextSnapshot?, insertion: String,
        target: ExternalTextTarget, lease: InsertionClipboardLease
    ) async throws -> Outcome {
        guard let before else {
            // No acknowledgement is possible without readable AX text. Keep the
            // clipboard leased long enough for slow consumers, without a blind retry.
            try await environment.pause(milliseconds: 1200)
            return .sent
        }
        let expected = before.replacingSelection(with: insertion)
        for _ in 0..<15 {
            try await environment.pause(milliseconds: 80)
            if case .ready(let after) = environment.focus(for: target), after?.value == expected {
                environment.restore(lease)
                return .confirmed
            }
        }
        return .sent
    }

    private func type(_ text: String, target: ExternalTextTarget, sent: inout Bool) async throws -> Outcome {
        for packet in Self.unicodePackets(text) {
            try Task.checkCancellation()
            guard case .ready = environment.focus(for: target, readText: false) else {
                return sent ? .interrupted : copyOnly(text)
            }
            guard environment.postUnicode(packet) else {
                return sent ? .interrupted : copyOnly(text)
            }
            sent = true
            try await environment.pause(milliseconds: 6)
        }
        return .sent
    }

    private func copyOnly(_ text: String) -> Outcome {
        environment.copy(text) == nil ? .interrupted : .copied
    }

    /// One grapheme per event, except unusually long clusters, which are split
    /// at scalar boundaries. Never truncate a UTF-16 surrogate pair.
    nonisolated static func unicodePackets(_ text: String) -> [[UInt16]] {
        var packets: [[UInt16]] = []
        for character in text {
            let units = Array(String(character).utf16)
            if units.count <= 20 {
                packets.append(units)
            } else {
                var packet: [UInt16] = []
                for scalar in String(character).unicodeScalars {
                    let units = Array(String(scalar).utf16)
                    if packet.count + units.count > 20 {
                        packets.append(packet)
                        packet = []
                    }
                    packet.append(contentsOf: units)
                }
                if !packet.isEmpty { packets.append(packet) }
            }
        }
        return packets
    }
}
