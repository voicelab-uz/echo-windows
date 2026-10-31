import Foundation
import Testing
@testable import VoiceLabCore

@Suite struct VocabularyCorrectionTests {
    @Test func correctionRewritesHeardMisspelling() {
        let fix = VocabularyEntry(word: "wisper flow", replacement: "Wispr Flow", isCorrection: true)
        let snippet = VocabularyEntry(word: "my email", replacement: "you@example.com")
        let text = TextRules.applyingReplacements(to: "I use wisper flow, write to my email.", entries: [fix, snippet])
        #expect(text == "I use Wispr Flow, write to you@example.com.")
        #expect(fix.isCorrection && !fix.isPhrase)
        #expect(snippet.isPhrase)
    }

    @Test func correctionFlagSurvivesSaveAndOldDataStillLoads() throws {
        let fix = VocabularyEntry(word: "btw", replacement: "by the way", isCorrection: true)
        let decoded = try JSONDecoder().decode(VocabularyEntry.self, from: JSONEncoder().encode(fix))
        #expect(decoded.isCorrection)
        let legacy = #"{"id":"\#(UUID().uuidString)","word":"Echo","replacement":""}"#
        #expect(try JSONDecoder().decode(VocabularyEntry.self, from: Data(legacy.utf8)).isCorrection == false)
    }
}
