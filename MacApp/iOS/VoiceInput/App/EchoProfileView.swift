import SwiftUI

/// Native account overview with inline allowance and separate subscription details.
@MainActor
struct EchoProfileView: View {
    var embedded = false
    var keyboardHost: KeyboardSessionHost? = nil
    let onSignOut: @MainActor () async throws -> Void

    @AppStorage("echo.app.language") private var appLanguage = EchoAppLanguage.uzbek.rawValue
    @Environment(\.dismiss) private var dismiss
    @State private var showsSettings = false
    @State private var showsBilling = false
    @State private var account: EchoAccount?
    @State private var usage: EchoUsageSnapshot?
    @State private var subscription: EchoSubscription?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var isSigningOut = false
    @State private var confirmsSignOut = false
    @State private var identityError: String?
    @State private var usageError: String?
    @State private var subscriptionError: String?
    @State private var signOutError: String?

    private var ui: EchoAppLanguage { EchoAppLanguage(rawValue: appLanguage) ?? .uzbek }

    var body: some View {
        NavigationStack {
            List {
                if hasLoaded || account != nil {
                    Section {
                        identityCard
                        if let identityError { failure(identityError) }
                    }
                    .listRowBackground(EchoMobileTheme.surface)
                    Section {
                        allowanceSummary
                    }
                    .listRowBackground(EchoMobileTheme.surface)
                    Section {
                        NavigationLink { subscriptionDetails } label: {
                            HStack(spacing: 12) {
                                MobileIcon(systemName: "creditcard").foregroundStyle(EchoMobileTheme.ink)
                                Text(ui.text(uz: "Obuna", en: "Subscription", ru: "Подписка"))
                                    .foregroundStyle(EchoMobileTheme.ink)
                                Spacer(minLength: 8)
                                Text(planSubtitle).font(.subheadline).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                            .frame(minHeight: 40)
                        }
                        accountActions
                    }
                    .listRowBackground(EchoMobileTheme.surface)
                    Section {
                        signOutButton
                    }
                    .listRowBackground(EchoMobileTheme.surface)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(16)
            .scrollContentBackground(.hidden)
            .background(EchoMobileTheme.canvas)
            .overlay {
                if !hasLoaded && account == nil {
                    WorkspaceLoading(title: ui.text(uz: "Profil yuklanmoqda…", en: "Loading your profile…", ru: "Загрузка профиля…"))
                }
            }
            .navigationTitle(ui.text(uz: "Profil", en: "Profile", ru: "Профиль"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !embedded {
                        Button(ui.text(uz: "Tayyor", en: "Done", ru: "Готово")) { dismiss() }
                            .disabled(isSigningOut)
                    }
                }
            }
            .refreshable { await refresh() }
        }
        .tint(EchoMobileTheme.ink)
        .sheet(isPresented: $showsSettings) { EchoSettingsView(keyboardHost: keyboardHost) }
        .sheet(isPresented: $showsBilling) {
            if let account { EchoBillingView(accountID: account.id) }
        }
        .task { if !hasLoaded { await refresh() } }
        .interactiveDismissDisabled(isSigningOut)
        .confirmationDialog(ui.text(uz: "Hisobdan chiqasizmi?", en: "Sign out of Echo?", ru: "Выйти из Echo?"), isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button(ui.text(uz: "Hisobdan chiqish", en: "Sign out", ru: "Выйти"), role: .destructive) {
                Task { await signOut() }
            }
            Button(ui.text(uz: "Bekor qilish", en: "Cancel", ru: "Отмена"), role: .cancel) {}
        } message: {
            Text(ui.text(uz: "Qoralama va faqat shu seansdagi qaydlar o‘chadi. Kerakli matnni oldin nusxalang.", en: "Your draft and session-only notes will be cleared. Copy anything you want to keep first.", ru: "Черновик и заметки текущего сеанса будут удалены. Сначала скопируйте нужный текст."))
        }
    }

    private var identityCard: some View {
        HStack(alignment: .center, spacing: 14) {
            avatar
            VStack(alignment: .leading, spacing: 5) {
                Text(account?.name ?? ui.text(uz: "Echo hisobi", en: "Echo account", ru: "Аккаунт Echo"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(EchoMobileTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let email = account?.email {
                    Text(email)
                        .font(.footnote).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }

    private var planSubtitle: String {
        if let subscription {
            return subscription.packageName ?? (subscription.active
                ? ui.text(uz: "Faol", en: "Active", ru: "Активна")
                : ui.text(uz: "Obuna yo‘q", en: "No subscription", ru: "Нет подписки"))
        }
        return isLoading
            ? ui.text(uz: "Yuklanmoqda…", en: "Loading…", ru: "Загрузка…")
            : ui.text(uz: "Yuklanmadi", en: "Unavailable", ru: "Недоступно")
    }

    private var allowanceSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ui.text(uz: "Diktovka vaqti", en: "Dictation time", ru: "Время диктовки"))
                .font(.subheadline.weight(.semibold))
            if let usage, usage.enabled {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        timeMetric(ui.text(uz: "Ishlatilgan", en: "Used", ru: "Использовано"), seconds: usage.usedSeconds)
                        timeMetric(ui.text(uz: "Qolgan", en: "Remaining", ru: "Осталось"), seconds: usage.remainingSeconds)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        timeMetric(ui.text(uz: "Ishlatilgan", en: "Used", ru: "Использовано"), seconds: usage.usedSeconds)
                        timeMetric(ui.text(uz: "Qolgan", en: "Remaining", ru: "Осталось"), seconds: usage.remainingSeconds)
                    }
                }
                if let limit = usage.usageLimitSeconds, limit > 0, let used = usage.usedSeconds {
                    ProgressView(value: Double(min(limit, max(0, used))), total: Double(limit))
                        .tint(EchoMobileTheme.ink).accessibilityHidden(true)
                }
                VStack(spacing: 6) {
                    allowanceDetail(ui.text(uz: "Jami limit", en: "Total allowance", ru: "Общий лимит"), value: usage.usageLimitSeconds.map(duration) ?? "—")
                    if let reset = dateDescription(usage.resetsAt) {
                        allowanceDetail(ui.text(uz: "Yangilanadi", en: "Resets", ru: "Обновится"), value: reset)
                    }
                }
            } else if isLoading && usage == nil {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
            } else {
                Text(usage?.enabled == false
                     ? ui.text(uz: "Diktovka yoqilmagan", en: "Dictation is disabled", ru: "Диктовка отключена")
                     : ui.text(uz: "Ma’lumot yuklanmadi", en: "Details unavailable", ru: "Данные недоступны"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let usageError { failure(usageError) }
        }
        .padding(.vertical, 6)
    }

    private func timeMetric(_ title: String, seconds: Int?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(seconds.map(duration) ?? "—")
                .font(.title3.weight(.semibold)).monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(EchoMobileTheme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func allowanceDetail(_ title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fixedSize()
                Spacer(minLength: 12)
                Text(value).fixedSize()
            }
            VStack(alignment: .leading, spacing: 3) { Text(title); Text(value) }
        }
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var accountActions: some View {
        Button { showsSettings = true } label: {
            HStack(spacing: 12) {
                MobileIcon(systemName: "slider.horizontal.3").foregroundStyle(EchoMobileTheme.ink)
                Text(ui.text(uz: "Sozlamalar", en: "Settings", ru: "Настройки"))
                    .foregroundStyle(EchoMobileTheme.ink)
                Spacer()
                MobileIcon(systemName: "chevron.right", size: 14).foregroundStyle(.tertiary)
            }.frame(minHeight: 40).contentShape(Rectangle())
        }
        .disabled(isSigningOut)
    }

    private var subscriptionDetails: some View {
        List {
            Section {
                subscriptionSummary
            }
            .listRowBackground(EchoMobileTheme.surface)
            if let subscription, subscription.active {
                Section {
                    valueRow(ui.text(uz: "Kunlik diktovka", en: "Daily dictation", ru: "Диктовка в день"), value: duration(subscription.dailySeconds))
                    valueRow(ui.text(uz: "Bitta yozuv", en: "Per recording", ru: "Одна запись"), value: duration(subscription.maxRequestSeconds))
                } header: {
                    Text(ui.text(uz: "Tarif imkoniyatlari", en: "Plan allowance", ru: "Возможности тарифа"))
                }
                .listRowBackground(EchoMobileTheme.surface)
                if let end = dateDescription(subscription.periodEndsAt) {
                    Section {
                        valueRow(subscription.cancelAtPeriodEnd
                                 ? ui.text(uz: "Obuna tugaydi", en: "Subscription ends", ru: "Подписка закончится")
                                 : ui.text(uz: "Joriy davr oxiri", en: "Current period ends", ru: "Конец текущего периода"), value: end)
                    } footer: {
                        if subscription.cancelAtPeriodEnd {
                            Text(ui.text(uz: "Avtomatik yangilanish o‘chirilgan. Shu sanagacha obunangizdan foydalanishingiz mumkin.", en: "Automatic renewal is off. Your subscription stays available until this date.", ru: "Автопродление отключено. Подписка доступна до этой даты."))
                        }
                    }
                    .listRowBackground(EchoMobileTheme.surface)
                }
            }
            #if DEBUG
            Section {
                Button { showsBilling = true } label: {
                    HStack(spacing: 12) {
                        MobileIcon(systemName: "creditcard")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ui.text(uz: "Tariflar va to‘lovlar", en: "Plans & payments", ru: "Тарифы и платежи"))
                                .foregroundStyle(EchoMobileTheme.ink)
                            Text(ui.text(uz: "Tarif tanlash, kartalar va to‘lov tarixi", en: "Choose a plan, manage cards and payments", ru: "Выбор тарифа, карты и история оплат"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        MobileIcon(systemName: "chevron.right", size: 14)
                    }.frame(minHeight: 44)
                }
                .disabled(account == nil || isSigningOut)
            }
            .listRowBackground(EchoMobileTheme.surface)
            #endif
        }
        .listStyle(.insetGrouped).listSectionSpacing(16)
        .scrollContentBackground(.hidden)
        .background(EchoMobileTheme.canvas)
        .navigationTitle(ui.text(uz: "Obuna", en: "Subscription", ru: "Подписка"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
    }

    private var avatar: some View {
        Group {
            if let url = account?.avatarURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: some View {
        let letters = account?.name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined() ?? ""
        return ZStack {
            Circle().fill(EchoMobileTheme.selection)
            if letters.isEmpty { MobileIcon(systemName: "person.fill").font(.title2).foregroundStyle(EchoMobileTheme.ink) }
            else { Text(letters.uppercased()).font(.title3.weight(.semibold)).foregroundStyle(EchoMobileTheme.ink) }
        }
    }

    private var subscriptionSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let subscription {
                HStack(spacing: 10) {
                    MobileIcon(systemName: "creditcard", size: 24)
                    Text(subscription.packageName ?? (subscription.active
                         ? ui.text(uz: "Echo obunasi", en: "Echo subscription", ru: "Подписка Echo")
                         : ui.text(uz: "Faol obuna yo‘q", en: "No active subscription", ru: "Нет активной подписки")))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(EchoMobileTheme.ink)
                }
                HStack(spacing: 6) {
                    Circle().fill(subscription.active ? Color.green : Color.secondary).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(subscription.active
                         ? ui.text(uz: "Obunangiz faol", en: "Your subscription is active", ru: "Подписка активна")
                         : ui.text(uz: "Joriy diktovka limitini Profil ekranida ko‘rishingiz mumkin.", en: "Your current dictation allowance is available in Profile.", ru: "Текущий лимит диктовки указан в профиле."))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let subscriptionError { failure(subscriptionError) }
        }
        .padding(.vertical, 10)
    }

    private var signOutButton: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(role: .destructive) { confirmsSignOut = true } label: {
                HStack {
                    if isSigningOut { ProgressView() }
                    else { MobileIcon(systemName: "rectangle.portrait.and.arrow.right") }
                    Text(ui.text(uz: "Hisobdan chiqish", en: "Sign out", ru: "Выйти из аккаунта"))
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)

            .disabled(isSigningOut)
            if let signOutError { Text(signOutError).font(.footnote).foregroundStyle(.red) }
        }
    }

    private func valueRow(_ title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value).multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.secondary)
                Text(value)
            }
        }
        .font(.subheadline)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.footnote).foregroundStyle(.red)
            Button(ui.text(uz: "Qayta urinish", en: "Retry", ru: "Повторить")) {
                Task { await refresh() }
            }
            .frame(minHeight: 44)
            .disabled(isLoading || isSigningOut)
        }
    }

    private func duration(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    private func dateDescription(_ value: String?) -> String? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func refresh() async {
        guard !isLoading, !isSigningOut else { return }
        isLoading = true
        defer {
            isLoading = false
            if !Task.isCancelled { hasLoaded = true }
        }
        identityError = nil
        usageError = nil
        subscriptionError = nil
        if account == nil {
            do { account = try await EchoAuthClient.shared.restore() }
            catch { identityError = error.localizedDescription }
        }
        // Fetch independent sections concurrently and apply them together. Returning
        // to this tab keeps the existing content instead of inserting a spinner row.
        async let nextAccount = try? EchoAuthClient.shared.getProfile()
        async let nextUsage = try? EchoAuthClient.shared.getUsage()
        async let nextSubscription = try? EchoAuthClient.shared.getSubscription()
        let (identity, allowance, plan) = await (nextAccount, nextUsage, nextSubscription)
        guard !Task.isCancelled else { return }
        if let identity { account = identity }
        else { identityError = ui.text(uz: "Profilni yangilab bo‘lmadi.", en: "Couldn’t refresh your profile.", ru: "Не удалось обновить профиль.") }
        if let allowance { usage = allowance }
        else { usageError = ui.text(uz: "Limitni yuklab bo‘lmadi.", en: "Couldn’t load your allowance.", ru: "Не удалось загрузить лимит.") }
        if let plan { subscription = plan }
        else { subscriptionError = ui.text(uz: "Obunani yuklab bo‘lmadi.", en: "Couldn’t load your subscription.", ru: "Не удалось загрузить подписку.") }
    }

    private func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        signOutError = nil
        defer { isSigningOut = false }
        do { try await onSignOut() }
        catch { signOutError = error.localizedDescription }
    }
}
