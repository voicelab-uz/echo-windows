import Foundation

@main
struct UzbekKeyboardDictionaryRegression {
    static func main() {
        let dictionary = UzbekKeyboardDictionary()
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }
        expect(dictionary.suggestions(for: "şa", modern: true).contains("şahar"), "Modern prefix")
        expect(dictionary.suggestions(for: "Sha", modern: false).contains("Shahar"), "Current prefix and capitalization")
        expect(dictionary.correction(for: "salmo", modern: true) == "salom", "Transposed typo")
        expect(dictionary.correction(for: "kitobm", modern: true) == nil, "Ambiguous edits stay suggestions")
        expect(dictionary.suggestions(for: "kitobm", modern: true).contains("kitobim"), "Typo suggestions")
        expect(dictionary.suggestions(for: "ÖZ", modern: true).contains("ÖZBEK"), "Uppercase suggestions")
        expect(dictionary.correction(for: "shahar", modern: true) == "şahar", "Convert known spelling")
        expect(dictionary.correction(for: "o'zgartirish", modern: true) == "özgartiriş", "Apostrophe normalization")
        expect(dictionary.correction(for: "şahar", modern: false) == "shahar", "Current alphabet")
        expect(dictionary.correction(for: "hello", modern: true) == nil, "English preservation")
        expect(dictionary.correction(for: "John", modern: true) == nil, "Name preservation")
        expect(dictionary.correction(for: "Salmo", modern: true) == nil, "Unknown capitalized name")
        expect(dictionary.correction(for: "salom123", modern: true) == nil, "Identifier preservation")
        expect(dictionary.correction(for: "https://salmo", modern: true) == nil, "URL preservation")
        expect(dictionary.correction(for: "ha", modern: true) == nil, "Short words unchanged")
        expect(dictionary.correction(for: "salom", modern: true) == nil, "Valid unchanged")
        expect(UzbekKeyboardDictionary.trailingWord(in: "Salom, özbe") == "özbe", "Trailing word")
        expect(UzbekKeyboardDictionary.trailingWord(in: "Salom ").isEmpty, "Whitespace boundary")
        print("Uzbek keyboard dictionary regressions passed")
    }
}
