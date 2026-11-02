import Foundation

/// A small, deterministic on-device vocabulary for everyday Uzbek typing.
/// This hand-curated word list is intentionally conservative: ambiguous edits are suggestions only.
struct UzbekKeyboardDictionary {
    private let words: [String]
    private let known: Set<String>
    private static let apostrophes: Set<Character> = ["'", "‘", "’", "ʻ", "ʼ", "`", "´"]
    private static let english: Set<String> = Set("""
        about after again also back because before being between both call came can chat check come could day did does done down each even every first from get give good great had has have hello help here home how into just know last like little long look made make many more most much must name need never next nice night now only other our out over people please right said same say see send she should show since some still such take tell test text than thank thanks that the their them then there these they thing think this those through time today too two under use very want was way well were what when where which while who why will with work would year yes you your
        swift github google telegram iphone ipad api http https com org net html json code key let var func class print return true false null nil
        short ship shop shirt share sharp chart chair change channel child children choose choice school shoulder shall shell shoot shut shine chop chin cheap clean clear close open file save email message meeting morning tomorrow welcome world
        john jane alex anna mark david sarah michael
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    init() {
        let canonical = Self.commonWords.split(whereSeparator: \.isWhitespace).map { Self.normalize(String($0)) }
        var seen = Set<String>()
        words = canonical.filter { seen.insert($0).inserted }
        known = Set(words)
    }

    func suggestions(for word: String, modern: Bool) -> [String] {
        guard Self.isWord(word), word.count <= 40 else { return [] }
        let value = Self.normalize(word)
        guard value.count >= 2 else { return [] }
        var candidates = words.filter { $0.hasPrefix(value) }
        if value.count >= 3 {
            candidates += words.filter { !$0.hasPrefix(value) && Self.oneEditApart(value, $0) }
        }
        return Array(candidates.prefix(3)).map { Self.matchCase(Self.render($0, modern: modern), to: word) }
    }

    func correction(for word: String, modern: Bool) -> String? {
        guard Self.isWord(word), word.count >= 4, word.count <= 32 else { return nil }
        let value = Self.normalize(word)
        guard !Self.english.contains(word.lowercased()) else { return nil }
        if known.contains(value) {
            let rendered = Self.matchCase(Self.render(value, modern: modern), to: word)
            return rendered == word ? nil : rendered
        }
        // Unknown capitalized words may be names. Leave them for an explicit suggestion tap.
        guard word == word.lowercased() else { return nil }
        let candidates = words.filter { Self.oneEditApart(value, $0) }
        guard candidates.count == 1, let candidate = candidates.first else { return nil }
        return Self.render(candidate, modern: modern)
    }

    static func trailingWord(in context: String) -> String {
        String(context.reversed().prefix(while: { $0.isLetter || apostrophes.contains($0) }).prefix(40).reversed())
    }

    private static func isWord(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isLetter || apostrophes.contains($0) }
    }

    private static func normalize(_ word: String) -> String {
        let apostropheNormalized = String(word.lowercased().map { apostrophes.contains($0) ? "ʼ" : $0 })
        return apostropheNormalized.replacingOccurrences(of: "oʼ", with: "ö")
            .replacingOccurrences(of: "gʼ", with: "ğ")
            .replacingOccurrences(of: "sh", with: "ş")
            .replacingOccurrences(of: "ch", with: "ç")
            .precomposedStringWithCanonicalMapping
    }

    private static func render(_ word: String, modern: Bool) -> String {
        guard !modern else { return word }
        return word.replacingOccurrences(of: "ö", with: "oʻ")
            .replacingOccurrences(of: "ğ", with: "gʻ")
            .replacingOccurrences(of: "ş", with: "sh")
            .replacingOccurrences(of: "ç", with: "ch")
    }

    private static func matchCase(_ result: String, to input: String) -> String {
        if input == input.uppercased() { return result.uppercased() }
        if input.first?.isUppercase == true { return result.prefix(1).uppercased() + result.dropFirst() }
        return result
    }

    /// Levenshtein distance one, also accepting a single adjacent transposition.
    private static func oneEditApart(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1, a != b else { return false }
        if a.count == b.count {
            let mismatches = a.indices.filter { a[$0] != b[$0] }
            if mismatches.count == 1 { return true }
            if mismatches.count == 2 {
                let i = mismatches[0], j = mismatches[1]
                return j == i + 1 && a[i] == b[j] && a[j] == b[i]
            }
            return false
        }
        let short = a.count < b.count ? a : b
        let long = a.count < b.count ? b : a
        var i = 0, j = 0, skipped = false
        while i < short.count && j < long.count {
            if short[i] == long[j] { i += 1; j += 1 }
            else if !skipped { skipped = true; j += 1 }
            else { return false }
        }
        return true
    }

    private static let commonWords = """
        salom assalomu alaykum rahmat marhamat iltimos xayr yaxshi yomon ha yoʻq
        men sen siz u biz ular bu shu oʻsha kim nima qanday qaysi qayer qayerda qachon nega uchun bilan haqida
        bugun ertaga kecha hozir keyin oldin doim yana hali juda ham faqat albatta balki chunki ammo lekin yoki
        kerak mumkin emas bor edi ekan boʻladi boʻldi boʻlsa boʻlish boʻlishi boʻlgan boʻlmagan
        kelish ketish qilish olish berish yozish oʻqish ishlash koʻrish aytish bilish tushunish
        keladi kelaman keldim kelgan keling ketadi ketaman ketdim ketgan boring boraman boradi bordim
        qilaman qiladi qildim qiling olaman oladi oldim oling beraman beradi berdim bering
        yozaman yozadi yozdim yozing oʻqiyman oʻqiydi oʻqidim oʻqing ishlayman ishlaydi ishladim
        koʻraman koʻradi koʻrdim koʻring aytaman aytadi aytdim ayting bilaman biladi bilmayman
        tushundim tushunarli tushunmadim kuting kutaman kutyapman tayyor tayyorman boshlash boshlaymiz
        tugadi tugatish davom etish qayta yuborish yuboring yubordim saqlash saqlang saqlandi nusxa
        oʻzbek oʻzbekcha oʻzbekiston toshkent samarqand buxoro andijon namangan fargʻona nukus qarshi
        shahar qishloq koʻcha uy xona eshik deraza bogʻ maktab universitet kutubxona doʻkon bozor
        ish ishlar ishchi ishxona dars talaba oʻquvchi oʻqituvchi ustoz doʻst doʻstlar oila ota ona bola
        aka uka opa singil inson odam odamlar mehmon hamkasb mijoz rahbar jamoa guruh
        vaqt kun hafta oy yil soat daqiqa soniya tong ertalab kechqurun tun bayram dam olish
        bir ikki uch toʻrt besh olti yetti sakkiz toʻqqiz oʻn yuz ming million birinchi ikkinchi oxirgi
        katta kichik yangi eski uzun qisqa oson qiyin tez sekin chiroyli goʻzal toʻgʻri notoʻgʻri muhim
        ochiq yopiq issiq sovuq toza mazali shirin achchiq oq qora qizil koʻk yashil sariq
        suv choy qahva non ovqat osh shoʻrva goʻsht baliq tuxum sut qatiq meva olma uzum sabzi piyoz
        kitob daftar qalam ruchka qogʻoz telefon kompyuter ekran klaviatura tugma dastur ilova sayt
        internet aloqa xabar xabarlar matn ovoz nutq yozuv qayd qaydlar suhbat savol javob fikr fikrlar
        maʼlumot maʼlumotlar taʼlim taʼtil eʼlon eʼtibor masʼul sanʼat maʼno
        loyiha reja vazifa uchrashuv yigʻilish natija maqsad taklif yordam muammo yechim imkoniyat
        hisob akkaunt kirish chiqish parol til alifbo harf soʻz gap tarjima sozlama sozlamalar
        toʻlov pul narx narxi hisoblash statistika sana manzil xarita yoʻl mashina avtobus poyezd samolyot
        ishga uyga maktabga shaharga bugungi ertangi kechagi yangi yaxshi rahmat kattakon
        kelayapman ketyapman boryapman ishlayapman yozyapman oʻqiyapman kutyapman gapiryapman
        gapiring eshiting tinglash tinglayapman boshlang toʻxtatish toʻxtating ochish yoping oching
        oʻzgartirish oʻzgartiring tanlash tanlang oʻchirish oʻchiring qoʻshish qoʻshing tekshirish tekshiring
        yuklash yuklang yangilash yangilang foydalanish foydalaning roʻyxat roʻyxatdan belgi belgilar
        gʻoya gʻalaba gʻamxoʻr gʻisht oʻrtoq oʻrin oʻzgarish oʻqitish oʻrganish shaxs shaxsiy shart
        shunday shuning shuningdek shirinlik charchadim chiroq choynak choʻntak choʻl chiziq chizma
        barchasi hammasi hech qayerga qayerdan shundan shundaymi yaxshimisiz salomat sogʻliq sogʻlom
        baxt omad tabrik muborak xursand xursandman kechirasiz uzr afsus ishonch ishonaman
        rejalar vazifalar uchrashuvlar loyihalar imkoniyatlar savollar javoblar telefonlar dasturlar
        oilam doʻstim onam otam uyim ishim kitobim vaqtim fikrim hisobim soʻzim tilim
        """
}
