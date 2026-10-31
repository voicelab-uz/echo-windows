import Testing
@testable import VoiceLabCore

/// Dictation fitted into the text already around the cursor.
@Suite struct ContextFittingTests {
    @Test(arguments: [
        // (dictation, text before cursor, text after cursor, expected)
        ("Go home", "", "", "Go home"),
        ("go home", "", "", "Go home"),
        ("Go home", "I want to ", "", "go home"),
        ("Go home.", "I want to ", "", "go home."),
        ("Salom, qalaysiz", "Rahmat. ", "", "Salom, qalaysiz"),
        ("salom, qalaysiz", "Rahmat. ", "", "Salom, qalaysiz"),
        ("Do you agree?", "Done!\n", "", "Do you agree?"),
        ("Yes", "Hi, ", "", "yes"),
        ("Tomorrow morning", "Meeting: ", "", "tomorrow morning"),
        ("Bugun", "Men ", "", "bugun"),
        ("Сегодня вечером", "Я приду ", "", "сегодня вечером"),
        ("Next", "He said \"Done.\" ", "", "Next"),
        // Inserting into the middle drops a lone trailing full stop.
        ("Go home.", "I ", " tomorrow.", "go home"),
        ("Go home...", "I ", " tomorrow", "go home..."),
        ("Go home.", "I ", "", "go home."),
        // A capital after the cursor is a new sentence: keep the dictation's full stop.
        ("Hammasi tayyor.", "Oldingi qayd. ", " Oxiri.", "Hammasi tayyor."),
    ])
    func fitsTheSentence(dictation: String, before: String, after: String, expected: String) {
        #expect(TextRules.fitted(dictation, before: before, after: after) == expected)
    }

    @Test(arguments: [
        ("I think so", "Well, "),
        ("I'm here", "Well, "),
        ("AI is everywhere", "Today "),
        ("iPhone is ready", "My "),
        ("VoiceLab works", "Now "),
    ])
    func keepsWordsThatMustStayCapitalised(dictation: String, before: String) {
        #expect(TextRules.fitted(dictation, before: before, after: "") == dictation)
    }

    @Test func keepsDictionaryWordsCapitalised() {
        let words: Set<String> = ["Toshkent", "Echo"]
        #expect(TextRules.fitted("Toshkent shahri", before: "Men ", after: "", protectedWords: words)
                == "Toshkent shahri")
        #expect(TextRules.fitted("Echo yozdi", before: "Bugun ", after: "", protectedWords: words) == "Echo yozdi")
    }

    @Test func leavesNonLettersAndEmptyTextAlone() {
        #expect(TextRules.fitted("", before: "Hi ", after: "") == "")
        #expect(TextRules.fitted("42 apples", before: "I have ", after: "") == "42 apples")
        #expect(TextRules.fitted(" Go", before: "I ", after: "") == " go")
    }
}

@Suite struct ContextNameTests {
    @Test func keepsEnglishNamesCapitalised() {
        #expect(TextRules.fitted("John will call you", before: "Tomorrow morning ", after: "") == "John will call you")
        #expect(TextRules.fitted("London is busy", before: "In winter ", after: "") == "London is busy")
    }
}
