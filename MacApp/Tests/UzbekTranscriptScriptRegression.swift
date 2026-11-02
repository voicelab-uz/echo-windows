import Foundation

@main struct UzbekTranscriptScriptRegression {
    static func main() {
        checkSharedPreferences()
        func check(_ input: String, _ script: UzbekTranscriptScript, _ expected: String, language: String = "uz") {
            let actual = UzbekTranscriptScript.render(input, detectedLanguage: language, script: script)
            precondition(actual == expected, "\(script): \(input)\nExpected: \(expected)\nActual: \(actual)")
        }
        check("O‘zbekiston, g‘oya, shahar, chiroyli!", .modern, "Özbekiston, ğoya, şahar, çiroyli!")
        check("O‘zbekiston, g‘oya, shahar, chiroyli!", .cyrillic, "Ўзбекистон, ғоя, шаҳар, чиройли!")
        check("O'ZBEKISTON G‘OYA SHAHAR CHIROYLI", .modern, "ÖZBEKISTON ĞOYA ŞAHAR ÇIROYLI")
        check("ÖZBEKISTON ĞOYA ŞAHAR ÇIROYLI", .current, "O‘ZBEKISTON G‘OYA SHAHAR CHIROYLI")
        check("Özbekiston, ğoya, şahar, çiroyli!", .cyrillic, "Ўзбекистон, ғоя, шаҳар, чиройли!")
        check("Ер, юрак, ёз, яхши, йўл, эмас, мен.", .current, "Yer, yurak, yoz, yaxshi, yo‘l, emas, men.")
        check("Yer, yurak, yoz, yaxshi, yo‘l, emas, men.", .cyrillic, "Ер, юрак, ёз, яхши, йўл, эмас, мен.")
        check("ma’no, she’r, in’om, san’at, mas’ul", .cyrillic, "маъно, шеър, инъом, санъат, масъул")
        check("ЎЗБЕКИСТОН ШАҲАР ЧИРОЙЛИ", .modern, "ÖZBEKISTON ŞAHAR ÇIROYLI")
        check("Oʻzbek Oʼzbek O’zbek O`zbek O＇zbek", .modern, "Özbek Özbek Özbek Özbek Özbek")
        check("Shahar — 2026! 👋", .cyrillic, "Шаҳар — 2026! 👋")
        let protected = "https://shahar.uz/chiroyli?sh=1 www.shahar.uz shahar.uz test@shahar.uz @shahar #chiroyli user_name userName abc123 `shahar()` ```\nchiroyli()\n```"
        check(protected, .cyrillic, protected)
        check("Shahar: " + protected, .modern, "Şahar: " + protected)
        check("Hello, Shahar!", .cyrillic, "Hello, Shahar!", language: "en")
        check("Привет, Шаҳар!", .modern, "Привет, Шаҳар!", language: "ru")
        check("Shahar", .modern, "Şahar", language: " UZ ")
        check("Shahar", .modern, "Şahar", language: "uzb")
        check("Shahar", .modern, "Shahar", language: "auto")
        check("O‘zbekiston", .current, "O‘zbekiston")
        check("", .cyrillic, "")
        print("Uzbek transcript script regressions passed")
    }

    static func checkSharedPreferences() {
        let localName = "test.echo.script.local." + UUID().uuidString
        let sharedName = "test.echo.script.shared." + UUID().uuidString
        let local = UserDefaults(suiteName: localName)!
        let shared = UserDefaults(suiteName: sharedName)!
        defer {
            local.removePersistentDomain(forName: localName)
            shared.removePersistentDomain(forName: sharedName)
        }
        let key = "echo.dictation.uzbekScript"
        func preferred() -> UzbekTranscriptScript {
            .preferredScript(standard: local, shared: shared)
        }
        precondition(preferred() == .modern, "Fresh output spelling must agree with the modern keyboard")
        shared.set("current", forKey: "echo.uzbek.alphabet")
        precondition(preferred() == .current)
        shared.set("modern", forKey: "echo.uzbek.alphabet")
        precondition(preferred() == .modern)
        local.set("current", forKey: key)
        precondition(preferred() == .current, "An existing app-only script choice must survive migration")
        shared.set("modern", forKey: key)
        precondition(preferred() == .modern, "A keyboard choice must override an older app-only preference")
        precondition(UzbekTranscriptScript.render("O‘zbekiston shahri", detectedLanguage: "uz", script: preferred()) == "Özbekiston şahri")
        shared.set("cyrillic", forKey: key)
        precondition(preferred() == .cyrillic)
        precondition(UzbekTranscriptScript.render("O‘zbekiston shahri", detectedLanguage: "uz", script: preferred()) == "Ўзбекистон шаҳри")
        shared.set("invalid", forKey: key)
        precondition(preferred() == .current, "Invalid shared settings must not erase a valid app preference")
        local.set("invalid", forKey: key)
        precondition(preferred() == .modern, "Invalid canonical values must fall back to the shared alphabet")
    }
}
