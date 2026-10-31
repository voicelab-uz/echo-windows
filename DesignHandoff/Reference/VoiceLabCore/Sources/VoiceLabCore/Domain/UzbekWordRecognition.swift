import Foundation

/// Conservative spelling eligibility, not a general-purpose language detector.
/// Unknown/ambiguous words retain their original spelling. Never infer Uzbek
/// just because a word contains sh/ch or because the surrounding sentence is Uzbek.
struct UzbekWordRecognition {
    private let explicitUzbek: Set<String>
    private let preserved: Set<String>

    init(entries: [VocabularyEntry] = []) {
        // A user-specified spelling takes precedence over the bundled lexicon.
        // Snippet expansions are already kept verbatim by TextRules.
        explicitUzbek = Set(entries.filter { !$0.isSnippet && $0.language == .uzbekLatin }.map { Self.key($0.word) })
        preserved = Set(entries.filter { !$0.isSnippet && $0.language != .uzbekLatin }.map { Self.key($0.word) })
    }

    func shouldConvert(_ word: String) -> Bool {
        // Bound recognition work, and preserve code identifiers/camelCase.
        guard word.count <= 64,
              word == word.lowercased() || word == word.uppercased()
                || String(word.dropFirst()) == String(word.dropFirst()).lowercased()
        else { return false }
        let normalized = Self.key(word)
        guard !preserved.contains(normalized) else { return false }
        if explicitUzbek.contains(normalized) { return true }
        // Shared spellings (e.g. chat, chin, chop, sham) are ambiguous without
        // per-word language metadata. Preserving them is safer than rewriting English.
        guard !UzbekAlphabetLexicon.english.contains(normalized) else { return false }
        if UzbekAlphabetLexicon.uzbek.contains(normalized) { return true }

        // Recognize common inflections only after a known Uzbek stem, with a
        // complete bounded suffix match. A prefix alone is never enough.
        for boundary in normalized.indices.dropFirst(3) {
            let suffix = String(normalized[boundary...])
            guard suffix.utf8.count <= 24 else { continue }
            let stem = String(normalized[..<boundary])
            guard UzbekAlphabetLexicon.uzbek.contains(stem) else { continue }
            let range = NSRange(suffix.startIndex..., in: suffix)
            // Attaching a case suffix to an English word (shopda, chatni)
            // doesn't make its spelling Uzbek. A complete Uzbek verb ending
            // can disambiguate an overlapping verb such as chop + ayapti.
            if !UzbekAlphabetLexicon.english.contains(stem),
               Self.inflection.nominal.firstMatch(in: suffix, range: range) != nil { return true }
            if Self.inflection.verbal.firstMatch(in: suffix, range: range) != nil { return true }
        }
        return false
    }

    private static func key(_ word: String) -> String {
        let marks = Set("ʻʼ‘’‛`´′＇")
        return String(word.lowercased().map { marks.contains($0) ? "'" : $0 })
            .replacingOccurrences(of: "ö", with: "o'")
            .replacingOccurrences(of: "ğ", with: "g'")
            .replacingOccurrences(of: "ş", with: "sh")
            .replacingOccurrences(of: "ç", with: "ch")
    }

    // Common nominal endings and verb forms. This deliberately does not accept
    // arbitrary chains of suffixes; unsupported/uncertain forms stay unchanged.
    private static let inflection: (nominal: NSRegularExpression, verbal: NSRegularExpression) = {
        let possession = "(?:im|ing|i|si|imiz|ingiz|lari)"
        let grammaticalCase = "(?:ni|ning|ga|ka|qa|da|dan)"
        let person = "(?:man|san|miz|siz|lar|m|ng|k|ngiz)"
        let noun = "(?:lar)?\(possession)?\(grammaticalCase)?(?:mi)?"
        let verb = "(?:tir|dir|t|il|in|ish|sh|n)?(?:ma)?(?:"
            + "(?:yap|ayap)(?:ti|man|san|miz|siz|tilar)"
            + "|(?:moqda|yotir)\(person)?"
            + "|(?:a|y)(?:man|san|di|miz|siz|dilar)"
            + "|di(?:m|ng|k|ngiz|lar)?"
            + "|(?:gan|kan|qan)(?:\(person)|\(noun))?"
            + "|(?:gan|kan|qan)di(?:m|ng|k|ngiz|lar)?"
            + "|(?:moq|moqchi|sa)\(person)?"
            + "|(?:ish|sh)\(noun)"
            + "|(?:ib|b)|(?:ing|sin|ay|aylik))"
            + "(?:mi)?"
        return (
            try! NSRegularExpression(pattern: "\\A\(noun)\\z"),
            try! NSRegularExpression(pattern: "\\A\(verb)\\z")
        )
    }()
}
