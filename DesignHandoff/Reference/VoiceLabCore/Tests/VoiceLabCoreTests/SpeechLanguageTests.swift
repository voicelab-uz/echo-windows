import Foundation
import Testing
@testable import VoiceLabCore

@Suite struct SpeechLanguageTests {
    @Test(arguments: ["uz", "en"])
    func mixedUzbekEnglishRegardlessOfDominantLanguage(_ language: String) throws {
        let text = "I am switching. Hozir o‘zgartiryapti, chopayapti."
        let transcript = Transcript(text: text, language: language, durationMS: 2000)
        #expect(transcript.languageCodeForDisplay == "mul")
        #expect(Set(transcript.detectedLanguages ?? []) == ["uz", "en"])
        #expect(DictationText.render(text, detectedLanguage: language, alphabet: .modern, vocabulary: [])
            == "I am switching. Hozir özgartiryapti, çopayapti.")
        let restored = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript))
        #expect(restored.languageCodeForDisplay == "mul")
        #expect(restored.language == language)
    }

    @Test(arguments: [
        ("en", "I am switching. Please check the English spelling."),
        ("en", "The bank manager and the bus driver are here."),
        ("de", "Ich schreibe einen schönen Text. Das ist wirklich schön."),
        ("fr", "Le chat cherche une place dans la chambre."),
        ("tr", "Merhaba, şimdi çalışıyorum. Bugün çok güzel bir gün."),
        ("ru", "Сейчас я говорю по-русски. Всё работает хорошо."),
        ("ja", "今日は日本語で話しています。よろしくお願いします。"),
        ("uz", "Hozir o‘zgartiryapti, chopayapti. Shahar chiroyli."),
    ])
    func monolingualKeepsDetectedLanguage(_ sample: (String, String)) {
        let transcript = Transcript(text: sample.1, language: sample.0, durationMS: 2000)
        #expect(transcript.languageCodeForDisplay == sample.0)
        if sample.0 != "uz" {
            #expect(DictationText.render(sample.1, detectedLanguage: sample.0, alphabet: .modern, vocabulary: []) == sample.1)
        }
    }

    @Test func mixedScriptsAndForeignClausesArePreserved() {
        let text = "Ich schreibe einen schönen Text. Bugun shahar chiroyli. Сейчас я говорю по-русски."
        let transcript = Transcript(text: text, language: "uz", durationMS: 2000)
        #expect(transcript.languageCodeForDisplay == "mul")
        #expect(DictationText.render(text, detectedLanguage: "uz", alphabet: .modern, vocabulary: [])
            == "Ich schreibe einen schönen Text. Bugun şahar çiroyli. Сейчас я говорю по-русски.")
        let foreign = "The chat is open. Le chat cherche une place dans la chambre."
        #expect(Transcript(text: foreign, language: "en", durationMS: 1000).languageCodeForDisplay == "mul")
        #expect(DictationText.render(foreign, detectedLanguage: "en", alphabet: .modern, vocabulary: []) == foreign)
    }

    @Test func switchingInsideASentenceAndTechnicalText() {
        let text = "I am switching hozir o‘zgartiryapti chopayapti"
        #expect(Transcript(text: text, language: "en", durationMS: 1000).languageCodeForDisplay == "mul")
        #expect(DictationText.render(text, detectedLanguage: "en", alphabet: .modern, vocabulary: [])
            == "I am switching hozir özgartiryapti çopayapti")
        let code = "Shahar chiroyli. `I am switching` https://shop.com/ch"
        #expect(Transcript(text: code, language: "uz", durationMS: 1000).languageCodeForDisplay == "uz")
        let foreign = "Hello how are you buenos días cómo estás"
        #expect(Transcript(text: foreign, language: "en", durationMS: 1000).languageCodeForDisplay == "mul")
    }

    @Test func uncertainSingleWordsDoNotInventLanguageSwitches() {
        for word in ["Echo", "Shahar", "chat", "chop", "Chrome", "こんにちは"] {
            let transcript = Transcript(text: word, language: "en", durationMS: 1000)
            #expect(transcript.languageCodeForDisplay == "en")
            #expect(DictationText.render(word, detectedLanguage: "en", alphabet: .modern, vocabulary: []) == word)
        }
        #expect(Transcript(text: "Hello", language: "auto", durationMS: 1000).languageCodeForDisplay == "und")
    }

    @Test func oldSavedTranscriptStillDecodes() throws {
        let data = Data(#"{"id":"old","text":"Salom","language":"uz","durationMS":1000,"createdAt":0}"#.utf8)
        let old = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(old.detectedLanguages == nil)
        #expect(old.languageCodeForDisplay == "uz")
    }

    @Test(arguments: DictationLanguage.allCases)
    func APIAlwaysRequestsAuto(_ oldPreference: DictationLanguage) async throws {
        let transport = StubTransport([(200, tokenJSON()), (200,
            #"{"text":"Ich schreibe einen Text.","language":"de","duration_ms":1000}"#)])
        let http = HTTPClient(transport: transport)
        let auth = try await restoredAuth(http: http, secrets: MemorySecrets())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("RIFF-test-audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await DesktopAPI(http: http, auth: auth).transcribe(file: file, language: oldPreference)
        let multipart = String(decoding: try #require(await transport.uploads.first), as: UTF8.self)
        #expect(multipart.contains("name=\"language\"\r\n\r\nauto\r\n"))
        #expect(result.language == "de" && result.languageCodeForDisplay == "de")
    }

    @Test func statisticsAcceptDetectedLanguagesBeyondTheOldThree() async throws {
        let response = #"{"days":[{"day":"2026-10-21","language":"de","words":5,"recordings":1,"duration_ms":1000},{"day":"2026-10-21","language":"ja","words":5,"recordings":1,"duration_ms":1000}],"from":"2026-04-23","through":"2026-10-21","time_zone":"UTC"}"#
        let transport = StubTransport([(200, tokenJSON()), (200, response)])
        let http = HTTPClient(transport: transport)
        let auth = try await restoredAuth(http: http, secrets: MemorySecrets())
        let result = try await DesktopAPI(http: http, auth: auth).statistics(accountID: "account-a", timeZone: "UTC")
        #expect(result.days.map(\.language) == ["de", "ja"])
    }
}
