import Foundation
import Testing

@testable import VoiceLabCore

@Suite struct UzbekAlphabetTests {
    @Test func reportedNotesParagraph() {
        #expect(
            DictationText.render(
                "Salomlar, men yangi alifboni bunday bo’ladi deb o’ylamagandim. Bizning chiroyli alifbomizga ko’z tegibdi.",
                language: .uz, alphabet: .modern, vocabulary: [])
                == "Salomlar, men yangi alifboni bunday böladi deb öylamagandim. Bizning çiroyli alifbomizga köz tegibdi.")
    }
    @Test func convertsApprovedFourLettersAndPreservesCase() {
        #expect(
            UzbekAlphabetConverter.convert("O‘zbekiston, g‘oya, shahar, chiroyli")
                == "Özbekiston, ğoya, şahar, çiroyli")
        #expect(
            UzbekAlphabetConverter.convert("O'ZBEK G'ALABA SHAHAR CHIROQ Shahar Chiroq")
                == "ÖZBEK ĞALABA ŞAHAR ÇIROQ Şahar Çiroq")
    }
    @Test(arguments: Array("'ʻʼ‘’‛`´′＇"))
    func recognizesApostropheVariants(_ apostrophe: Character) {
        let mark = String(apostrophe)
        #expect(UzbekAlphabetConverter.convert("o\(mark)zbek G\(mark)oya") == "özbek Ğoya")
    }
    @Test func punctuationWhitespaceAndTutuqRemainIntact() {
        let input = "  Shahar!\nChiroyli\tma’no, san'at, Is’hoq, tong — 123 😊"
        #expect(
            UzbekAlphabetConverter.convert(input) == "  Şahar!\nÇiroyli\tma’no, san'at, Is’hoq, tong — 123 😊")
    }
    @Test func conversionIsIdempotent() {
        let output = UzbekAlphabetConverter.convert("O'zbekcha shahar, ğoya, Ö, Ç, Ş, Ğ")
        #expect(UzbekAlphabetConverter.convert(output) == output)
    }
    @Test func protectsURLsEmailDomainsAndCode() {
        let input = """
            shahar https://shop.uz/ch?q=sh sh@shop.uz www.shop.uz/ch shop.uz/sh
            `show('ch')` chiroq
            ```swift
            let show = "sh";
            ```
            g‘oya
            """
        let expected = """
            şahar https://shop.uz/ch?q=sh sh@shop.uz www.shop.uz/ch shop.uz/sh
            `show('ch')` çiroq
            ```swift
            let show = "sh";
            ```
            ğoya
            """
        #expect(UzbekAlphabetConverter.convert(input) == expected)
    }
    @Test func unfinishedCodeBlockAndInlineCodeStayVerbatim() {
        #expect(UzbekAlphabetConverter.convert("shahar ```show\nch") == "şahar ```show\nch")
        #expect(UzbekAlphabetConverter.convert("shahar `show\nchiroq") == "şahar `show\nçiroq")
    }
    @Test func uzbekOnlyAndOptIn() {
        let input = "Show character O'zbek"
        for language in DictationLanguage.allCases {
            #expect(
                DictationText.render(input, language: language, alphabet: .current, vocabulary: []) == input)
        }
        for language in [DictationLanguage.en, .ru] {
            #expect(
                DictationText.render(input, language: language, alphabet: .modern, vocabulary: []) == input)
        }
        #expect(
            DictationText.render(input, language: .uz, alphabet: .modern, vocabulary: [])
                == "Show character Özbek")
    }
    @Test func reportedMixedLanguageSentence() {
        #expect(
            DictationText.render(
                "I am switching. Hozir o‘zgartiryapti, chopayapti.",
                language: .uz, alphabet: .modern, vocabulary: [])
                == "I am switching. Hozir özgartiryapti, çopayapti.")
    }
    @Test func mixedLanguagesWithinOneSentence() {
        #expect(
            UzbekAlphabetConverter.convert("Please check: chiroyli shahar, English school, yangi g‘oya.")
                == "Please check: çiroyli şahar, English school, yangi ğoya.")
        #expect(
            UzbekAlphabetConverter.convert("Share the changes, keyin shaharlarimizda tekshiramiz.")
                == "Share the changes, keyin şaharlarimizda tekşiramiz.")
    }
    @Test(arguments: [
        "switching", "SWITCHING", "Show", "character", "check", "church", "shampoo",
        "English", "wish", "research", "shipping", "chat", "chin", "chop", "sham",
        "Chrome", "Shopify", "ChatGPT", "Shakespeare", "O’Connor", "o'clock", "G’day",
        "Shaztopia", "ShaharCloud", "shahar_id", "chiroq2", "shaharЖ", "überchiroq",
        "shopda", "chatni", "switchingni",
    ])
    func preservesEnglishNamesAndUnknownTokens(_ word: String) {
        #expect(UzbekAlphabetConverter.convert("shahar \(word) chiroq") == "şahar \(word) çiroq")
    }
    @Test func preservesFormattingAndQuotedWords() {
        #expect(
            UzbekAlphabetConverter.convert("😊  ‘Shahar’\t\"switching\"\nchiroyli-check, bog‘!")
                == "😊  ‘Şahar’\t\"switching\"\nçiroyli-check, boğ!")
    }
    @Test func recognizesInflectionsWithoutBlindPrefixMatching() {
        #expect(
            UzbekAlphabetConverter.convert("Shaharlarimizda chiroqlarni yoqishdi. O‘ylamagandim, o‘zgartiryapti.")
                == "Şaharlarimizda çiroqlarni yoqişdi. Öylamagandim, özgartiryapti.")
        #expect(UzbekAlphabetConverter.convert("shaharness chiroqify") == "shaharness chiroqify")
    }
    @Test func vocabularyLanguageResolvesUnknownOrAmbiguousWords() {
        let entries = [
            VocabularyEntry(word: "Shahar", language: .english),
            VocabularyEntry(word: "Chiroq", language: .all),
            VocabularyEntry(word: "Shazobod", language: .uzbekLatin),
            VocabularyEntry(word: "chop", language: .uzbekLatin),
        ]
        #expect(
            DictationText.render("Shahar Chiroq Shazobod chop", language: .uz, alphabet: .modern, vocabulary: entries)
                == "Shahar Chiroq Şazobod çop")
    }
    @Test func leavesAlreadyRenderedTextAlone() {
        // Do not guess how to repair historic output or transliterate foreign ç/ş.
        let text = "I am switçing. Hozir özgartiryapti, çopayapti."
        #expect(UzbekAlphabetConverter.convert(text) == text)
    }
    @Test func matchesOldSpellingSnippetAndPreservesLiteralExpansion() {
        let entries = [
            VocabularyEntry(word: "shablon", replacement: "Best wishes, Shavkat\nhttps://shop.uz/ch")
        ]
        #expect(
            DictationText.render(
                "Chiroyli shablon va g‘oya", language: .uz, alphabet: .modern, vocabulary: entries)
                == "Çiroyli Best wishes, Shavkat\nhttps://shop.uz/ch va ğoya")
    }
    @Test func snippetsCannotDamageProtectedTokensInModernMode() {
        let entries = [VocabularyEntry(word: "shop", replacement: "store")]
        #expect(
            DictationText.render(
                "https://shop.uz/ch shop shahar", language: .uz, alphabet: .modern, vocabulary: entries)
                == "https://shop.uz/ch store şahar")
    }
    @Test func emptyAndUnrelatedScriptsStayUnchanged() {
        for input in ["", "Ўзбекистон, шаҳар, ғоя", "Özbekçe", "🌍 123"] {
            #expect(UzbekAlphabetConverter.convert(input) == input)
        }
    }
}
