import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public enum TextRules {
    /// Matches the current desktop dictionary's apostrophe and Unicode normalization.
    public static func normalizedKey(_ text: String) -> String {
        let apostrophes = Set("`´ʻʼ‘’‛′＇")
        let normalized = text.precomposedStringWithCompatibilityMapping
            .map { apostrophes.contains($0) ? Character("ʻ") : $0 }
        return String(normalized).split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    public static func spaced(_ text: String, precedingCharacter: Character?) -> String {
        guard let first = text.first, !first.isWhitespace, let previous = precedingCharacter else {
            return text
        }
        if previous.isWhitespace || "([{<\"'`“‘".contains(previous) || ",.!?;:)]}%”’".contains(first) {
            return text
        }
        return " " + text
    }

    /// Only explicit replacements are applied. Vocabulary is never represented as an unsupported STT prompt.
    public static func applyingReplacements(
        to text: String, entries: [VocabularyEntry],
        transformUnmatched: (String) -> String = { $0 }
    ) -> String {
        let snippets = entries.filter { !$0.word.isEmpty && $0.isSnippet }
        guard !snippets.isEmpty else { return transformUnmatched(text) }
        func fold(_ value: String) -> String {
            value.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "İ", with: "i")
        }
        var replacements: [String: String] = [:]
        for entry in snippets {
            replacements[fold(entry.word).lowercased()] = entry.replacement
        }
        for entry in snippets {
            let variant = fold(entry.word).replacingOccurrences(of: "I", with: "ı").lowercased()
            if replacements[variant] == nil { replacements[variant] = entry.replacement }
        }
        let alternatives = replacements.keys.sorted {
            $0.count == $1.count ? $0 < $1 : $0.count > $1.count
        }.map {
            NSRegularExpression.escapedPattern(for: $0)
                .replacingOccurrences(of: "i", with: "[iİ]")
                .replacingOccurrences(of: "ı", with: "[ıI]")
        }.joined(separator: "|")
        guard
            let regex = try? NSRegularExpression(
                pattern: "(?<![^\\s\\p{P}\\p{S}])(?:\(alternatives))(?=$|[\\s\\p{P}\\p{S}])",
                options: .caseInsensitive)
        else { return transformUnmatched(text) }
        let source = text.precomposedStringWithCanonicalMapping
        var result = ""
        var cursor = source.startIndex
        // Compute matches once. Replacement text must never trigger another snippet.
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range, in: source) else { continue }
            let folded = fold(String(source[range]))
            if let replacement = replacements[folded.lowercased()]
                ?? replacements[folded.replacingOccurrences(of: "I", with: "ı").lowercased()]
            {
                result += transformUnmatched(String(source[cursor..<range.lowerBound]))
                result += replacement
                cursor = range.upperBound
            }
        }
        result += transformUnmatched(String(source[cursor...]))
        return result
    }
}


extension TextRules {
    /// Fits a dictation into the sentence around the cursor, so continuing a sentence
    /// doesn't start with a stray capital and inserting mid-text doesn't add a stray full stop.
    ///
    /// - Empty field, or after `.` `!` `?` `…` or a line break: the first letter is capitalised.
    /// - Mid-sentence (after a word, comma, colon, dash…): the first word is lowercased,
    ///   unless it must stay capitalised: "I", acronyms (AI), mixed case (iPhone, VoiceLab),
    ///   a word from `protectedWords` (the user's dictionary) or a recognised name.
    /// - Text continues after the cursor: a single trailing full stop is dropped.
    ///
    /// Runs entirely on device; nothing about the field is sent anywhere.
    public static func fitted(
        _ text: String, before: String, after: String, protectedWords: Set<String> = []
    ) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        let lead = result.prefix { $0.isWhitespace }
        var body = String(result.dropFirst(lead.count))
        guard let first = body.first else { return text }

        if startsSentence(before) {
            if first.isLetter, first.isLowercase {
                body = first.uppercased() + body.dropFirst()
            }
        } else if first.isLetter, first.isUppercase {
            let word = String(body.prefix { $0.isLetter || "'’ʻʼ‘-".contains($0) })
            if !keepsCapital(word, in: body, context: String(before.suffix(200)), protectedWords: protectedWords) {
                body = first.lowercased() + body.dropFirst()
            }
        }
        result = String(lead) + body

        // The same sentence continues after the cursor ("…go home. tomorrow" → "…go home
        // tomorrow"). A capital after the cursor starts a new sentence, so the stop stays.
        if let next = after.first(where: { !$0.isWhitespace }), next.isLowercase || next.isNumber,
           result.hasSuffix("."), !result.hasSuffix("..") {
            result.removeLast()
        }
        return result
    }

    /// True when the text before the cursor ends a sentence (or there is none).
    static func startsSentence(_ before: String) -> Bool {
        var trimmed = Substring(before)
        while let last = trimmed.last, last == " " || last == "\t" || last == "\u{00A0}" { trimmed.removeLast() }
        guard let last = trimmed.last else { return true }
        if last.isNewline { return true }
        // Closing quotes/brackets after a full stop still end the sentence: He said "Done." ▌
        var index = trimmed.endIndex
        while index > trimmed.startIndex {
            index = trimmed.index(before: index)
            let character = trimmed[index]
            if "\"'”’»)]".contains(character) { continue }
            return ".!?…".contains(character)
        }
        return true
    }

    static func keepsCapital(_ word: String, in text: String, context: String = "",
                             protectedWords: Set<String>) -> Bool {
        guard !word.isEmpty else { return true }
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return true }
        // AI, USA, iPhone, VoiceLab: any capital after the first letter.
        if word.dropFirst().contains(where: \.isUppercase) { return true }
        if protectedWords.contains(word) || protectedWords.contains(where: { $0.hasPrefix(word + " ") }) {
            return true
        }
        return isName(word, in: context + text)
    }

    /// Apple's name tagger only for languages it models; elsewhere (Uzbek, Kazakh…) it
    /// labels any unfamiliar capitalised word a name, so the dictionary decides instead.
    static func isName(_ word: String, in text: String) -> Bool {
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let supported: Set<NLLanguage> = [.english, .german, .french, .spanish, .italian, .portuguese, .russian]
        guard let language = recognizer.dominantLanguage, supported.contains(language) else { return false }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        guard let range = text.range(of: word, options: .backwards) else { return false }
        let (tag, _) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType)
        return tag == .personalName || tag == .placeName || tag == .organizationName
        #else
        return false
        #endif
    }
}
