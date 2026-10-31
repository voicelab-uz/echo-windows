import Foundation

public enum VocabularyLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case all = "und"
    case uzbekLatin = "uz-Latn"
    case uzbekCyrillic = "uz-Cyrl"
    case kazakhCyrillic = "kk-Cyrl"
    case kazakhLatin = "kk-Latn"
    case kyrgyz = "ky-Cyrl"
    case tajik = "tg-Cyrl"
    case turkmen = "tk-Latn"
    case russian = "ru-Cyrl"
    case english = "en-Latn"
    public var id: Self { self }
    public var title: String {
        switch self {
        case .all: "Barcha tillar"
        case .uzbekLatin: "O‘zbekcha"
        case .uzbekCyrillic: "Ўзбекча"
        case .kazakhCyrillic: "Қазақша"
        case .kazakhLatin: "Qazaqşa"
        case .kyrgyz: "Кыргызча"
        case .tajik: "Тоҷикӣ"
        case .turkmen: "Türkmençe"
        case .russian: "Русский"
        case .english: "English"
        }
    }
}

/// Shared validation and atomic edits for local dictionary words and spoken snippets.
public enum VocabularyRules {
    public struct ImportResult: Sendable {
        public let entries: [VocabularyEntry]
        public let added: Int
        public let skipped: Int
    }

    public static func words(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",\r\n"))
            .map(cleanWord).filter { !$0.isEmpty }
    }

    public static func cleanWord(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func importing(
        _ text: String, language: VocabularyLanguage, into entries: [VocabularyEntry]
    ) throws -> ImportResult {
        // Validate the entire batch before changing anything.
        let words = words(in: text)
        guard words.count <= 10_000 else {
            throw VoiceLabError.storage("Bir martada 10 000 tagacha so‘z kiriting.")
        }
        for word in words { try validateWord(word, isSnippet: false) }
        var keys = Set(
            entries.filter { !$0.isSnippet && $0.language == language }
                .map { TextRules.normalizedKey($0.word) })
        var additions: [VocabularyEntry] = []
        for word in words where keys.insert(TextRules.normalizedKey(word)).inserted {
            additions.append(VocabularyEntry(word: word, language: language))
        }
        return ImportResult(
            entries: entries + additions, added: additions.count, skipped: words.count - additions.count)
    }

    public static func saving(_ entry: VocabularyEntry, in entries: [VocabularyEntry]) throws
        -> [VocabularyEntry]
    {
        var value = entry
        value.word = cleanWord(value.word)
        value.replacement = value.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateWord(value.word, isSnippet: value.isSnippet)
        guard value.replacement.count <= 10_000 else {
            throw VoiceLabError.storage("Almashtirish matni 10 000 belgidan oshmasin.")
        }
        guard
            !entries.contains(where: {
                $0.id != value.id && $0.isSnippet == value.isSnippet
                    && (value.isSnippet || $0.language == value.language)
                    && TextRules.normalizedKey($0.word) == TextRules.normalizedKey(value.word)
            })
        else { throw VoiceLabError.storage("Bu so‘z lug‘atda mavjud.") }
        var result = entries
        if let index = result.firstIndex(where: { $0.id == value.id }) {
            result[index] = value
        } else {
            result.append(value)
        }
        return result
    }

    private static func validateWord(_ word: String, isSnippet: Bool) throws {
        guard !word.isEmpty, word.count <= (isSnippet ? 80 : 200) else {
            throw VoiceLabError.storage(
                isSnippet ? "Ibora 1–80 belgidan iborat bo‘lsin." : "So‘z 1–200 belgidan iborat bo‘lsin.")
        }
    }
}
