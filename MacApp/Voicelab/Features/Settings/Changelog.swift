import Foundation

/// Release notes shipped with the app. Add a new entry at the top for every release;
/// each change is a localization key so it reads in the user's interface language.
struct ChangelogRelease: Identifiable {
    let version: String
    /// Release date as yyyy-MM-dd, so it formats in the user's locale.
    let date: String
    let changes: [String]
    var id: String { version }

    static let all: [ChangelogRelease] = [
        ChangelogRelease(
            version: "1.0", date: "2026-10-27",
            changes: [
                "Sozlamalar asosiy oynaga ko‘chirildi va macOS uslubida qayta yaratildi.",
                "Yangi ishga tushirish usullari: bosib yoqish, bosib turish va ikki marta bosib qo‘lsiz yozish.",
                "Matn kursor turgan joyga joylanadi; matn maydoni bo‘lmasa, buferga nusxalanadi.",
                "Statistika: bugungi natijalar, tejalgan vaqt, faollik grafigi, yutuqlar va rekordlar.",
                "Bosh sahifa, Lug‘at, Qaydlar va Boshlash qo‘llanmasi yangi dizaynga o‘tdi.",
                "Shortcutni sozlamalar qatorining o‘zida yozib olish mumkin.",
                "Mavzu almashtirilganda paydo bo‘ladigan ingichka chiziqlar tuzatildi.",
            ]),
    ]

    @MainActor var formattedDate: String {
        guard let parsed = try? Date(date, strategy: .iso8601.year().month().day()) else { return date }
        return parsed.formatted(.dateTime.day().month(.wide).year().locale(AppLocalization.shared.language.locale))
    }
}
