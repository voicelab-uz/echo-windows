import SwiftUI
import VoiceLabCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, dictation, shortcuts, permissions, notifications, changelog
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "Umumiy"
        case .dictation: "Yozish"
        case .shortcuts: "Tezkor tugmalar"
        case .permissions: "Ruxsatlar"
        case .notifications: "Bildirishnomalar"
        case .changelog: "O‘zgarishlar"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "waveform"
        case .shortcuts: "command"
        case .permissions: "lock.shield"
        case .notifications: "bell"
        case .changelog: "sparkles"
        }
    }
    /// VoiceLab's own artwork for the settings sidebar, matching the main sidebar.
    var workspaceIcon: WorkspaceAssetIcon.Name {
        switch self {
        case .general: .settings
        case .dictation: .speechToText
        case .shortcuts: .keyboard
        case .permissions: .shield
        case .notifications: .notifications
        case .changelog: .star
        }
    }
    var subtitle: String {
        switch self {
        case .general: "Echo ko‘rinishi va Mac’da ishlashini sozlang."
        case .dictation: "Ovozingizdan tayyor matngacha."
        case .shortcuts: "Echo doim bir tugma masofasida."
        case .permissions: "Mikrofon va matn joylash uchun ruxsatlarni boshqaring."
        case .notifications: "Echo yangiliklari va bildirishnomalarini boshqaring."
        case .changelog: "Har bir versiyada nimalar yangilangani."
        }
    }
    /// Pages listed in the sidebar's settings section, in display order.
    static let navigation: [SettingsPage] = [.general, .dictation, .shortcuts, .permissions, .notifications, .changelog]
}

/// One settings page, shown in the main window's detail column. The workspace sidebar
/// owns navigation between pages; this view owns the page's controls and dialogs.
struct SettingsDetailView: View {
    let model: AppModel
    let page: SettingsPage
    @State private var accessibility = TextInsertion.hasAccessibility
    @State private var error: String?
    @State private var shortcutError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                pageContent
                if let error { ErrorBanner(message: error) { self.error = nil } }
            }
            .buttonStyle(.echo)
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 8).padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        // Fresh scroll position per page, without any page transition animation.
        .id(page)
        .tint(Design.tint)
        .onAppear { model.loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibility = TextInsertion.hasAccessibility
            model.loginItem.refresh()
        }
        .onDisappear { model.endShortcutRecording() }
    }

    // MARK: Pages

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .general: generalSettings
        case .dictation: dictationSettings
        case .shortcuts: shortcutSettings
        case .permissions: permissionSettings
        case .notifications: notificationSettings
        case .changelog: changelog
        }
    }

    private var generalSettings: some View {
        @Bindable var preferences = model.preferences
        return Group {
            SettingsSection("Ko‘rinish", subtitle: "Echo’ni tizim mavzusiga moslang yoki doimiy ko‘rinishni tanlang.") {
                SettingsGroup {
                    SettingsAppearancePicker(selection: $preferences.appearance).padding(.vertical, 16)
                    Divider()
                    SettingsRow("Urg‘u rangi", detail: "VoiceLab rangini, tizim rangini yoki boshqa rangni tanlang.") {
                        AccentColorPicker(accent: AppAccent.shared)
                    }
                }
            }
            SettingsSection("Ilova", subtitle: "Echo Mac’da qanday ishlashini tanlang.") {
                SettingsGroup {
                    SettingsRow("Ilova tili") {
                        SettingsMenu(title: "Ilova tili", selection: $preferences.interfaceLanguage,
                                     options: InterfaceLanguage.allCases) { $0.title }
                    }
                    Divider()
                    SettingsRow("Dock belgisini doim ko‘rsatish", detail: "Oynalar yopilganda ham Echo belgisi Dock’da qoladi.") {
                        settingsToggle("Dock belgisini doim ko‘rsatish", isOn: $preferences.alwaysShowDockIcon)
                    }
                    Divider()
                    SettingsRow("Mac yoqilganda ishga tushirish", detail: loginItemDetail) {
                        settingsToggle("Mac yoqilganda ishga tushirish", isOn: Binding(
                            get: { model.loginItem.isEnabled }, set: model.loginItem.setEnabled))
                    }
                    if model.loginItem.needsApproval {
                        Button(AppLocalization.text("Login Items sozlamalarini ochish")) { model.loginItem.openSystemSettings() }
                            .padding(.bottom, 14)
                    }
                    if let error = model.loginItem.error { ErrorBanner(message: error).padding(.bottom, 14) }
                }
            }
            UpdateSettingsSection(updates: .shared)
        }
    }

    private var loginItemDetail: String? {
        if model.loginItem.needsApproval { return "Avtomatik ishga tushish uchun macOS ruxsatini yoqing." }
        if !model.loginItem.isInstalled { return "Avtomatik ishga tushish uchun Echo’ni Applications papkasiga o‘rnating." }
        return nil
    }

    private var dictationSettings: some View {
        @Bindable var preferences = model.preferences
        return Group {
            SettingsSection("O‘zbek yozuvi", subtitle: "Faqat yangi o‘zbekcha diktovka matniga qo‘llanadi.") {
                SettingsGroup {
                    SettingsRow("O‘zbek yozuvi", verbatimDetail: preferences.uzbekAlphabet.example) {
                        SettingsMenu(title: "O‘zbek yozuvi", selection: $preferences.uzbekAlphabet,
                                     options: UzbekAlphabet.allCases) { AppLocalization.text($0.title) }
                    }
                }
            }
            SettingsSection("Avtomatik joylash", subtitle: "Tayyor matn kursor turgan joyga joylanadi.") {
                SettingsGroup {
                    SettingsRow("Tayyor matnni avtomatik joylash") {
                        settingsToggle("Tayyor matnni avtomatik joylash", isOn: $preferences.autoPaste)
                    }
                    Divider()
                    SettingsRow(
                        "Matn joylash usuli",
                        detail: "Brauzer yoki ilova paste qabul qilmasa, klaviatura orqali yozishni tanlang."
                    ) {
                        SettingsMenu(title: "Matn joylash usuli", selection: $preferences.textInsertionMethod,
                                     options: TextInsertionMethod.allCases) { AppLocalization.text($0.title) }
                            .disabled(!preferences.autoPaste)
                    }
                }
            }
            SettingsSection("Tarix", subtitle: "Yozuvlar faqat shu Mac’da saqlanadi.") {
                SettingsGroup {
                    SettingsRow("Yangi yozuvlarni lokal tarixga saqlash") {
                        settingsToggle("Yangi yozuvlarni lokal tarixga saqlash", isOn: $preferences.retainHistory)
                    }
                }
            }
        }
    }

    private var shortcutSettings: some View {
        @Bindable var preferences = model.preferences
        return SettingsSection(
            SettingsPage.shortcuts.title, subtitle: SettingsPage.shortcuts.subtitle,
            footer: "Bir yozuv 10 daqiqagacha. Tayyor matn kursor turgan joyga joylanadi."
        ) {
            SettingsGroup {
                SettingsRow(
                    "Global shortcut",
                    verbatimDetail: shortcutError ?? AppLocalization.text(
                        "Bosing va tugmani tanlang: fn, yakka modifikator, F-tugma yoki ⌘, ⌥, ⌃ bilan kombinatsiya."),
                    detailIsError: shortcutError != nil
                ) {
                    ShortcutField(model: model) { shortcutError = $0 }
                }
                Divider()
                SettingsRow("Ishga tushirish usuli", detail: preferences.activationMode.detail) {
                    SettingsMenu(title: "Ishga tushirish usuli", selection: $preferences.activationMode,
                                 options: DictationActivationMode.allCases) { AppLocalization.text($0.title) }
                }
                Divider()
                SettingsRow("Oxirgi yozuvni joylash",
                            detail: "Eng so‘nggi yozuvingizni tanlangan matn maydoniga qayta yozadi.") {
                    Text(verbatim: "⌃⌘V").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).frame(minWidth: 60, minHeight: 26)
                        .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
    }

    private var permissionSettings: some View {
        SettingsSection(
            SettingsPage.permissions.title, subtitle: SettingsPage.permissions.subtitle,
            footer: "Ruxsat berilmasa ham natijani qo‘lda nusxalash mumkin."
        ) {
            SettingsGroup {
                SettingsRow("Mikrofon") {
                    Button(AppLocalization.text("System Settings’da ochish")) { openPrivacy("Microphone") }
                }
                Divider()
                SettingsRow("Avtomatik joylash") {
                    Button(AppLocalization.text(accessibility ? "Accessibility yoqilgan" : "Accessibility ruxsatini berish")) {
                        TextInsertion.requestAccessibility()
                        openPrivacy("Accessibility")
                    }
                }
            }
        }
    }

    private var notificationSettings: some View {
        Group {
            SettingsSection(SettingsPage.notifications.title, subtitle: SettingsPage.notifications.subtitle) {
                SettingsGroup {
                    SettingsRow("Update notifications", detail: "Let Echo notify you when an update is available or ready to install.") {
                        settingsToggle("Update notifications", isOn: Binding(
                            get: { model.updateNotifications.isEnabled },
                            set: { model.updateNotifications.setEnabled($0) }
                        ))
                    }
                    if let push = model.push {
                        Divider()
                        SettingsRow("Important alerts") {
                            settingsToggle("Important alerts", isOn: Binding(
                                get: { push.isEnabled && push.preferences.important },
                                set: { enabled in Task { await push.setCategory(.important, enabled: enabled) } }
                            )).disabled(push.isUpdating)
                        }
                        Divider()
                        SettingsRow("News") {
                            settingsToggle("News", isOn: Binding(
                                get: { push.isEnabled && push.preferences.news },
                                set: { enabled in Task { await push.setCategory(.news, enabled: enabled) } }
                            )).disabled(push.isUpdating)
                        }
                        if let error = push.error {
                            HStack {
                                Text(error).font(.callout).foregroundStyle(.secondary)
                                Button(AppLocalization.text("Qayta urinish")) { Task { await push.retryRegistration() } }
                            }.padding(.bottom, 14)
                        }
                    }
                    if model.updateNotifications.authorization == .notDetermined {
                        Button(AppLocalization.text("Bildirishnomalarga ruxsat berish")) {
                            Task {
                                await model.updateNotifications.requestPermission()
                                await model.push?.refresh()
                            }
                        }
                        .disabled(model.updateNotifications.isRequestingPermission)
                        .padding(.bottom, 14)
                    } else if model.updateNotifications.authorization == .denied {
                        Button(AppLocalization.text("Bildirishnoma sozlamalarini ochish")) {
                            model.updateNotifications.openSystemSettings()
                        }
                        .padding(.bottom, 14)
                    }
                    if let error = model.updateNotifications.error {
                        Text(error).font(.callout).foregroundStyle(.secondary).padding(.bottom, 14)
                    }
                }
            }
            if let inbox = model.inbox {
                NotificationInboxView(model: inbox, push: model.push, embedded: true, onOpen: {
                    model.dismissSettings()
                })
                .clipShape(RoundedRectangle(cornerRadius: settingsGroupRadius, style: .continuous))
            } else {
                SettingsGroup {
                    SettingsRow("Hozircha yangilik yo‘q", detail: "Echo yangiliklari shu yerda ko‘rinadi.") { EmptyView() }
                }
            }
        }
        .task {
            await model.updateNotifications.refresh()
            await model.push?.refresh()
        }
    }

    private var changelog: some View {
        VStack(alignment: .leading, spacing: 32) {
            Text(AppLocalization.text(SettingsPage.changelog.subtitle))
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ForEach(ChangelogRelease.all) { release in
                SettingsSection(AppLocalization.text("Versiya %@", release.version), subtitle: release.formattedDate) {
                    SettingsGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(release.changes, id: \.self) { change in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Circle().fill(Design.tint).frame(width: 5, height: 5)
                                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                                    Text(AppLocalization.text(change)).font(.system(size: 13))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.vertical, 14)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func settingsToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(AppLocalization.text(label), isOn: isOn).labelsHidden().toggleStyle(.switch)
            .accessibilityLabel(AppLocalization.text(label))
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
