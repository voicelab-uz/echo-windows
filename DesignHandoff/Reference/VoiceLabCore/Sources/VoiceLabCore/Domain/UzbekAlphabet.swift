import Foundation

public enum UzbekAlphabet: String, CaseIterable, Codable, Sendable, Identifiable {
    case current, modern
    public var id: Self { self }
    public var title: String { self == .current ? "Amaldagi alifbo" : "Yangi alifbo" }
    public var example: String {
        self == .current ? "O‘zbekiston, g‘oya, shahar, chiroyli" : "Özbekiston, ğoya, şahar, çiroyli"
    }
}

/// Optional output spelling, independent of UI language and the server API.
/// Mapping follows the Senate-approved forms published on gov.uz on 2026-09-10.
public enum UzbekAlphabetConverter {
    private static let letters = try! NSRegularExpression(
        pattern: #"[OoGg]['ʻʼ‘’‛`´′＇]|[Ss][Hh]|[Cc][Hh]"#)
    // Keep identifiers, contractions and mixed-script tokens together. Matching
    // only ASCII subranges could convert an Uzbek-looking piece of a foreign word.
    static let words = try! NSRegularExpression(
        pattern: #"[\p{L}\p{M}\p{N}_]+(?:['ʻʼ‘’‛`´′＇][\p{L}\p{M}\p{N}_]+)*(?:(?<=[OoGg])['ʻʼ‘’‛`´′＇])?"#)
    private static let protectedTokens = try! NSRegularExpression(
        pattern:
            #"(?s:(?<![\p{L}\p{N}])```.*?(?:```|\z))|(?<![\p{L}\p{N}])`[^`\r\n]*(?:`|$)|(?i:(?:https?://|www\.)[^\s<>]+)|[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+|(?i:\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}(?:/[^\s<>]*)?)"#,
        options: [.anchorsMatchLines])

    public static func convert(_ text: String) -> String {
        transformProse(text) { convertWords($0, recognition: UzbekWordRecognition()) }
    }

    static func proseForLanguageDetection(_ text: String) -> String {
        let result = NSMutableString(string: text)
        for match in protectedTokens.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            result.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        return result as String
    }

    fileprivate static func transformProse(_ text: String, transform: (String) -> String) -> String {
        var result = ""
        var cursor = text.startIndex
        for match in protectedTokens.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += transform(String(text[cursor..<range.lowerBound]))
            result += text[range]
            cursor = range.upperBound
        }
        result += transform(String(text[cursor...]))
        return result
    }

    fileprivate static func convertWords(
        _ text: String, recognition: UzbekWordRecognition, allowedWords: Set<NSRange>? = nil
    ) -> String {
        let result = NSMutableString(string: text)
        for match in words.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let word = String(text[range])
            guard letters.firstMatch(in: word, range: NSRange(word.startIndex..., in: word)) != nil,
                  recognition.shouldConvert(word), allowedWords?.contains(match.range) ?? true
            else { continue }
            result.replaceCharacters(in: match.range, with: convertLetters(word))
        }
        return result as String
    }

    private static func convertLetters(_ text: String) -> String {
        let result = NSMutableString(string: text)
        for match in letters.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text), let first = text[range].first else { continue }
            let replacement: String
            switch first {
            case "o": replacement = "ö"
            case "O": replacement = "Ö"
            case "g": replacement = "ğ"
            case "G": replacement = "Ğ"
            case "s": replacement = "ş"
            case "S": replacement = "Ş"
            case "c": replacement = "ç"
            case "C": replacement = "Ç"
            default: continue
            }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }
}

public enum DictationText {
    public static func render(
        _ text: String, language: DictationLanguage, alphabet: UzbekAlphabet,
        vocabulary: [VocabularyEntry]
    ) -> String {
        render(text, detectedLanguage: language.rawValue, alphabet: alphabet, vocabulary: vocabulary)
    }

    public static func render(
        _ text: String, detectedLanguage: String, alphabet: UzbekAlphabet,
        vocabulary: [VocabularyEntry]
    ) -> String {
        guard alphabet == .modern else {
            return TextRules.applyingReplacements(to: text, entries: vocabulary)
        }
        let analysis = SpeechLanguages(text: text, reportedLanguage: detectedLanguage, vocabulary: vocabulary)
        let context = !analysis.uzbekWords.isEmpty ? "uz" : detectedLanguage
        let wordRecognition = UzbekWordRecognition(entries: vocabulary)
        // The API language describes the utterance, not every word in it.
        // Protect links/code before splitting around snippets, so neither a
        // trigger inside a URL nor a converted chunk can damage that token.
        return UzbekAlphabetConverter.transformProse(text) { prose in
            TextRules.applyingReplacements(
                to: prose, entries: vocabulary,
                transformUnmatched: { fragment in
                    let words = SpeechLanguages(
                        text: fragment, reportedLanguage: context, vocabulary: vocabulary).uzbekWords
                    return UzbekAlphabetConverter.convertWords(
                        fragment, recognition: wordRecognition, allowedWords: words)
                })
        }
    }
}
