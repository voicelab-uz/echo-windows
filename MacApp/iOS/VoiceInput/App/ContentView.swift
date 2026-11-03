import SwiftUI

/// Uses the same light/dark color assets as the desktop workspace.
enum EchoMobileTheme {
    static let canvas = Color("WorkspaceCanvas")
    static let surface = Color("WorkspaceSurface")
    static let ink = Color("WorkspaceAccent")
    static let accent = Color("VoicelabAccent")
    static let selection = Color("WorkspaceSelection")
    static let border = Color.primary.opacity(0.08)
}

struct MobileSurface: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(EchoMobileTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Frontend SVG artwork with matching round-outline symbols for mobile-only actions.
struct MobileIcon: View {
    let systemName: String
    var size: CGFloat = 20
    static let assets = [
        "text.alignleft": "file-text", "chart.bar": "chart-no-axes-combined",
        "person.crop.circle": "user-round", "person.fill": "user-round",
        "slider.horizontal.3": "settings-2", "waveform": "mic", "mic": "mic",
        "calendar": "calendar-days", "clock.badge.checkmark": "clock-3",
        "creditcard": "credit-card", "rectangle.portrait.and.arrow.right": "log-out",
        "arrow.up.right": "external-link", "arrow.up.right.square": "external-link",
        "chevron.right": "chevron-right", "checkmark.circle.fill": "circle-check",
        "info.circle": "info", "desktopcomputer": "monitor", "iphone": "smartphone",
        "wifi.exclamationmark": "triangle-alert", "magnifyingglass": "search",
        "doc.on.doc": "copy", "trash": "trash-2", "arrow.clockwise.circle": "rotate-cw"
    ]
    var body: some View {
        Group {
            if let asset = Self.assets[systemName] {
                Image("MobileIcon-" + asset).renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: systemName).font(.system(size: size, weight: .regular))
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(EchoMobileTheme.ink)
        .accessibilityHidden(true)
    }
}

struct MobileLabel: View {
    let title: String
    let systemImage: String
    init(_ title: String, systemImage: String) { self.title = title; self.systemImage = systemImage }
    var body: some View {
        Label { Text(title) } icon: { MobileIcon(systemName: systemImage, size: 18) }
    }
}

/// UITabBar uses UIImage's intrinsic size, ignoring SwiftUI frame modifiers.
/// Render the original vector into a real 24-point image before handing it to iOS.
@MainActor enum MobileTabArtwork {
    static let notes = render("MobileIcon-file-text", fallback: "doc.text")
    static let statistics = render("MobileIcon-chart-no-axes-combined", fallback: "chart.bar")
    static let profile = render("MobileIcon-user-round", fallback: "person.crop.circle")

    private static func render(_ name: String, fallback: String) -> UIImage {
        let source = UIImage(named: name) ?? UIImage(systemName: fallback)
        let size = CGSize(width: 24, height: 24)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            guard let source, source.size.width > 0, source.size.height > 0 else { return }
            let scale = min(size.width / source.size.width, size.height / source.size.height)
            let fitted = CGSize(width: source.size.width * scale, height: source.size.height * scale)
            source.withRenderingMode(.alwaysOriginal).draw(in: CGRect(
                x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                width: fitted.width, height: fitted.height))
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

struct MobileTabLabel: View {
    let title: String
    let image: UIImage
    var body: some View {
        Label { Text(title) } icon: { Image(uiImage: image) }
    }
}

struct WorkspaceLoading: View {
    let title: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(EchoMobileTheme.accent)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct Note: Identifiable, Hashable {
    let id: String
    let text: String
    let createdAt: Date
    let isDictation: Bool

    init(id: String = UUID().uuidString, text: String, createdAt: Date, isDictation: Bool = false) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.isDictation = isDictation
    }
}

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var selectedNote: Note?
    @State private var composer = ComposerModel()
    @State private var keyboardHost = KeyboardSessionHost.shared
    @State private var notes: [Note] = []
    @State private var noteSearch = ""
    @State private var historyItems: [EchoDictationHistory.Item] = []
    @State private var historyCursor: String?
    @State private var historyLoading = false
    @State private var historyLoaded = false
    @State private var historyRefreshPending = false
    @State private var historyError: String?
    @AppStorage("echo.dictation.uzbekScript") private var transcriptScript = "current"
    @AppStorage("echo.dictation.language") private var preferredLanguage = DictationLanguage.auto.rawValue
    @AppStorage("echo.app.language") private var appLanguage = EchoAppLanguage.uzbek.rawValue
    @AppStorage("echo.onboarding.backendCompletionPending") private var backendCompletionPending = false
    @State private var backendCompletionInFlight = false
    @AppStorage("echo.onboarding.completed") private var onboardingCompleted = false
    @State private var showsProfile = false
    @State private var showsSettings = false
    @State private var showsStatistics = false
    @State private var showsKeyboardGuide = false
    @State private var showsKeyboardActivation = false
    @State private var keyboardActivationStartsRecording = true
    @Environment(\.scenePhase) private var scenePhase

    private var ui: EchoAppLanguage { EchoAppLanguage(rawValue: appLanguage) ?? .uzbek }

    private var filteredNotes: [Note] {
        let query = noteSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? notes : notes.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            notesWorkspace
                .tabItem { MobileTabLabel(title: ui.text(uz: "Qaydlar", en: "Notes", ru: "Заметки"), image: MobileTabArtwork.notes) }.tag(0)
            EchoStatisticsView(embedded: true)
                .tabItem { MobileTabLabel(title: ui.text(uz: "Statistika", en: "Stats", ru: "Статистика"), image: MobileTabArtwork.statistics) }.tag(1)
            EchoProfileView(embedded: true, keyboardHost: keyboardHost, onSignOut: signOut)
                .tabItem { MobileTabLabel(title: ui.text(uz: "Profil", en: "Profile", ru: "Профиль"), image: MobileTabArtwork.profile) }.tag(2)
        }
        .tint(EchoMobileTheme.ink)
        .task {
            keyboardHost.activate()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--echo-diagnose-live-activity") {
                EchoLiveActivityController.shared.diagnoseLiveActivity()
            }
            if ProcessInfo.processInfo.arguments.contains("--echo-diagnose-billing") {
                await EchoAuthClient.shared.diagnoseBilling()
            }
            #endif
        }
        .onChange(of: selectedTab) { _, _ in composer.finishDictation() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { composer.finishDictation() }
            if phase == .active { Task { await loadHistory(reset: true) } }
            if phase == .active, let shared = UserDefaults(suiteName: VoiceBridge.appGroup) {
                for key in ["echo.dictation.uzbekScript", "echo.uzbek.alphabet", "echo.keyboard.layout", "echo.keyboard.autocorrect", "echo.keyboard.suggestions"] {
                    if let value = shared.object(forKey: key) { UserDefaults.standard.set(value, forKey: key) }
                }
            }
        }
        // App and keyboard share one microphone: whichever starts last takes it.
        .onOpenURL { url in
            guard url.scheme == VoiceBridge.urlScheme else { return }
            switch url.host {
            case "settings":
                selectedTab = 0
                composer.dismissKeyboard()
                showsSettings = true
            case "subscription":
                selectedTab = 2
                composer.dismissKeyboard()
            case "dictate":
                selectedTab = 0
                composer.dismissKeyboard()
                let requestsReadySession = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(where: { $0.name == "session" && $0.value == "ready" }) == true
                if requestsReadySession {
                    keyboardActivationStartsRecording = !requestsReadySession
                    showsKeyboardActivation = true
                } else {
                    Task {
                        await composer.cancelAndWait()
                        await keyboardHost.start(listening: true)
                    }
                }
            default: break
            }
        }
        .onChange(of: composer.language) { _, language in
            keyboardHost.language = language
            preferredLanguage = language.rawValue
        }
        .onChange(of: preferredLanguage) { _, value in
            let language = DictationLanguage(rawValue: value) ?? .auto
            composer.language = language
            keyboardHost.language = language
        }
        .onAppear {
            let shared = UserDefaults(suiteName: VoiceBridge.appGroup)
            transcriptScript = UzbekTranscriptScript.preferredScript(shared: shared).rawValue
            shared?.set(transcriptScript, forKey: "echo.dictation.uzbekScript")
            composer.beforeRecording = { await keyboardHost.stopAndWait() }
            composer.language = DictationLanguage(rawValue: preferredLanguage) ?? .auto
            keyboardHost.language = composer.language
        }
        .onChange(of: transcriptScript) { _, value in
            guard UzbekTranscriptScript(rawValue: value) != nil else { return }
            UserDefaults(suiteName: VoiceBridge.appGroup)?.set(value, forKey: "echo.dictation.uzbekScript")
        }
        .onChange(of: composer.successfulDictations) { _, count in
            if count > 0 {
                finishBackendOnboardingAfterSpeech()
                Task { await loadHistory(reset: true) }
            }
        }
        .onChange(of: keyboardHost.successfulDictations) { _, count in
            if count > 0 {
                finishBackendOnboardingAfterSpeech()
                Task { await loadHistory(reset: true) }
            }
        }

    }

    private var notesWorkspace: some View {
        NavigationStack {
            List {
                if !initialHistoryLoading {
                    dictationHistory
                    if !notes.isEmpty { recentNotes }
                }
            }
            .overlay {
                if initialHistoryLoading {
                    WorkspaceLoading(title: ui.text(uz: "Qaydlar yuklanmoqda…", en: "Loading your notes…", ru: "Загрузка заметок…"))
                }
            }
            .refreshable { await loadHistory(reset: true) }
            .task { await loadHistory(reset: true) }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(EchoMobileTheme.canvas)
            .searchable(text: $noteSearch, placement: .navigationBarDrawer(displayMode: .always), prompt: ui.text(uz: "Qaydlarni qidirish", en: "Search notes", ru: "Поиск заметок"))
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Echo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image("EchoLogo")
                            .resizable()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        Text("Echo").font(.headline)
                    }
                }

            }
            .safeAreaInset(edge: .bottom) {
                InputBar(model: composer, onSend: save)
                    .background(EchoMobileTheme.canvas.opacity(0.96))
            }
        }
        .sheet(isPresented: $showsProfile) { EchoProfileView(onSignOut: signOut) }
        .sheet(isPresented: $showsSettings) { EchoSettingsView(keyboardHost: keyboardHost) }
        .sheet(isPresented: $showsStatistics) { EchoStatisticsView() }
        .sheet(isPresented: $showsKeyboardGuide) { keyboardGuide }
        .sheet(isPresented: $showsKeyboardActivation) { keyboardActivation }
        .sheet(item: $selectedNote) { note in noteDetail(note) }
    }

    private var keyboardActivation: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image("EchoLogo")
                .resizable().frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 15))
            Text(ui.text(uz: "Mikrofon rejimini tanlang", en: "Choose microphone mode", ru: "Выберите режим микрофона"))
                .font(.title2.weight(.semibold))
            Text(ui.text(uz: "Yozuv tugashi bilan mikrofon o‘chadi. Keyingi yozuvda iOS Echo’ni qayta ochishi mumkin.", en: "The microphone turns off when recording ends. iOS may reopen Echo for the next recording.", ru: "Микрофон выключается после записи. Для следующей записи iOS может снова открыть Echo."))
            Button {
                activateKeyboardSession(keepReady: false)
            } label: {
                Text(ui.text(uz: "Bir marta yozish", en: "Record once", ru: "Записать один раз"))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            MobileLabel(ui.text(uz: "Sessiya davomida mikrofon indikatori yoniq qoladi. Faqat diktovka paytidagi audio saqlanadi va yuboriladi.", en: "The microphone indicator stays on during the session. Only dictated audio is saved and sent.", ru: "Во время сеанса индикатор микрофона остаётся включённым. Сохраняется и отправляется только звук диктовки."), systemImage: "mic.badge.plus")
                .font(.footnote).foregroundStyle(.secondary)
            Button {
                activateKeyboardSession(keepReady: true)
            } label: {
                Text(ui.text(uz: "Mikrofonni tayyor tutish — 5 daqiqa", en: "Keep microphone ready — 5 minutes", ru: "Держать микрофон готовым — 5 минут"))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func activateKeyboardSession(keepReady: Bool) {
        VoiceBridge.Store()?.microphoneMode = keepReady ? .readySession : .recordingOnly
        let listening = keyboardActivationStartsRecording || !keepReady
        showsKeyboardActivation = false
        Task {
            await composer.cancelAndWait()
            await keyboardHost.start(listening: listening, keepMicrophoneReady: keepReady)
        }
    }

    private var keyboardGuide: some View {
        NavigationStack {
            List {
                Section {
                    MobileLabel(ui.text(uz: "Settings → General → Keyboard → Keyboards bo‘limini oching.", en: "Open Settings → General → Keyboard → Keyboards.", ru: "Откройте Настройки → Основные → Клавиатура → Клавиатуры."), systemImage: "1.circle")
                    MobileLabel(ui.text(uz: "Add New Keyboard tugmasini bosing va Echo’ni tanlang.", en: "Tap Add New Keyboard and choose Echo.", ru: "Нажмите «Новые клавиатуры» и выберите Echo."), systemImage: "2.circle")
                    MobileLabel(ui.text(uz: "Echo’ni oching va Allow Full Access’ni yoqing.", en: "Open Echo and enable Allow Full Access.", ru: "Откройте Echo и включите «Полный доступ»."), systemImage: "3.circle")
                    MobileLabel(ui.text(uz: "Istalgan matn maydonida globus tugmasini bosib turib, Echo’ni tanlang.", en: "In any text field, hold the globe key and choose Echo.", ru: "В любом поле ввода удерживайте значок глобуса и выберите Echo."), systemImage: "4.circle")
                } footer: {
                    Text(ui.text(uz: "Mikrofon tugmasi yozuv uchun Echo ilovasini ochadi. Klaviatura o‘zi mikrofonni ishlatmaydi.", en: "The microphone button opens Echo to record. The keyboard itself does not access your microphone.", ru: "Кнопка микрофона открывает Echo для записи. Сама клавиатура не использует микрофон."))
                }
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    Section {
                        Link(destination: settingsURL) {
                            MobileLabel(ui.text(uz: "Echo sozlamalarini ochish", en: "Open Echo settings", ru: "Открыть настройки Echo"), systemImage: "arrow.up.forward.app")
                        }
                    } footer: {
                        Text(ui.text(uz: "Bu tugma Echo sozlamalarini ochadi. Klaviatura qo‘shish uchun yuqoridagi yo‘ldan foydalaning.", en: "This opens Echo’s app settings. To add the keyboard, follow the path above.", ru: "Откроются настройки приложения Echo. Для добавления клавиатуры следуйте пути выше."))
                    }
                }
            }
            .navigationTitle(ui.text(uz: "Klaviaturani sozlash", en: "Keyboard setup", ru: "Настройка клавиатуры"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ui.text(uz: "Tayyor", en: "Done", ru: "Готово")) { showsKeyboardGuide = false }
                }
            }
        }
    }

    private var recentNotes: some View {
        Section {
            if notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    MobileLabel(ui.text(uz: "Birinchi fikringizdan boshlang", en: "Start with your first thought", ru: "Начните с первой мысли"), systemImage: "text.bubble")
                        .font(.subheadline.weight(.semibold))
                    Text(ui.text(uz: "Pastdagi Echo tugmasini bosing yoki yozing.", en: "Tap Echo below or start typing.", ru: "Нажмите Echo внизу или начните печатать."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .listRowBackground(EchoMobileTheme.surface)
            } else if filteredNotes.isEmpty {
                Text(ui.text(uz: "Mos qayd topilmadi.", en: "No matching notes.", ru: "Заметки не найдены."))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .listRowBackground(EchoMobileTheme.surface)
            } else {
                ForEach(filteredNotes) { note in noteRow(note) }
            }
        } header: {
            Text(ui.text(uz: "Saqlangan qaydlar", en: "Saved notes", ru: "Сохранённые заметки"))
                .textCase(nil)
        } footer: {
            Text(ui.text(uz: "Qaydlar faqat shu seansda saqlanadi. Kerakli matnni nusxalang.", en: "Notes stay here for this session only. Copy anything you want to keep.", ru: "Заметки доступны только в этом сеансе. Скопируйте нужный текст."))
        }
    }

    private var initialHistoryLoading: Bool {
        !historyLoaded && historyItems.isEmpty && notes.isEmpty && historyError == nil
    }

    private var historyGroups: [(date: Date, notes: [Note])] {
        Dictionary(grouping: filteredDictations) { Calendar.current.startOfDay(for: $0.createdAt) }
            .map { (date: $0.key, notes: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.date > $1.date }
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return ui.text(uz: "Bugun", en: "Today", ru: "Сегодня") }
        if Calendar.current.isDateInYesterday(date) { return ui.text(uz: "Kecha", en: "Yesterday", ru: "Вчера") }
        return date.formatted(.dateTime.day().month(.wide))
    }

    @ViewBuilder private var dictationHistory: some View {
        ForEach(historyGroups, id: \.date) { group in
            Section {
                ForEach(group.notes) { note in noteRow(note) }
            } header: {
                Text(dayTitle(group.date)).font(.subheadline.weight(.medium)).textCase(nil)
            }
        }
        Section {
            if let historyError {
                VStack(alignment: .leading, spacing: 12) {
                    MobileLabel(ui.text(uz: "Tarix yuklanmadi", en: "Couldn’t load history", ru: "История не загружена"), systemImage: "wifi.exclamationmark")
                        .font(.subheadline.weight(.semibold))
                    Text(historyError).font(.footnote).foregroundStyle(.secondary)
                    Button(ui.text(uz: "Qayta urinish", en: "Retry", ru: "Повторить")) {
                        Task { await loadHistory(reset: true) }
                    }
                    .buttonStyle(.bordered).disabled(historyLoading)
                }
                .padding(.vertical, 12)
                .listRowBackground(EchoMobileTheme.surface)
            } else if historyLoaded && filteredDictations.isEmpty && !historyLoading {
                VStack(spacing: 14) {
                    MobileIcon(systemName: noteSearch.isEmpty ? "waveform" : "magnifyingglass")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(EchoMobileTheme.accent)
                        .frame(width: 64, height: 64)
                        .background(EchoMobileTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                    Text(noteSearch.isEmpty
                         ? ui.text(uz: "Birinchi fikringizdan boshlang", en: "Start with your first thought", ru: "Начните с первой мысли")
                         : ui.text(uz: "Qayd topilmadi", en: "No matching notes", ru: "Заметки не найдены"))
                        .font(.headline)
                    Text(noteSearch.isEmpty
                         ? ui.text(uz: "Pastdagi Echo tugmasini bosing va gapiring. Diktovkalaringiz shu yerda saqlanadi.", en: "Tap Echo below and start speaking. Your dictations will appear here.", ru: "Нажмите Echo внизу и начните говорить. Ваши диктовки появятся здесь.")
                         : ui.text(uz: "Yuklangan qaydlardan boshqa so‘z bilan izlab ko‘ring.", en: "Try another word in your loaded notes.", ru: "Попробуйте другое слово в загруженных заметках."))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.vertical, 30)
                .listRowBackground(EchoMobileTheme.surface)
            }
            if historyLoading && historyLoaded {
                HStack { Spacer(); ProgressView().tint(EchoMobileTheme.ink); Spacer() }
                    .padding(.vertical, 10).listRowBackground(Color.clear)
            }
            if historyCursor != nil && !historyLoading {
                Button { Task { await loadHistory(reset: false) } } label: {
                    Text(ui.text(uz: "Yana yuklash", en: "Load more", ru: "Загрузить ещё"))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .listRowBackground(EchoMobileTheme.surface)
            }
        }
    }

    private var filteredDictations: [Note] {
        let script = UzbekTranscriptScript(rawValue: transcriptScript) ?? .current
        let query = noteSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return historyItems.compactMap { item in
            let text = UzbekTranscriptScript.render(item.transcript, detectedLanguage: item.language, script: script)
            guard query.isEmpty || text.localizedCaseInsensitiveContains(query) else { return nil }
            return Note(id: item.id, text: text, createdAt: item.createdAt, isDictation: true)
        }
    }

    private func noteRow(_ note: Note) -> some View {
        Button { selectedNote = note } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(note.createdAt, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.caption)
                Text(note.text)
                    .font(.subheadline).foregroundStyle(EchoMobileTheme.ink).lineSpacing(4).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(EchoMobileTheme.surface)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { noteActions(note) }
        .contextMenu { noteActions(note) }
        .accessibilityHint(ui.text(uz: "To‘liq o‘qish uchun bosing. Amallar uchun chapga suring.", en: "Tap to read. Swipe left for actions.", ru: "Нажмите, чтобы прочитать. Смахните влево для действий."))
    }

    @MainActor private func loadHistory(reset: Bool) async {
        guard !historyLoading else {
            if reset { historyRefreshPending = true }
            return
        }
        if !reset && historyCursor == nil { return }
        historyLoading = true
        defer {
            historyLoading = false
            if historyRefreshPending {
                historyRefreshPending = false
                Task { await loadHistory(reset: true) }
            }
        }
        do {
            let result = try await EchoAuthClient.shared.getDictationHistory(cursor: reset ? nil : historyCursor)
            if reset { historyItems = result.items }
            else {
                let existing = Set(historyItems.map(\.id))
                historyItems.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            }
            historyCursor = result.nextCursor
            historyLoaded = true
            historyError = nil
        } catch {
            historyError = ui.text(uz: "Diktovka tarixini yuklab bo‘lmadi. Qayta urinib ko‘ring.", en: "Couldn’t load dictation history. Please try again.", ru: "Не удалось загрузить историю диктовок. Попробуйте ещё раз.")
        }
    }

    @ViewBuilder private func noteActions(_ note: Note) -> some View {
        if !note.isDictation {
        Button(role: .destructive) {
            notes.removeAll { $0.id == note.id }
            if selectedNote?.id == note.id { selectedNote = nil }
        } label: {
            MobileLabel(ui.text(uz: "O‘chirish", en: "Delete", ru: "Удалить"), systemImage: "trash")
        }
        }
        Button { UIPasteboard.general.string = note.text } label: {
            MobileLabel(ui.text(uz: "Nusxa", en: "Copy", ru: "Копировать"), systemImage: "doc.on.doc")
        }
        .tint(EchoMobileTheme.ink)
    }

    private func noteDetail(_ note: Note) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(note.createdAt, format: .dateTime.day().month().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                    Text(note.text).font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
            .background(EchoMobileTheme.canvas)
            .navigationTitle(ui.text(uz: "Qayd", en: "Note", ru: "Заметка"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu { noteActions(note) } label: {
                        MobileIcon(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(ui.text(uz: "Qayd amallari", en: "Note actions", ru: "Действия с заметкой"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ui.text(uz: "Tayyor", en: "Done", ru: "Готово")) { selectedNote = nil }
                }
            }
        }
    }

    private func save(_ text: String) {
        noteSearch = ""
        notes.insert(Note(text: text, createdAt: .now), at: 0)
    }

    @MainActor private func signOut() async throws {
        composer.cancelDictation()
        keyboardHost.stop()
        try await EchoAuthClient.shared.signOut()
        showsProfile = false
        backendCompletionPending = false
        UserDefaults.standard.set("welcome", forKey: "echo.onboarding.step")
        onboardingCompleted = false
    }

    private func finishBackendOnboardingAfterSpeech() {
        guard backendCompletionPending, !backendCompletionInFlight else { return }
        backendCompletionInFlight = true
        Task {
            defer { backendCompletionInFlight = false }
            do {
                try await EchoAuthClient.shared.completeOnboarding()
                backendCompletionPending = false
            } catch {
                // Keep the pending flag so a later successful dictation retries.
            }
        }
    }
}

private struct LanguageMenu: View {
    @Binding var selection: DictationLanguage
    let ui: EchoAppLanguage

    var body: some View {
        Menu {
            ForEach([DictationLanguage.auto, .uzbek, .english, .russian]) { language in
                Button {
                    selection = language
                } label: {
                    if selection == language {
                        Label(title(for: language), systemImage: "checkmark")
                    } else {
                        Text(title(for: language))
                    }
                }
            }
        } label: {
            Label(title(for: selection), systemImage: "globe")
                .frame(minHeight: 44)
        }
    }

    private func title(for language: DictationLanguage) -> String {
        switch language {
        case .auto: ui.text(uz: "Avtomatik", en: "Auto-detect", ru: "Автоопределение")
        case .uzbek: "Oʻzbekcha"
        case .english: "English"
        case .russian: "Русский"
        case .arabic: "العربية"
        case .turkish: "Türkçe"
        }
    }
}

enum EchoAppLanguage: String, CaseIterable, Identifiable {
    case uzbek = "uz", english = "en", russian = "ru"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .uzbek: "Oʻzbekcha"
        case .english: "English"
        case .russian: "Русский"
        }
    }

    func text(uz: String, en: String, ru: String) -> String {
        switch self {
        case .uzbek: uz
        case .english: en
        case .russian: ru
        }
    }
}

struct EchoSettingsView: View {
    var embedded = false
    var keyboardHost: KeyboardSessionHost? = nil
    @AppStorage("echo.app.language") private var appLanguage = EchoAppLanguage.uzbek.rawValue
    @AppStorage("echo.dictation.uzbekScript") private var transcriptScript = "current"
    @AppStorage("echo.dictation.language") private var dictationLanguage = DictationLanguage.auto.rawValue
    @AppStorage("echo.uzbek.alphabet") private var alphabet = "modern"
    @AppStorage("echo.keyboard.layout") private var keyboardLayout = "uzbek"
    @AppStorage("echo.keyboard.autocorrect") private var autocorrect = true
    @AppStorage("echo.keyboard.suggestions") private var suggestions = true
    @State private var microphoneMode = VoiceBridge.MicrophoneMode.readySession
    @Environment(\.dismiss) private var dismiss

    private var ui: EchoAppLanguage { EchoAppLanguage(rawValue: appLanguage) ?? .uzbek }

    var body: some View {
        NavigationStack {
            Form {
                appLanguageSection
                speechSection
                keyboardSection
                keyboardSessionSection
            }
            .formStyle(.grouped)
            .listSectionSpacing(16)
            .scrollContentBackground(.hidden)
            .background(EchoMobileTheme.canvas)
            .tint(EchoMobileTheme.ink)
            .navigationTitle(ui.text(uz: "Sozlamalar", en: "Settings", ru: "Настройки"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !embedded { Button(ui.text(uz: "Tayyor", en: "Done", ru: "Готово")) { dismiss() } }
                }
            }
        }
        .onAppear {
            microphoneMode = VoiceBridge.Store()?.microphoneMode ?? .readySession
            guard let shared = UserDefaults(suiteName: VoiceBridge.appGroup) else { return }
            transcriptScript = UzbekTranscriptScript.preferredScript(shared: shared).rawValue
            if let value = shared.string(forKey: "echo.uzbek.alphabet") { alphabet = value }
            if transcriptScript != "cyrillic" { alphabet = transcriptScript }
            if let value = shared.string(forKey: "echo.keyboard.layout") { keyboardLayout = value }
            if let value = shared.object(forKey: "echo.keyboard.autocorrect") as? Bool { autocorrect = value }
            if let value = shared.object(forKey: "echo.keyboard.suggestions") as? Bool { suggestions = value }
        }
        .onChange(of: alphabet) { _, value in
            let shared = UserDefaults(suiteName: VoiceBridge.appGroup)
            shared?.set(value, forKey: "echo.uzbek.alphabet")
            if transcriptScript != "cyrillic" {
                transcriptScript = value
                shared?.set(value, forKey: "echo.dictation.uzbekScript")
            }
        }
        .onChange(of: transcriptScript) { _, value in
            let shared = UserDefaults(suiteName: VoiceBridge.appGroup)
            shared?.set(value, forKey: "echo.dictation.uzbekScript")
            if value == "current" || value == "modern" { alphabet = value }
        }
        .onChange(of: keyboardLayout) { _, value in
            UserDefaults(suiteName: VoiceBridge.appGroup)?.set(value, forKey: "echo.keyboard.layout")
        }
        .onChange(of: autocorrect) { _, value in
            UserDefaults(suiteName: VoiceBridge.appGroup)?.set(value, forKey: "echo.keyboard.autocorrect")
        }
        .onChange(of: suggestions) { _, value in
            UserDefaults(suiteName: VoiceBridge.appGroup)?.set(value, forKey: "echo.keyboard.suggestions")
        }
        .onChange(of: microphoneMode) { _, value in
            VoiceBridge.Store()?.microphoneMode = value
            if value == .recordingOnly, keyboardHost?.phase == .ready { keyboardHost?.stop() }
        }
    }

    private var appLanguageSection: some View {
        Section {
            Picker(ui.text(uz: "Ilova tili", en: "App language", ru: "Язык приложения"), selection: $appLanguage) {
                ForEach(EchoAppLanguage.allCases) { language in
                    Text(language.name).tag(language.rawValue)
                }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text(ui.text(uz: "Umumiy", en: "General", ru: "Основные"))
        }
        .listRowBackground(EchoMobileTheme.surface)
    }

    private var speechSection: some View {
        Section {
            Picker(ui.text(uz: "Nutq tili", en: "Spoken language", ru: "Язык речи"), selection: $dictationLanguage) {
                Text(ui.text(uz: "Avtomatik", en: "Automatic", ru: "Автоматически")).tag(DictationLanguage.auto.rawValue)
                Text("Oʻzbekcha").tag(DictationLanguage.uzbek.rawValue)
                Text("English").tag(DictationLanguage.english.rawValue)
                Text("Русский").tag(DictationLanguage.russian.rawValue)
                Text("العربية").tag(DictationLanguage.arabic.rawValue)
                Text("Türkçe").tag(DictationLanguage.turkish.rawValue)
            }
            .pickerStyle(.navigationLink)
            Picker(ui.text(uz: "Matn yozuvi", en: "Output script", ru: "Письменность"), selection: $transcriptScript) {
                Text(ui.text(uz: "Lotin · O‘, G‘", en: "Latin · O‘, G‘", ru: "Латиница · O‘, G‘")).tag("current")
                Text(ui.text(uz: "Yangi lotin · Ö, Ğ", en: "New Latin · Ö, Ğ", ru: "Новая латиница · Ö, Ğ")).tag("modern")
                Text("Кирилл · Ў, Ғ").tag("cyrillic")
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text(ui.text(uz: "Diktovka", en: "Dictation", ru: "Диктовка"))
        } footer: {
            Text(ui.text(uz: "O‘zbekcha matn namunasi: ", en: "Uzbek text preview: ", ru: "Пример узбекского текста: ")
                 + (transcriptScript == "cyrillic" ? "Ўзбекистон, шаҳар" : transcriptScript == "modern" ? "Özbekiston, şahar" : "O‘zbekiston, shahar"))
        }
        .listRowBackground(EchoMobileTheme.surface)
    }

    private var keyboardSection: some View {
        Section {
            Picker(ui.text(uz: "Klaviatura tili", en: "Keyboard language", ru: "Язык клавиатуры"), selection: $keyboardLayout) {
                Text("Oʻzbekcha").tag("uzbek")
                Text("English").tag("english")
                Text("Русский").tag("russian")
            }
            .pickerStyle(.navigationLink)
            if keyboardLayout == "uzbek" {
                Picker(ui.text(uz: "Alifbo", en: "Alphabet", ru: "Алфавит"), selection: $alphabet) {
                    Text(ui.text(uz: "Amaldagi · O‘, G‘", en: "Current · O‘, G‘", ru: "Текущий · O‘, G‘")).tag("current")
                    Text(ui.text(uz: "Yangi · Ö, Ğ", en: "New · Ö, Ğ", ru: "Новый · Ö, Ğ")).tag("modern")
                }
                .pickerStyle(.navigationLink)
            }
            Toggle(ui.text(uz: "Avtomatik tuzatish", en: "Auto-correction", ru: "Автоисправление"), isOn: $autocorrect)
                .tint(Color(uiColor: .systemGreen))
            Toggle(ui.text(uz: "So‘z tavsiyalari", en: "Word suggestions", ru: "Подсказки слов"), isOn: $suggestions)
                .tint(Color(uiColor: .systemGreen))
        } header: {
            Text(ui.text(uz: "Klaviatura", en: "Keyboard", ru: "Клавиатура"))
        } footer: {
            Text(ui.text(uz: "O‘zgarishlar klaviaturani qayta ochganda qo‘llanadi.", en: "Reopen the keyboard to apply changes.", ru: "Откройте клавиатуру заново, чтобы применить изменения."))
        }
        .listRowBackground(EchoMobileTheme.surface)
    }

    private var keyboardSessionSection: some View {
        Section {
            NavigationLink { microphoneOptions } label: {
                HStack {
                    Text(ui.text(uz: "Mikrofon rejimi", en: "Microphone mode", ru: "Режим микрофона"))
                    Spacer(minLength: 8)
                    Text(modeTitle(microphoneMode)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let keyboardHost {
                HStack {
                    Text(ui.text(uz: "Hozirgi holat", en: "Current status", ru: "Сейчас"))
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(keyboardHost.isOn ? Color.orange : Color.secondary).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(microphoneStatus).foregroundStyle(.secondary)
                    }
                }
                if keyboardHost.isOn {
                    Button(ui.text(uz: "Mikrofonni o‘chirish", en: "Turn off microphone", ru: "Выключить микрофон"), role: .destructive) { keyboardHost.stop() }
                } else if microphoneMode == .readySession {
                    Button(ui.text(uz: "Mikrofonni tayyor tutish", en: "Keep microphone ready", ru: "Держать микрофон готовым")) {
                        VoiceBridge.Store()?.microphoneMode = .readySession
                        Task { await keyboardHost.start(listening: false, keepMicrophoneReady: true) }
                    }
                }
                if keyboardHost.failure != nil {
                    Text(ui.text(uz: "Mikrofon sessiyasida xatolik yuz berdi. Ruxsatlar va internetni tekshirib, qayta urinib ko‘ring.", en: "The microphone session failed. Check permissions and your connection, then try again.", ru: "Ошибка сеанса микрофона. Проверьте разрешения и подключение, затем повторите."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(ui.text(uz: "Ovozli klaviatura", en: "Voice keyboard", ru: "Голосовая клавиатура"))
        } footer: {
            Text(microphoneMode == .recordingOnly
                 ? ui.text(uz: "Mikrofon har diktovkadan keyin o‘chadi.", en: "The microphone turns off after each dictation.", ru: "Микрофон выключается после каждой диктовки.")
                 : ui.text(uz: "Tayyor sessiyada mikrofon faol qoladi. Echo fonda va klaviatura yopiq bo‘lsa, 5 daqiqa ishlatilmagach o‘chadi.", en: "A ready session keeps the microphone active. It ends after 5 idle minutes while Echo is in the background and the keyboard is closed.", ru: "В готовом сеансе микрофон активен. Сеанс завершится через 5 минут бездействия, когда Echo в фоне, а клавиатура закрыта."))
        }
        .listRowBackground(EchoMobileTheme.surface)
    }

    private func modeTitle(_ mode: VoiceBridge.MicrophoneMode) -> String {
        mode == .readySession
            ? ui.text(uz: "Tayyor holat", en: "Keep ready", ru: "В готовности")
            : ui.text(uz: "Har yozuvda", en: "Per recording", ru: "На запись")
    }

    private var microphoneStatus: String {
        switch keyboardHost?.phase ?? .off {
        case .off: ui.text(uz: "O‘chiq", en: "Off", ru: "Выключен")
        case .ready: ui.text(uz: "Tayyor", en: "Ready", ru: "Готов")
        case .starting: ui.text(uz: "Yoqilmoqda…", en: "Starting…", ru: "Включается…")
        case .recording: ui.text(uz: "Yozilmoqda", en: "Recording", ru: "Запись")
        case .transcribing: ui.text(uz: "Matnga aylantirilmoqda", en: "Transcribing", ru: "Распознавание")
        }
    }

    private var microphoneOptions: some View {
        List {
            Section {
                modeOption(.recordingOnly, description: ui.text(uz: "Faqat diktovka paytida ishlaydi. Keyingi yozuvda Echo qayta ochilishi mumkin.", en: "Active only while dictating. Echo may reopen for your next recording.", ru: "Работает только при диктовке. Для следующей записи Echo может открыться снова."))
                modeOption(.readySession, description: ui.text(uz: "Ketma-ket diktovkalar uchun mikrofon tayyor turadi. Sessiya yoqilganda mikrofon indikatori yonadi.", en: "Keeps the microphone ready between dictations. The microphone indicator stays on during the session.", ru: "Микрофон готов между диктовками. Во время сеанса горит индикатор микрофона."))
            } footer: {
                Text(ui.text(uz: "Faqat diktovka ovozi saqlanadi va yuboriladi. Yozuv paytida rejimni almashtirsangiz, keyingi sessiyaga qo‘llanadi.", en: "Only dictated audio is saved and sent. Changes made while recording apply to the next session.", ru: "Сохраняется и отправляется только звук диктовки. Изменение режима во время записи применяется к следующему сеансу."))
            }
            .listRowBackground(EchoMobileTheme.surface)
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden)
        .background(EchoMobileTheme.canvas)
        .navigationTitle(ui.text(uz: "Mikrofon rejimi", en: "Microphone mode", ru: "Режим микрофона"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modeOption(_ mode: VoiceBridge.MicrophoneMode, description: String) -> some View {
        Button { microphoneMode = mode } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(modeTitle(mode)).font(.body).foregroundStyle(EchoMobileTheme.ink)
                    Text(description).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark").font(.body.weight(.semibold))
                    .foregroundStyle(EchoMobileTheme.ink)
                    .opacity(microphoneMode == mode ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(microphoneMode == mode ? .isSelected : [])
    }
}

struct EchoStatisticsView: View {
    var embedded = false
    @AppStorage("echo.app.language") private var appLanguage = EchoAppLanguage.uzbek.rawValue
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var chartProgress = 0.0
    @ScaledMetric(relativeTo: .title2) private var gaugeHeight = 48.0
    @State private var statistics: EchoStatistics?
    @State private var error: String?
    @State private var isLoading = false

    private var chartReveal: Double { reduceMotion ? 1 : chartProgress }
    private var ui: EchoAppLanguage { EchoAppLanguage(rawValue: appLanguage) ?? .uzbek }
    private var rows: [EchoStatistics.Day] { statistics?.days ?? [] }
    private var words: Int64 { statistics?.trustedSummary?.words ?? rows.reduce(Int64(0)) { $0 + Int64($1.words) } }
    private var recordings: Int64 { statistics?.trustedSummary?.recordings ?? rows.reduce(Int64(0)) { $0 + Int64($1.recordings) } }
    private var durationMs: Int64 { statistics?.trustedSummary?.durationMs ?? rows.reduce(Int64(0)) { $0 + Int64($1.durationMs) } }
    private var wordsPerMinute: Int? {
        guard durationMs > 0 else { return nil }
        let rate = (Double(words) * 60_000 / Double(durationMs)).rounded()
        guard rate.isFinite, rate >= 0, rate < Double(Int.max) else { return nil }
        return Int(rate)
    }
    private var desktopRecordings: Int {
        (statistics?.platformDays ?? []).filter { $0.platform == "desktop" }.reduce(0) { $0 + $1.recordings }
    }
    private var iPhoneRecordings: Int {
        (statistics?.platformDays ?? []).filter { $0.platform == "ios" }.reduce(0) { $0 + $1.recordings }
    }
    private var calendarDays: [(date: Date, count: Int, words: Int)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: statistics?.timeZone ?? "") ?? .current
        let today = calendar.startOfDay(for: .now)
        let counts = Dictionary(rows.map { ($0.day, $0.recordings) }, uniquingKeysWith: +)
        let wordCounts = Dictionary(rows.map { ($0.day, $0.words) }, uniquingKeysWith: +)
        return (0..<182).map { offset in
            let date = calendar.date(byAdding: .day, value: offset - 181, to: today) ?? today
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            return (date, counts[key] ?? 0, wordCounts[key] ?? 0)
        }
    }
    private var activeDays: Int { calendarDays.filter { $0.count > 0 }.count }
    private var longestStreak: Int {
        var run = 0
        var longest = 0
        for day in calendarDays {
            run = day.count > 0 ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }
    private var currentStreak: Int {
        let days = calendarDays
        let relevant = days.last?.count == 0 ? days.dropLast() : days.dropLast(0)
        var streak = 0
        for day in relevant.reversed() {
            if day.count == 0 { break }
            streak += 1
        }
        return streak
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if statistics != nil {
                        let headingLayout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                            : AnyLayout(HStackLayout())
                        headingLayout {
                            Text(ui.text(uz: "Foydalanish", en: "Overview", ru: "Обзор"))
                                .font(.subheadline.weight(.semibold))
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            Text(ui.text(uz: "Oxirgi 6 oy", en: "Last 6 months", ru: "Последние 6 месяцев"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 8)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(EchoMobileTheme.border).frame(height: 1)
                        }
                        if let error { errorNotice(error) }
                        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
                        LazyVGrid(columns: columns, spacing: 12) {
                            speedCard
                            recordingsCard
                        }
                        wordsCard
                        if let saved = statistics?.estimatedSavedTime {
                            savedTimeCard(saved)
                        }
                        activityCard
                        if statistics?.platformDays != nil { sourceCard }
                    } else if let error {
                        errorNotice(error)
                    }
                }
                .padding(16)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background(EchoMobileTheme.canvas)
            .overlay {
                if statistics == nil && error == nil {
                    WorkspaceLoading(title: ui.text(uz: "Statistika yuklanmoqda…", en: "Loading your activity…", ru: "Загрузка статистики…"))
                }
            }
            .refreshable { await refresh() }
            .navigationTitle(ui.text(uz: "Statistika", en: "Statistics", ru: "Статистика"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !embedded { Button(ui.text(uz: "Tayyor", en: "Done", ru: "Готово")) { dismiss() } }
                }
            }
        }
        .tint(EchoMobileTheme.accent)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; chartProgress = 0 }
        .task(id: isVisible && statistics != nil) {
            guard isVisible, statistics != nil else { return }
            if reduceMotion { chartProgress = 1; return }
            // Begin after the initial layout: only the data marks move, never the cards.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.65)) { chartProgress = 1 }
        }
        .task { await refresh() }
    }

    private func errorNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MobileLabel(ui.text(uz: "Yangilab bo‘lmadi", en: "Couldn’t refresh", ru: "Не удалось обновить"), systemImage: "arrow.clockwise.circle")
                .font(.subheadline.weight(.semibold))
            Text(message).font(.footnote).foregroundStyle(.secondary)
            Button(ui.text(uz: "Qayta urinish", en: "Retry", ru: "Повторить")) {
                Task { await refresh() }
            }
            .buttonStyle(.bordered).disabled(isLoading)
        }
        .modifier(MobileSurface())
    }

    private func caption(_ title: String) -> some View {
        Text(title).font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption(ui.text(uz: "So‘z / daqiqa", en: "Words / minute", ru: "Слов / минуту"))
            ZStack(alignment: .bottom) {
                MobileSpeedArc()
                    .stroke(EchoMobileTheme.selection, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                MobileSpeedArc().trim(from: 0, to: chartReveal * min(1, max(0, Double(wordsPerMinute ?? 0) / 200)))
                    .stroke(EchoMobileTheme.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                Text(wordsPerMinute.map { String(chartReveal > 0 ? $0 : 0) } ?? "—")
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .font(.system(.title2, design: .default, weight: .semibold)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
            }
            .frame(height: gaugeHeight).padding(.horizontal, 5)
            HStack { Text("0"); Spacer(); Text("200+") }
                .font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 106, alignment: .topLeading)
        .modifier(MobileSurface())
        .accessibilityElement(children: .combine)
    }

    private var recordingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption(ui.text(uz: "Yozuvlar", en: "Recordings", ru: "Записи"))
            Text((chartReveal > 0 ? recordings : 0).formatted())
                .contentTransition(reduceMotion ? .identity : .numericText())
                .font(.system(.title2, design: .default, weight: .semibold)).monospacedDigit()
                .foregroundStyle(EchoMobileTheme.ink).lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Divider()
            MobileLabel(ui.text(uz: "\(activeDays) faol kun", en: "\(activeDays) active days", ru: "Активных дней: \(activeDays)"), systemImage: "calendar")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 106, alignment: .topLeading)
        .modifier(MobileSurface())
        .accessibilityElement(children: .combine)
    }

    private var wordsCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                wordsTotal.frame(minWidth: 100, alignment: .leading)
                weekBars.frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 12) { wordsTotal; weekBars }
        }
        .modifier(MobileSurface())
    }

    private var wordsTotal: some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(ui.text(uz: "Yozilgan so‘zlar", en: "Words written", ru: "Записано слов"))
            Text((chartReveal > 0 ? words : 0).formatted())
                .font(.title2.weight(.semibold)).monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
    }

    private var weekBars: some View {
        let days = Array(calendarDays.suffix(7))
        let peak = max(1, days.map(\.words).max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 7) {
                ForEach(days, id: \.date) { day in
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(day.words == 0 ? EchoMobileTheme.selection : EchoMobileTheme.accent.opacity(Calendar.current.isDateInToday(day.date) ? 1 : 0.55))
                            .frame(height: max(3, 46 * Double(day.words) / Double(peak) * chartReveal))
                            .frame(height: 46, alignment: .bottom)
                        Text(day.date, format: .dateTime.weekday(.narrow))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue(ui.text(uz: "\(day.words) so‘z", en: "\(day.words) words", ru: "Слов: \(day.words)"))
                }
            }
            caption(ui.text(uz: "Oxirgi 7 kun", en: "Last 7 days", ru: "Последние 7 дней"))
        }
        .frame(minWidth: 140)
    }

    private func savedTimeCard(_ value: EchoStatistics.SavedTime) -> some View {
        DisclosureGroup {
            Text(ui.text(uz: "40 so‘z/daqiqa tezlikda qo‘lda yozishga nisbatan, diktovka vaqti ayirilgan. Oxirgi 6 oy uchun taxmin.", en: "Compared with typing at 40 words/minute, minus dictation time. Estimated over the last 6 months.", ru: "По сравнению с набором 40 слов/мин, за вычетом времени диктовки. Оценка за последние 6 месяцев."))
                .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                MobileLabel(ui.text(uz: "Taxminiy tejalgan vaqt", en: "Estimated time saved", ru: "Примерно сэкономлено"), systemImage: "clock.badge.checkmark")
                    .font(.caption).foregroundStyle(.secondary)
                Text(savedTimeText(value)).font(.title3.weight(.semibold))
                    .foregroundStyle(EchoMobileTheme.ink).monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
        }
        .modifier(MobileSurface())
    }

    private func savedTimeText(_ value: EchoStatistics.SavedTime) -> String {
        if value.isLessThanOneMinute {
            return ui.text(uz: "1 daqiqadan kam", en: "Less than 1 minute", ru: "Меньше 1 минуты")
        }
        if value.hours > 0 {
            if value.minutes == 0 {
                return ui.text(uz: "\(value.hours) soat", en: "\(value.hours) hr", ru: "\(value.hours) ч")
            }
            return ui.text(uz: "\(value.hours) soat \(value.minutes) daqiqa", en: "\(value.hours) hr \(value.minutes) min", ru: "\(value.hours) ч \(value.minutes) мин")
        }
        return ui.text(uz: "\(value.minutes) daqiqa", en: "\(value.minutes) min", ru: "\(value.minutes) мин")
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ui.text(uz: "Qurilmalar", en: "Devices", ru: "Устройства"))
                .font(.subheadline.weight(.semibold))
            deviceRow("Mac", icon: "desktopcomputer", count: desktopRecordings)
            deviceRow("iPhone", icon: "iphone", count: iPhoneRecordings)
        }
        .modifier(MobileSurface())
    }

    private func deviceRow(_ title: String, icon: String, count: Int) -> some View {
        VStack(spacing: 10) {
            HStack {
                MobileLabel(title, systemImage: icon).font(.subheadline)
                Spacer()
                Text(ui.text(uz: "\(count.formatted()) yozuv", en: "\(count.formatted()) recordings", ru: "Записей: \(count.formatted())"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: Double(count) * chartReveal, total: Double(max(1, desktopRecordings + iPhoneRecordings)))
                .tint(EchoMobileTheme.accent)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ui.text(uz: "Faollik", en: "Activity", ru: "Активность"))
                .font(.subheadline.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) { streakSummary; Spacer(); bestStreak }
                VStack(alignment: .leading, spacing: 12) { streakSummary; bestStreak }
            }
            activityGrid
            HStack(spacing: 4) {
                Text(ui.text(uz: "Kam", en: "Less", ru: "Меньше")).padding(.trailing, 4)
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(level == 0 ? EchoMobileTheme.selection : EchoMobileTheme.accent.opacity(Double(level) / 4))
                        .frame(width: 10, height: 10)
                }
                Text(ui.text(uz: "Ko‘p", en: "More", ru: "Больше")).padding(.leading, 4)
            }
            .font(.caption2).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityHidden(true)
        }
        .modifier(MobileSurface())
    }

    private var streakSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ui.text(uz: "\(currentStreak) kun", en: "\(currentStreak) days", ru: "\(currentStreak) дн."))
                .font(.subheadline.weight(.semibold)).monospacedDigit()
            caption(ui.text(uz: "Hozirgi ketma-ketlik", en: "Current streak", ru: "Текущая серия"))
        }
        .accessibilityElement(children: .combine)
    }

    private var bestStreak: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ui.text(uz: "\(longestStreak) kun", en: "\(longestStreak) days", ru: "\(longestStreak) дн."))
                .font(.subheadline.weight(.semibold)).monospacedDigit()
            caption(ui.text(uz: "Eng uzun ketma-ketlik", en: "Longest streak", ru: "Лучшая серия"))
        }
        .accessibilityElement(children: .combine)
    }

    private var activityGrid: some View {
        let days = calendarDays
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: statistics?.timeZone ?? "") ?? .current
        // Monday is the first row. Pad the first/last weeks instead of shifting weekdays.
        let leading = (calendar.component(.weekday, from: days[0].date) + 5) % 7
        let weeks = (days.count + leading + 6) / 7
        return VStack(spacing: 8) {
            HStack {
                Text(days[0].date, format: .dateTime.month(.abbreviated))
                Spacer()
                Text(days[days.count / 2].date, format: .dateTime.month(.abbreviated))
                Spacer()
                Text(days[days.count - 1].date, format: .dateTime.month(.abbreviated))
            }
            .font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<weeks, id: \.self) { week in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { weekday in
                            let index = week * 7 + weekday - leading
                            if days.indices.contains(index) {
                                let day = days[index]
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(day.count == 0 ? EchoMobileTheme.selection : EchoMobileTheme.accent.opacity(min(1, 0.25 + Double(day.count) * 0.18)))
                                    .aspectRatio(1, contentMode: .fit)
                                    .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                                    .accessibilityValue(ui.text(uz: "\(day.count) yozuv", en: "\(day.count) recordings", ru: "Записей: \(day.count)"))
                            } else {
                                Color.clear.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            statistics = try await EchoAuthClient.shared.getStatistics()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MobileSpeedArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width / 2, rect.height)
        path.addArc(center: CGPoint(x: rect.midX, y: rect.maxY), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        return path
    }
}
