import Foundation
import NaturalLanguage

/// Conservative, on-device text evidence for code switching. The API's language
/// is an audio-level detection, not a language tag for every word. Uncertain text
/// stays unclassified; this never translates or repairs the transcript.
public struct SpeechLanguages: Sendable {
    public let codes: [String]
    let uzbekWords: Set<NSRange>

    public init(text: String, reportedLanguage: String, vocabulary: [VocabularyEntry] = []) {
        let recognition = UzbekWordRecognition(entries: vocabulary)
        var found = Set<String>()
        var confirmedUzbek = Set<NSRange>()
        var candidates = Set<NSRange>()
        let source = text as NSString
        // Mask technical tokens without changing UTF-16 offsets.
        let prose = UzbekAlphabetConverter.proseForLanguageDetection(text)
        for clause in Self.clauses.matches(in: prose, range: NSRange(location: 0, length: source.length)) {
            let tokens = UzbekAlphabetConverter.words.matches(in: prose, range: clause.range).map(\.range)
            // Script changes are useful boundaries even without punctuation.
            var groups: [[NSRange]] = []
            for token in tokens {
                let word = source.substring(with: token)
                if let last = groups.last?.last,
                   Self.script(source.substring(with: last)) == Self.script(word) {
                    groups[groups.count - 1].append(token)
                } else { groups.append([token]) }
            }
            for group in groups {
                let content = group.map { source.substring(with: $0) }.joined(separator: " ")
                let recognized = Set(group.filter {
                    let word = source.substring(with: $0)
                    return word.count >= 3 && recognition.shouldConvert(word)
                })
                let uzbekEvidence = (recognized.count >= 2 && Double(recognized.count) / Double(group.count) >= 0.6)
                    || recognized.contains {
                        source.substring(with: $0).range(
                            of: #"[OoGg]['ʻʼ‘’‛`´′＇]"#, options: .regularExpression) != nil
                    }
                // A clearly foreign clause wins over overlapping dictionary words.
                // The OS has no Uzbek model, so strong Uzbek evidence must be
                // checked first, including its distinctive o‘/g‘ letters.
                if !uzbekEvidence, let language = Self.detect(content, minimumConfidence: 0.90),
                   group.count >= 2 || Self.script(content) != 0 {
                    found.insert(language)
                    found.formUnion(Self.foreignSwitches(group.map { source.substring(with: $0) }))
                    continue
                }
                var run: [NSRange] = []
                var remainder: [NSRange] = []
                func finishRun() {
                    if run.count >= 2 {
                        confirmedUzbek.formUnion(run)
                        found.insert("uz")
                    }
                    candidates.formUnion(run)
                    run.removeAll(keepingCapacity: true)
                }
                func finishRemainder() {
                    let words = remainder.map { source.substring(with: $0) }
                    let switches = Self.foreignSwitches(words)
                    if switches.count > 1 {
                        found.formUnion(switches)
                    } else if remainder.count >= 2,
                       let language = Self.detect(
                        words.joined(separator: " "),
                        minimumConfidence: 0.80) { found.insert(language) }
                    remainder.removeAll(keepingCapacity: true)
                }
                for token in group {
                    if recognized.contains(token) {
                        finishRemainder()
                        run.append(token)
                    } else {
                        finishRun()
                        remainder.append(token)
                    }
                }
                finishRun()
                finishRemainder()
            }
        }
        // A lone ambiguous Uzbek-looking word in foreign speech is insufficient.
        // Once Uzbek is established, recognize isolated inflections after commas.
        if reportedLanguage == "uz" || !confirmedUzbek.isEmpty {
            confirmedUzbek.formUnion(candidates)
            if !confirmedUzbek.isEmpty { found.insert("uz") }
        }
        uzbekWords = confirmedUzbek
        codes = found.count > 1 ? found.sorted() : [reportedLanguage]
    }

    public static func isLanguageCode(_ code: String) -> Bool {
        code.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil
            && code != "und" && code != "mul"
    }

    private static let clauses = try! NSRegularExpression(pattern: #"[^\r\n.!?;:,]+"#)
    private static let scripts = ["Latin", "Cyrillic", "Arabic", "Devanagari", "Hangul"].map {
        try! NSRegularExpression(pattern: "\\p{\($0)}")
    }
    private static func script(_ word: String) -> Int {
        scripts.firstIndex { $0.firstMatch(in: word, range: NSRange(word.startIndex..., in: word)) != nil }
            ?? scripts.count
    }
    private static func foreignSwitches(_ words: [String]) -> Set<String> {
        // Require separate, non-overlapping phrases. A borrowed word or brand
        // must not turn an otherwise monolingual recording into “Multilingual”.
        // Bound the extra model work for long, unpunctuated transcripts.
        guard (8...80).contains(words.count) else { return [] }
        var found = Set<String>()
        var start = 0
        while start + 4 <= words.count {
            if let code = detect(words[start..<(start + 4)].joined(separator: " "), minimumConfidence: 0.90) {
                found.insert(code)
                start += 4
            } else { start += 1 }
        }
        return found.count > 1 ? found : []
    }
    private static func detect(_ text: String, minimumConfidence: Double) -> String? {
        guard text.count >= 8 else { return nil }
        let detector = NLLanguageRecognizer()
        detector.processString(text)
        guard let best = detector.languageHypotheses(withMaximum: 1).first,
              best.value >= minimumConfidence else { return nil }
        // Apple does not currently identify Uzbek. Use lexical evidence above;
        // never treat low-confidence Turkish/Indonesian guesses as Uzbek.
        return best.key.rawValue.components(separatedBy: "-")[0]
    }
}

extension Transcript {
    /// `auto` is an input mode. It must never become a displayed speech language.
    public var languageCodeForDisplay: String {
        if language == "mul" || Set(detectedLanguages ?? []).count > 1 { return "mul" }
        return SpeechLanguages.isLanguageCode(language) ? language : "und"
    }
}
