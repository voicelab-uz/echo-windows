import Foundation

/// Output spelling for Uzbek dictation, independent of keyboard and app language.
/// This is deterministic transliteration, not translation or word recognition:
/// unmarked foreign words in an utterance reported as Uzbek are transliterated too.
/// Loanwords whose Cyrillic spelling is not reversible (e.g. сентябрь/сентябр)
/// cannot be recovered without a dictionary. Links, code and identifiers stay intact.
enum UzbekTranscriptScript: String, CaseIterable, Sendable {
    case current, modern, cyrillic

    /// App Group spelling is shared by the keyboard and app; older app-only
    /// selections remain valid until a shared choice is made.
    static func preferredScript(standard: UserDefaults = .standard,
                                shared: UserDefaults? = nil) -> Self {
        let key = "echo.dictation.uzbekScript"
        if let raw = shared?.string(forKey: key), let value = Self(rawValue: raw) { return value }
        if let raw = standard.string(forKey: key), let value = Self(rawValue: raw) { return value }
        if let raw = shared?.string(forKey: "echo.uzbek.alphabet"),
           let value = Self(rawValue: raw), value != .cyrillic { return value }
        return .modern
    }

    static func render(_ text: String, detectedLanguage: String, script: Self) -> String {
        let language = detectedLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard language == "uz" || language == "uzb" else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in protectedTokens.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += convertProse(String(text[cursor..<range.lowerBound]), script: script)
            result += text[range]
            cursor = range.upperBound
        }
        result += convertProse(String(text[cursor...]), script: script)
        return result
    }

    private static let protectedTokens = try! NSRegularExpression(pattern:
        #"(?s:(?<![\p{L}\p{N}])```.*?(?:```|\z))|(?<![\p{L}\p{N}])`[^`\r\n]*(?:`|$)|(?i:(?:https?://|www\.)[^\s<>]+)|[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+|(?i:\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}(?:/[^\s<>]*)?)|(?<![\p{L}\p{N}_])[@#][\p{L}\p{N}_]+"#,
        options: [.anchorsMatchLines])
    private static let words = try! NSRegularExpression(pattern:
        #"[\p{L}\p{M}\p{N}_]+(?:['ʻʼ‘’‛`´′＇][\p{L}\p{M}\p{N}_]+)*(?:(?<=[OoGg])['ʻʼ‘’‛`´′＇])?"#)
    private static let apostrophes: Set<Character> = Set("'ʻʼ‘’‛`´′＇")
    private static let latin: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzöğşç")
    private static let cyrillicLetters: Set<Character> = Set("абвгдеёжзийклмнопрстуфхцчшщъыьэюяўқғҳ")

    private static func convertProse(_ text: String, script: Self) -> String {
        let result = NSMutableString(string: text)
        for match in words.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let word = String(text[range])
            // Digits, underscores, camelCase and mixed scripts often identify code.
            guard !word.contains(where: { $0.isNumber || $0 == "_" }),
                  word.range(of: #"\p{Ll}\p{Lu}"#, options: .regularExpression) == nil else { continue }
            let lowered = word.lowercased()
            let letters = lowered.filter { !apostrophes.contains($0) }
            let isLatin = letters.allSatisfy { latin.contains($0) }
            let isCyrillic = letters.allSatisfy { cyrillicLetters.contains($0) }
            guard isLatin || isCyrillic else { continue }
            let current = isCyrillic ? toLatin(word) : normalizeLatin(word)
            let converted: String
            switch script {
            case .current: converted = current
            case .modern: converted = toModern(current)
            case .cyrillic: converted = isCyrillic ? word : toCyrillic(current)
            }
            result.replaceCharacters(in: match.range, with: converted)
        }
        return result as String
    }

    private static func cased(_ value: String, source: Character, allCaps: Bool) -> String {
        if allCaps { return value.uppercased() }
        guard source.isUppercase else { return value }
        return value.prefix(1).uppercased() + value.dropFirst()
    }

    private static func normalizeLatin(_ word: String) -> String {
        let allCaps = word == word.uppercased()
        let map: [Character: String] = ["ö":"o‘", "ğ":"g‘", "ş":"sh", "ç":"ch"]
        return word.map { character in
            if let value = map[Character(character.lowercased())] {
                return cased(value, source: character, allCaps: allCaps)
            }
            return String(character)
        }.joined()
    }

    private static func toModern(_ word: String) -> String {
        let chars = Array(word)
        var result = "", index = 0
        while index < chars.count {
            let current = chars[index], lower = current.lowercased()
            if index + 1 < chars.count {
                let next = chars[index + 1]
                let pair = lower + next.lowercased()
                let replacement: String?
                if (lower == "o" || lower == "g") && apostrophes.contains(next) {
                    replacement = lower == "o" ? "ö" : "ğ"
                } else { replacement = ["sh":"ş", "ch":"ç"][pair] }
                if let replacement {
                    result += cased(replacement, source: current, allCaps: false)
                    index += 2
                    continue
                }
            }
            result.append(current)
            index += 1
        }
        return result
    }

    private static func toCyrillic(_ word: String) -> String {
        let chars = Array(word), allCaps = word == word.uppercased()
        let singles: [Character: String] = ["a":"а", "b":"б", "d":"д", "f":"ф", "g":"г", "h":"ҳ", "i":"и", "j":"ж", "k":"к", "l":"л", "m":"м", "n":"н", "o":"о", "p":"п", "q":"қ", "r":"р", "s":"с", "t":"т", "u":"у", "v":"в", "x":"х", "y":"й", "z":"з", "c":"с", "w":"в"]
        var result = "", index = 0
        while index < chars.count {
            let current = chars[index], lower = current.lowercased()
            if index + 1 < chars.count {
                let next = chars[index + 1], pair = lower + next.lowercased()
                var replacement: String?
                if (lower == "o" || lower == "g") && apostrophes.contains(next) {
                    replacement = lower == "o" ? "ў" : "ғ"
                } else if pair == "yo", index + 2 < chars.count, apostrophes.contains(chars[index + 2]) {
                    replacement = nil // yo‘l → йўл, not ёъл
                } else { replacement = ["sh":"ш", "ch":"ч", "ya":"я", "yu":"ю", "yo":"ё", "ye":"е"][pair] }
                if let replacement {
                    result += cased(replacement, source: current, allCaps: allCaps)
                    index += 2
                    continue
                }
            }
            let replacement: String
            if lower == "e" {
                let previous = index > 0 ? chars[index - 1].lowercased() : ""
                replacement = index == 0 || "aeiou".contains(previous) || (index > 0 && apostrophes.contains(chars[index - 1])) ? "э" : "е"
            } else if apostrophes.contains(current) { replacement = "ъ" }
            else { replacement = singles[Character(lower)] ?? String(current) }
            result += cased(replacement, source: current, allCaps: allCaps)
            index += 1
        }
        return result
    }

    private static func toLatin(_ word: String) -> String {
        let chars = Array(word), allCaps = word == word.uppercased()
        let map: [Character: String] = ["а":"a", "б":"b", "в":"v", "г":"g", "д":"d", "ё":"yo", "ж":"j", "з":"z", "и":"i", "й":"y", "к":"k", "л":"l", "м":"m", "н":"n", "о":"o", "п":"p", "р":"r", "с":"s", "т":"t", "у":"u", "ф":"f", "х":"x", "ц":"ts", "ч":"ch", "ш":"sh", "щ":"shch", "ъ":"’", "ы":"i", "ь":"", "э":"e", "ю":"yu", "я":"ya", "ў":"o‘", "қ":"q", "ғ":"g‘", "ҳ":"h"]
        return chars.enumerated().map { index, character in
            let lower = Character(character.lowercased())
            var value = map[lower] ?? String(character)
            if lower == "е" {
                let previous = index > 0 ? chars[index - 1].lowercased() : ""
                value = index == 0 || "аеиоуэюяўъь".contains(previous) ? "ye" : "e"
            }
            return cased(value, source: character, allCaps: allCaps)
        }.joined()
    }
}
