import Foundation
import Testing

@testable import VoiceLabCore

@Suite struct VocabularyTests {
    @Test func existingLibraryMigratesWithoutLosingIDsOrReplacements() throws {
        let id = UUID()
        let data = Data(
            """
            {"schemaVersion":1,"transcripts":[],"notes":[],"vocabulary":[
              {"id":"\(id)","word":"imzo","replacement":"Mardon"}
            ]}
            """.utf8)
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: data)
        let entry = try #require(snapshot.vocabulary.first)
        #expect(entry.id == id && entry.isSnippet && entry.replacement == "Mardon")
        #expect(entry.language == .all)
        let restored = try JSONDecoder().decode(LibrarySnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.vocabulary == snapshot.vocabulary)
    }

    @Test func bulkImportTrimsNormalizesAndDeduplicates() throws {
        let result = try VocabularyRules.importing(
            "  VoiceLab,voicelab\nO‘rik\r\nOʼrik\n\nCafé,Cafe\u{301}", language: .all, into: [])
        #expect(result.added == 3 && result.skipped == 3)
        #expect(result.entries.map(\.word) == ["VoiceLab", "O‘rik", "Café"])
    }

    @Test func dictionaryLanguageAndSnippetAreSeparateNamespaces() throws {
        let snippet = VocabularyEntry(word: "salom", replacement: "Assalomu alaykum")
        let uz = try VocabularyRules.importing("salom", language: .uzbekLatin, into: [snippet])
        let en = try VocabularyRules.importing("salom", language: .english, into: uz.entries)
        let duplicate = try VocabularyRules.importing("SALOM", language: .uzbekLatin, into: en.entries)
        #expect(duplicate.entries.count == 3)
        #expect(duplicate.added == 0 && duplicate.skipped == 1)
    }

    @Test func invalidBatchDoesNotPartiallyChangeExistingWords() throws {
        let entries = [VocabularyEntry(word: "Existing")]
        #expect(throws: VoiceLabError.self) {
            try VocabularyRules.importing(
                "Valid,\(String(repeating: "x", count: 201))", language: .all, into: entries)
        }
        #expect(entries.count == 1 && entries[0].word == "Existing")
    }

    @Test func editPreservesIdentityAndRejectsDuplicates() throws {
        let first = VocabularyEntry(word: "One")
        let second = VocabularyEntry(word: "Two")
        var edit = first
        edit.word = "Updated"
        let saved = try VocabularyRules.saving(edit, in: [first, second])
        #expect(saved[0].id == first.id && saved[0].word == "Updated")
        edit.word = "TWO"
        #expect(throws: VoiceLabError.self) { try VocabularyRules.saving(edit, in: saved) }
    }

    @Test func snippetValidationRejectsBlankAndOversizedInput() {
        for entry in [
            VocabularyEntry(word: " ", replacement: "text"),
            VocabularyEntry(word: String(repeating: "x", count: 81), replacement: "text"),
            VocabularyEntry(word: "trigger", replacement: String(repeating: "x", count: 10_001)),
        ] {
            #expect(throws: VoiceLabError.self) { try VocabularyRules.saving(entry, in: []) }
        }
    }

    @Test func expansionIsSinglePassAndLongestTriggerWins() {
        let entries = [
            VocabularyEntry(word: "hello world", replacement: "short"),
            VocabularyEntry(word: "hello", replacement: "other"),
            VocabularyEntry(word: "short", replacement: "SHOULD NOT CASCADE"),
        ]
        #expect(
            TextRules.applyingReplacements(to: "Hello world! hello.", entries: entries) == "short! other.")
    }

    @Test func expansionPreservesLiteralTextAndDoesNotMatchInsideWords() {
        let entries = [VocabularyEntry(word: "lab", replacement: "$1\\name\nNext")]
        #expect(
            TextRules.applyingReplacements(to: "Laboratoriya lab.", entries: entries)
                == "Laboratoriya $1\\name\nNext.")
    }

    @Test func unicodeAndDottedIMatchLikeDesktopSnippets() {
        let entries = [
            VocabularyEntry(word: "İmza", replacement: "Signed"),
            VocabularyEntry(word: "café", replacement: "Coffee"),
        ]
        #expect(
            TextRules.applyingReplacements(to: "imza İMZA cafe\u{301}", entries: entries)
                == "Signed Signed Coffee")
    }

    @Test func plainDictionaryWordsNeverRewriteTranscripts() {
        #expect(
            TextRules.applyingReplacements(to: "voicelab", entries: [VocabularyEntry(word: "VoiceLab")])
                == "voicelab")
    }

    @Test func languageAndSnippetsPersistInEncryptedAccountLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory, secrets: MemorySecrets())
        var snapshot = LibrarySnapshot()
        snapshot.vocabulary = [
            VocabularyEntry(word: "Atama", language: .uzbekLatin),
            VocabularyEntry(word: "signature", replacement: "Mardon\nVoiceLab"),
        ]
        try await store.save(snapshot, accountID: "test-account")
        let restored = try await store.load(accountID: "test-account")
        #expect(restored.vocabulary == snapshot.vocabulary)
        #expect(try await store.load(accountID: "other-account").vocabulary.isEmpty)
    }
}
