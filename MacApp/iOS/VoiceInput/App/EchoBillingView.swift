import Observation
import SwiftUI
import SafariServices

/// Uses the existing account billing API. Prices and card masks always come from
/// the server; full card details exist only in the short-lived enrollment sheet.
struct EchoBillingView: View {
    @AppStorage("echo.app.language") private var appLanguage = EchoAppLanguage.uzbek.rawValue
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: EchoBillingModel
    @State private var showsAddCard = false
    @State private var selectedOffer: EchoBilling.Offer?
    @State private var selectedCardId = ""
    @State private var confirmsPurchase = false
    @State private var confirmsCancellation = false
    @State private var cardToRemove: EchoBilling.Card?
    @State private var period = "month"
    @State private var paymentMethod = "local"
    @State private var hostedCheckout: EchoBilling.HostedCheckout?

    init(accountID: String) {
        _model = State(initialValue: EchoBillingModel(accountId: accountID))
    }

    private var ui: EchoAppLanguage { EchoAppLanguage(rawValue: appLanguage) ?? .uzbek }
    private var selectedCard: EchoBilling.Card? { model.cards.first { $0.id == selectedCardId } }

    var body: some View {
        NavigationStack {
            List {
                if model.hasLoaded {
                    subscriptionSection.listRowBackground(EchoMobileTheme.surface)
                    pendingSection.listRowBackground(EchoMobileTheme.surface)
                    hostedPendingSection.listRowBackground(EchoMobileTheme.surface)
                    plansSection.listRowBackground(EchoMobileTheme.surface)
                    cardsSection.listRowBackground(EchoMobileTheme.surface)
                    paymentsSection.listRowBackground(EchoMobileTheme.surface)
                    if let message = model.error {
                        Section {
                            MobileLabel(message, systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button(ui.text(uz: "Qayta yuklash", en: "Reload", ru: "Обновить")) { Task { await model.load() } }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(16)
            .scrollContentBackground(.hidden)
            .background(EchoMobileTheme.canvas)
            .navigationTitle(ui.text(uz: "Obuna va to‘lovlar", en: "Subscription & payments", ru: "Подписка и платежи"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(ui.text(uz: "Tayyor", en: "Done", ru: "Готово")) { dismiss() }
                        .disabled(model.isBusy)
                }
            }
            .refreshable { await model.load() }
            .overlay {
                if !model.hasLoaded {
                    WorkspaceLoading(title: ui.text(uz: "Obuna yuklanmoqda…", en: "Loading subscription…", ru: "Загрузка подписки…"))
                }
            }
        }
        .tint(EchoMobileTheme.ink)
        .task { if !model.hasLoaded { await model.load() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && model.hasLoaded { Task { await model.load() } }
        }
        .interactiveDismissDisabled(model.isBusy)
        .sheet(isPresented: $showsAddCard) {
            EchoAddCardView(service: model.service, ui: ui) { card in
                selectedCardId = card.id
                Task { await model.load() }
            }
        }
        .sheet(item: $hostedCheckout, onDismiss: { Task { await model.load() } }) { checkout in
            if let url = checkout.url { EchoBillingSafariView(url: url) }
        }
        .sheet(item: $selectedOffer) { offer in
            checkout(offer)
        }
        .confirmationDialog(ui.text(uz: "Kartani olib tashlaysizmi?", en: "Remove this card?", ru: "Удалить карту?"), isPresented: Binding(get: { cardToRemove != nil }, set: { if !$0 { cardToRemove = nil } })) {
            if let card = cardToRemove {
                Button(ui.text(uz: "Kartani olib tashlash", en: "Remove card", ru: "Удалить карту"), role: .destructive) {
                    cardToRemove = nil
                    Task { await model.removeCard(card) }
                }
            }
        }
        .confirmationDialog(ui.text(uz: "Avtomatik yangilanishni o‘chirasizmi?", en: "Turn off automatic renewal?", ru: "Выключить автопродление?"), isPresented: $confirmsCancellation, titleVisibility: .visible) {
            Button(ui.text(uz: "Yangilanishni o‘chirish", en: "Turn off renewal", ru: "Выключить продление"), role: .destructive) {
                Task { await model.setRenewal(false) }
            }
        } message: {
            Text(ui.text(uz: "Obuna joriy to‘langan davr oxirigacha ishlaydi.", en: "Your subscription stays available until the current paid period ends.", ru: "Подписка действует до конца оплаченного периода."))
        }
        .onChange(of: model.cards) { _, cards in
            if !cards.contains(where: { $0.id == selectedCardId }) {
                selectedCardId = cards.first(where: \.isDefault)?.id ?? cards.first?.id ?? ""
            }
        }
    }

    @ViewBuilder private var subscriptionSection: some View {
        Section {
            if let subscription = model.subscription {
                MobileLabel(subscription.planName, systemImage: "creditcard")
                    .font(.headline)
                LabeledContent(ui.text(uz: "Holat", en: "Status", ru: "Статус"), value: status(subscription.status))
                LabeledContent(ui.text(uz: "Narx", en: "Price", ru: "Цена"), value: EchoBilling.money(subscription.amountMinor, currency: subscription.currency))
                LabeledContent(subscription.cancelAtPeriodEnd
                               ? ui.text(uz: "Tugaydi", en: "Ends", ru: "Завершится")
                               : ui.text(uz: "Keyingi davr", en: "Next period", ru: "Следующий период"), value: EchoBilling.date(subscription.periodEndsAt))
                MobileLabel(subscription.card.maskedNumber, systemImage: "creditcard")
                    .font(.subheadline).foregroundStyle(.secondary)
                if subscription.isCurrent && !subscription.isProcessing {
                    if subscription.cancelAtPeriodEnd {
                        Button(ui.text(uz: "Avtomatik yangilanishni yoqish", en: "Enable automatic renewal", ru: "Включить автопродление")) {
                            Task { await model.setRenewal(true) }
                        }
                    } else {
                        Button(ui.text(uz: "Avtomatik yangilanishni o‘chirish", en: "Turn off automatic renewal", ru: "Выключить автопродление"), role: .destructive) { confirmsCancellation = true }
                    }
                }
            } else if let account = model.accountSubscription, account.isCurrent {
                MobileLabel(account.planName, systemImage: "creditcard").font(.headline)
                LabeledContent(ui.text(uz: "Holat", en: "Status", ru: "Статус"), value: status(account.status))
                LabeledContent(ui.text(uz: "Keyingi davr", en: "Next period", ru: "Следующий период"), value: EchoBilling.date(account.periodEndsAt))
                Text(ui.text(uz: "Visa / Mastercard obunasi. Obunani VoiceLab hisobingiz orqali boshqaring.", en: "Visa / Mastercard subscription. Manage renewal in your VoiceLab account.", ru: "Подписка Visa / Mastercard. Управляйте продлением в аккаунте VoiceLab."))
                    .font(.footnote).foregroundStyle(.secondary)
            } else if model.hasLoaded {
                MobileLabel(ui.text(uz: "Faol obuna yo‘q", en: "No active subscription", ru: "Нет активной подписки"), systemImage: "creditcard")
                Text(ui.text(uz: "Mavjud hisob limitlari Profil sahifasida ko‘rsatiladi.", en: "Your account’s existing allowance is shown in Profile.", ru: "Текущие лимиты аккаунта показаны в профиле."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text(ui.text(uz: "Joriy obuna", en: "Current subscription", ru: "Текущая подписка"))
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder private var pendingSection: some View {
        if model.pending != nil || model.subscription?.isProcessing == true {
            Section {
                MobileLabel(ui.text(uz: "To‘lov tekshirilmoqda", en: "Payment needs confirmation", ru: "Платёж проверяется"), systemImage: "clock")
                Text(ui.text(uz: "To‘lov natijasini tekshiring. Tekshiruv yangi to‘lov yaratmaydi.", en: "Check the result of this payment. Checking does not create another charge.", ru: "Проверьте результат платежа. Проверка не создаёт новое списание."))
                    .font(.footnote).foregroundStyle(.secondary)
                Button(ui.text(uz: "To‘lov holatini tekshirish", en: "Check payment status", ru: "Проверить платёж")) {
                    Task { await model.checkPendingPayment() }
                }.disabled(model.isBusy)
            }
        }
    }

    @ViewBuilder private var hostedPendingSection: some View {
        if let prior = model.hostedPending {
            Section {
                MobileLabel(ui.text(uz: "Avvalgi to‘lov oynasi", en: "Previous checkout", ru: "Предыдущая оплата"), systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                if let name = prior.planName { LabeledContent(ui.text(uz: "Tarif", en: "Plan", ru: "Тариф"), value: name) }
                if let cadence = prior.billingInterval {
                    LabeledContent(ui.text(uz: "Davr", en: "Period", ru: "Период"), value: interval(cadence, count: prior.billingIntervalCount ?? 1))
                }
                LabeledContent(ui.text(uz: "Holat", en: "Status", ru: "Статус"), value: checkoutStatus(prior.status))
                if let expiry = prior.expiresAt {
                    LabeledContent(ui.text(uz: "To‘lov oynasi tugaydi", en: "Checkout expires", ru: "Окно оплаты истекает"), value: EchoBilling.expiryDate(expiry))
                }
                Text(ui.text(uz: "Bu avval tanlangan tarifning to‘lov oynasi. Boshqa tarifni boshlash uchun avvalgi oynaning haqiqiy muddati tugashini yoki to‘lov natijasi tasdiqlanishini kuting.", en: "This checkout belongs to your previous plan selection. A new plan must wait for the provider’s actual checkout expiry or confirmed payment result.", ru: "Это окно оплаты ранее выбранного тарифа. Новый тариф можно выбрать после фактического истечения окна оплаты или подтверждения результата платежа."))
                    .font(.footnote).foregroundStyle(.secondary)
                if let checkout = prior.resumableCheckout {
                    Button(ui.text(uz: "Avvalgi to‘lovni davom ettirish", en: "Continue previous checkout", ru: "Продолжить предыдущую оплату")) {
                        hostedCheckout = checkout
                    }.frame(minHeight: 44)
                }
                Button(ui.text(uz: "Holatni yangilash", en: "Refresh status", ru: "Обновить статус")) {
                    Task { await model.refreshHostedPending() }
                }.frame(minHeight: 44)
            }.disabled(model.isBusy)
        }
    }

    private func checkoutStatus(_ value: String) -> String {
        switch value {
        case "open": ui.text(uz: "To‘lov kutilmoqda", en: "Awaiting payment", ru: "Ожидает оплаты")
        case "confirmed", "succeeded": ui.text(uz: "Natija tasdiqlanmoqda", en: "Confirming result", ru: "Результат подтверждается")
        case "unknown": ui.text(uz: "Holat hali noma’lum", en: "Status not yet known", ru: "Статус пока неизвестен")
        default: value
        }
    }

    private var plansSection: some View {
        Section {
            Picker(ui.text(uz: "To‘lov davri", en: "Billing period", ru: "Период оплаты"), selection: $period) {
                Text(ui.text(uz: "Oylik", en: "Monthly", ru: "Месяц")).tag("month")
                Text(ui.text(uz: "Yillik", en: "Yearly", ru: "Год")).tag("year")
            }
            .pickerStyle(.segmented).disabled(model.isBusy)
            Picker(ui.text(uz: "To‘lov usuli", en: "Payment method", ru: "Способ оплаты"), selection: $paymentMethod) {
                Text("Uzcard / Humo").tag("local")
                Text("Visa / Mastercard").tag("international")
            }
            .disabled(model.isBusy)
            if paymentMethod == "local", let offer = model.offers.first(where: { $0.billingInterval == period }) {
                VStack(alignment: .leading, spacing: 16) {
                    planPrice(name: offer.name, price: offer.price, cadence: interval(offer.billingInterval, count: offer.billingIntervalCount))
                    Button {
                        selectedCardId = model.cards.first(where: \.isDefault)?.id ?? model.cards.first?.id ?? ""
                        selectedOffer = offer
                    } label: {
                        Text(ui.text(uz: "Tarifni tanlash", en: "Choose plan", ru: "Выбрать тариф"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(EchoMobileTheme.canvas)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent).tint(EchoMobileTheme.ink)
                    .disabled(!offer.purchasable || model.catalog?.enabled != true || purchaseDisabled)
                }
                .padding(.vertical, 8)
            } else if paymentMethod == "international", let offer = model.hostedOffers.first(where: { $0.billingInterval == period }) {
                VStack(alignment: .leading, spacing: 16) {
                    planPrice(name: offer.name, price: offer.price, cadence: interval(offer.billingInterval, count: offer.billingIntervalCount))
                    Button {
                        Task { hostedCheckout = await model.createHostedCheckout(offer) }
                    } label: {
                        Text(ui.text(uz: "To‘lovga o‘tish", en: "Continue to checkout", ru: "Перейти к оплате"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(EchoMobileTheme.canvas)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent).tint(EchoMobileTheme.ink)
                    .disabled(!offer.available || purchaseDisabled)
                    Text(ui.text(uz: "Karta ma’lumotlari Polar’ning himoyalangan to‘lov sahifasida kiritiladi.", en: "Enter your card on Polar’s secure checkout page.", ru: "Данные карты вводятся на защищённой странице Polar."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if model.hasLoaded {
                Text(ui.text(uz: "Bu davr yoki to‘lov usuli hozir mavjud emas.", en: "This period or payment method is currently unavailable.", ru: "Этот период или способ оплаты сейчас недоступен."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } header: {
            Text(ui.text(uz: "Tarif tanlash", en: "Choose a plan", ru: "Выбор тарифа"))
        } footer: {
            if model.hasCurrentSubscription {
                Text(ui.text(uz: "Sizda faol obuna bor. Uni yuqoridagi Joriy obuna bo‘limida boshqaring.", en: "You already have a subscription. Manage it under Current subscription above.", ru: "У вас уже есть подписка. Управляйте ей в разделе «Текущая подписка» выше."))
            } else if model.pending != nil || model.hostedPending != nil {
                Text(ui.text(uz: "Avval boshlangan to‘lov holatini tekshiring.", en: "Check your existing payment before choosing a new plan.", ru: "Сначала проверьте уже начатый платёж."))
            } else {
                Text(ui.text(uz: "Obuna tanlangan davr bo‘yicha avtomatik yangilanadi. To‘lovdan oldin narx va kartani tasdiqlaysiz.", en: "Your subscription renews for the selected period. Review the price and card before paying.", ru: "Подписка продлевается на выбранный период. Перед оплатой проверьте цену и карту."))
            }
        }
    }

    private func planPrice(name: String, price: String, cadence: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.headline).foregroundStyle(EchoMobileTheme.ink)
            Text(price).font(.title2.weight(.semibold)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(cadence).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var purchaseDisabled: Bool {
        model.isBusy || model.pending != nil || model.hostedPending != nil || model.hasCurrentSubscription
            || (paymentMethod == "local" ? !model.access.canPurchaseLocal : !model.access.canPurchaseHosted)
    }

    private var cardsSection: some View {
        Section {
            ForEach(model.cards) { card in
                HStack(spacing: 12) {
                    MobileIcon(systemName: "creditcard")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.maskedNumber).font(.subheadline.weight(.medium))
                        Text(card.vendor + (card.isDefault ? " · " + ui.text(uz: "Asosiy", en: "Default", ru: "Основная") : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        if !card.isDefault {
                            Button(ui.text(uz: "Asosiy karta qilish", en: "Make default", ru: "Сделать основной")) {
                                Task { await model.makeDefault(card) }
                            }
                        }
                        Button(ui.text(uz: "Olib tashlash", en: "Remove", ru: "Удалить"), role: .destructive) { cardToRemove = card }
                            .disabled(card.inUse)
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel(ui.text(uz: "Karta amallari", en: "Card actions", ru: "Действия с картой"))
                }
                .frame(minHeight: 48)
            }
            if model.cards.isEmpty && model.hasLoaded {
                Text(ui.text(uz: "Saqlangan kartalar yo‘q", en: "No saved cards", ru: "Нет сохранённых карт"))
                    .foregroundStyle(.secondary)
            }
            Button { showsAddCard = true } label: {
                MobileLabel(ui.text(uz: "Karta qo‘shish", en: "Add card", ru: "Добавить карту"), systemImage: "plus.circle")
                    .frame(minHeight: 44)
            }
            .disabled(!model.access.canManageCards || model.cards.count >= model.maxCards)
        } header: {
            Text(ui.text(uz: "Kartalar", en: "Cards", ru: "Карты"))
        } footer: {
            Text(ui.text(uz: "Karta Paylov orqali SMS kodi bilan tasdiqlanadi. Echo karta raqami va SMS kodini saqlamaydi.", en: "Cards are verified by Paylov using an SMS code. Echo does not save the full card number or SMS code.", ru: "Карта подтверждается SMS-кодом через Paylov. Echo не сохраняет полный номер карты и SMS-код."))
        }
        .disabled(model.isBusy || !model.access.canManageCards)
    }

    @ViewBuilder private var paymentsSection: some View {
        if !model.payments.isEmpty {
            Section(ui.text(uz: "To‘lovlar tarixi", en: "Payment history", ru: "История платежей")) {
                ForEach(model.payments) { payment in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(payment.planName).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(EchoBilling.money(payment.amountMinor, currency: payment.currency)).font(.subheadline)
                        }
                        HStack {
                            Text(EchoBilling.date(payment.paidAt ?? payment.createdAt))
                            Spacer()
                            Text(status(payment.status))
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
        }
    }

    private func checkout(_ offer: EchoBilling.Offer) -> some View {
        NavigationStack {
            Form {
                Section {
                    MobileLabel(offer.name, systemImage: "creditcard").font(.headline)
                    LabeledContent(ui.text(uz: "Hozir to‘lanadi", en: "Due today", ru: "Сегодня к оплате"), value: offer.price)
                    LabeledContent(ui.text(uz: "Yangilanish narxi", en: "Renewal price", ru: "Стоимость продления"), value: offer.price)
                    Text(interval(offer.billingInterval, count: offer.billingIntervalCount))
                        .foregroundStyle(.secondary)
                }
                Section(ui.text(uz: "To‘lov kartasi", en: "Payment card", ru: "Карта для оплаты")) {
                    Picker(ui.text(uz: "Karta", en: "Card", ru: "Карта"), selection: $selectedCardId) {
                        Text(ui.text(uz: "Kartani tanlang", en: "Choose a card", ru: "Выберите карту")).tag("")
                        ForEach(model.cards) { card in Text(card.maskedNumber).tag(card.id) }
                    }
                    if model.cards.isEmpty {
                        Text(ui.text(uz: "Avval Kartalar bo‘limida kartangizni qo‘shing.", en: "Add a card in Cards before subscribing.", ru: "Сначала добавьте карту в разделе «Карты»."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button { confirmsPurchase = true } label: {
                        HStack {
                            Spacer()
                            if model.isBusy { ProgressView() }
                            Text(ui.text(uz: "Obuna bo‘lish", en: "Subscribe", ru: "Оформить подписку"))
                                .font(.headline)
                            Spacer()
                        }.frame(minHeight: 44)
                    }
                    .disabled(selectedCard == nil || model.isBusy || model.pending != nil || !model.access.canPurchaseLocal)
                } footer: {
                    Text(ui.text(uz: "Obuna ko‘rsatilgan davr uchun avtomatik yangilanadi. Yangilanishni Obuna bo‘limida o‘chirishingiz mumkin.", en: "The subscription renews automatically for the displayed period. Turn off renewal in Subscription at any time.", ru: "Подписка автоматически продлевается на указанный период. Автопродление можно выключить в разделе подписки."))
                }
                if let error = model.error { Section { Text(error).font(.footnote).foregroundStyle(.secondary) } }
            }
            .navigationTitle(offer.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ui.text(uz: "Yopish", en: "Close", ru: "Закрыть")) { selectedOffer = nil }.disabled(model.isBusy)
                }
            }
            .confirmationDialog(ui.text(uz: "To‘lovni tasdiqlaysizmi?", en: "Confirm payment?", ru: "Подтвердить платёж?"), isPresented: $confirmsPurchase, titleVisibility: .visible) {
                if let card = selectedCard {
                    Button(ui.text(uz: "To‘lash: ", en: "Pay ", ru: "Оплатить ") + offer.price) {
                        Task {
                            await model.subscribe(offer: offer, card: card)
                            if model.pending != nil || model.subscription?.isCurrent == true { selectedOffer = nil }
                        }
                    }
                }
            } message: {
                Text(purchaseSummary(for: offer))
            }
            .interactiveDismissDisabled(model.isBusy)
        }
    }

    private func purchaseSummary(for offer: EchoBilling.Offer) -> String {
        let cardMask: String = selectedCard?.maskedNumber ?? ""
        let details: [String] = [offer.name, offer.price, cardMask]
        return details.joined(separator: " · ")
    }

    private func interval(_ value: String, count: Int) -> String {
        if value == "year" {
            return count == 1 ? ui.text(uz: "Har yili", en: "Every year", ru: "Ежегодно") : "\(count) " + ui.text(uz: "yilda bir marta", en: "years per period", ru: "года за период")
        }
        return count == 1 ? ui.text(uz: "Har oy", en: "Every month", ru: "Ежемесячно") : "\(count) " + ui.text(uz: "oyda bir marta", en: "months per period", ru: "месяцев за период")
    }
    private func status(_ value: String) -> String {
        switch value {
        case "active": ui.text(uz: "Faol", en: "Active", ru: "Активна")
        case "paid", "succeeded": ui.text(uz: "To‘langan", en: "Paid", ru: "Оплачено")
        case "incomplete", "pending", "processing": ui.text(uz: "Jarayonda", en: "Processing", ru: "Обрабатывается")
        case "past_due", "failed": ui.text(uz: "To‘lov yakunlanmagan", en: "Payment not completed", ru: "Платёж не завершён")
        case "canceled", "cancelled", "expired": ui.text(uz: "Tugagan", en: "Ended", ru: "Завершено")
        default: value
        }
    }
}

@MainActor @Observable
private final class EchoBillingModel {
    let service = EchoBillingService()
    var catalog: EchoBilling.CardCatalog?
    var hostedOffers: [EchoBilling.HostedOffer] = []
    var hostedPending: EchoBilling.PendingCheckout?
    var accountSubscription: EchoBilling.AccountSubscription?
    var cards: [EchoBilling.Card] = []
    var subscription: EchoBilling.Subscription?
    var payments: [EchoBilling.Payment] = []
    var pending: EchoBilling.PurchaseIntent?
    var isLoading = false
    var hasLoaded = false
    var isBusy = false
    var access = EchoBilling.Access()
    private var cardsLimit: Int?
    var error: String?
    private let accountId: String
    init(accountId: String) { self.accountId = accountId }
    var offers: [EchoBilling.Offer] { (catalog?.offers ?? []).filter { $0.planCode == "starter" && $0.billingIntervalCount == 1 && ["month", "year"].contains($0.billingInterval) }.sorted { $0.sortOrder < $1.sortOrder } }
    var maxCards: Int { min(5, max(0, cardsLimit ?? catalog?.maxCards ?? 0)) }
    var hasCurrentSubscription: Bool { subscription?.isCurrent == true || accountSubscription?.isCurrent == true }
    private var ui: EchoAppLanguage { EchoAppLanguage(rawValue: UserDefaults.standard.string(forKey: "echo.app.language") ?? "uz") ?? .uzbek }
    private var pendingKey: String { "echo.billing.pending." + accountId }

    func load() async {
        guard !isLoading else { return }
        isLoading = true; error = nil; access = EchoBilling.Access()
        defer { isLoading = false; hasLoaded = true }
        var failures: [String] = []
        do {
            let pricing = try await service.request(EchoBilling.Pricing.self, path: "/api/v1/billing/pricing")
            catalog = pricing.cardSubscriptions
            hostedOffers = pricing.subscriptionOffers.filter {
                $0.planCode == "starter" && $0.billingIntervalCount == 1 && ["month", "year"].contains($0.billingInterval) && $0.available
            }
        } catch { failures.append(ui.text(uz: "Narxlar", en: "Prices", ru: "Цены") + ": " + message(error)) }
        do {
            try await checkAccount()
            access.identityVerified = true
        } catch {
            cards = []; subscription = nil; accountSubscription = nil; payments = []; hostedPending = nil
            self.error = message(error)
            return
        }
        if pending == nil, let data = UserDefaults.standard.data(forKey: pendingKey) {
            pending = try? JSONDecoder().decode(EchoBilling.PurchaseIntent.self, from: data)
        }
        // Commit each verified response independently; unrelated history failures
        // cannot discard a successful card list or erase the public catalog.
        do {
            let reply = try await authorized(EchoBilling.CardsReply.self, path: EchoBilling.base + "/cards")
            cards = reply.cards; cardsLimit = reply.maxCards; access.cardsVerified = true
        } catch { failures.append(ui.text(uz: "Kartalar", en: "Cards", ru: "Карты") + ": " + message(error)) }
        do {
            let reply = try await authorized(EchoBilling.AccountReply.self, path: "/api/v1/account/subscription")
            accountSubscription = reply.subscription; access.accountSubscriptionVerified = true
        } catch { failures.append(ui.text(uz: "Obuna", en: "Subscription", ru: "Подписка") + ": " + message(error)) }
        do {
            let reply = try await authorized(EchoBilling.SubscriptionReply.self, path: EchoBilling.base + "/subscription")
            subscription = reply.subscription; access.cardSubscriptionVerified = true
            if let pending, let subscription, pending.serverSubscriptionId == subscription.id, !subscription.isProcessing {
                clearPending()
            }
        } catch { failures.append(ui.text(uz: "Karta obunasi", en: "Card subscription", ru: "Подписка по карте") + ": " + message(error)) }
        do {
            let reply = try await authorized(EchoBilling.PendingCheckoutReply.self, path: "/api/v1/billing/polar/checkout/pending")
            hostedPending = reply.pendingCheckout; access.pendingCheckoutVerified = true
        } catch { failures.append(ui.text(uz: "Kutilayotgan to‘lov", en: "Pending checkout", ru: "Ожидающая оплата") + ": " + message(error)) }
        do {
            let reply = try await authorized(EchoBilling.PaymentsReply.self, path: EchoBilling.base + "/payments")
            payments = reply.payments
        } catch { failures.append(ui.text(uz: "To‘lovlar tarixi", en: "Payment history", ru: "История платежей") + ": " + message(error)) }
        do { try await checkAccount() } catch {
            access = EchoBilling.Access()
            cards = []; subscription = nil; accountSubscription = nil; payments = []; hostedPending = nil
            failures = [message(error)]
        }
        self.error = failures.isEmpty ? nil : failures.joined(separator: "\n\n")
    }

    private func authorized<T: Decodable & Sendable>(_ type: T.Type, path: String) async throws -> T {
        try await checkAccount()
        let reply = try await service.request(type, path: path)
        try await checkAccount()
        return reply
    }

    func refreshHostedPending() async {
        access.pendingCheckoutVerified = false
        do {
            try await checkAccount()
            let reply = try await authorized(EchoBilling.PendingCheckoutReply.self,
                path: "/api/v1/billing/polar/checkout/pending")
            hostedPending = reply.pendingCheckout
            access.pendingCheckoutVerified = true
        } catch { self.error = message(error) }
    }

    func createHostedCheckout(_ offer: EchoBilling.HostedOffer) async -> EchoBilling.HostedCheckout? {
        guard !isBusy, access.canPurchaseHosted, pending == nil, hostedPending == nil, !hasCurrentSubscription, offer.available else { return nil }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            try await checkAccount()
            let result = try await service.request(EchoBilling.HostedCheckout.self,
                path: "/api/v1/billing/polar/checkout", method: "POST",
                body: EchoBilling.body(EchoBilling.HostedCheckoutBody(code: offer.packageCode)))
            guard result.url != nil else { throw EchoAuthError.invalidResponse }
            return result
        } catch {
            // Creating a checkout is never automatically retried. Only the provider
            // can confirm payment; dismissal/redirect always refreshes server state.
            if case EchoAuthError.server(409) = error {
                await refreshHostedPending()
                if hostedPending != nil { self.error = nil } else { self.error = message(error) }
            } else {
                self.error = message(error)
            }
            return nil
        }
    }

    func subscribe(offer: EchoBilling.Offer, card: EchoBilling.Card) async {
        guard !isBusy, access.canPurchaseLocal, pending == nil, !hasCurrentSubscription, offer.purchasable else { return }
        let intent = EchoBilling.PurchaseIntent(offer: offer, card: card)
        pending = intent
        savePending()
        await submitPending(intent)
    }
    func checkPendingPayment() async {
        guard !isBusy else { return }
        guard let pending else { await load(); return }
        guard pending.canRetry else {
            await load()
            if self.pending != nil {
                error = ui.text(uz: "Natija hali tasdiqlanmagan. Qayta to‘lamang; yordam uchun info@voicelab.uz bilan bog‘laning.", en: "The result is still unconfirmed. Do not pay again; contact info@voicelab.uz for help.", ru: "Результат ещё не подтверждён. Не оплачивайте повторно; свяжитесь с info@voicelab.uz.")
            }
            return
        }
        await submitPending(pending)
    }
    private func submitPending(_ intent: EchoBilling.PurchaseIntent) async {
        guard !isBusy else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            try await checkAccount()
            let reply = try await service.request(EchoBilling.SubscriptionReply.self, path: EchoBilling.base + "/subscription",
                                                  method: "POST", body: EchoBilling.purchaseBody(intent), key: intent.idempotencyKey)
            guard let subscription = reply.subscription else { throw EchoAuthError.invalidResponse }
            self.subscription = subscription
            if subscription.isProcessing {
                pending?.serverSubscriptionId = subscription.id
                savePending()
            } else {
                clearPending()
            }
            await load()
        } catch {
            // A timeout, cancellation, 202/incomplete or 409 in-progress never creates
            // another purchase identity. The user can check this same operation.
            if let failure = error as? EchoAuthError {
                switch failure {
                case .server(400), .server(402), .server(422): clearPending()
                default: break
                }
            }
            self.error = message(error)
        }
    }
    func makeDefault(_ card: EchoBilling.Card) async { await mutate(path: "/cards/\(card.id)/default", method: "POST", body: Data("{}".utf8)) }
    func removeCard(_ card: EchoBilling.Card) async {
        guard !card.inUse else { return }
        await mutate(path: "/cards/\(card.id)", method: "DELETE")
    }
    func setRenewal(_ enabled: Bool) async {
        await mutate(path: "/subscription", method: enabled ? "PATCH" : "DELETE",
                     body: enabled ? Data(#"{"cancel_at_period_end":false}"#.utf8) : nil)
    }
    private func mutate(path: String, method: String, body: Data? = nil) async {
        guard !isBusy, pending == nil else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            try await checkAccount()
            try await service.mutate(path: EchoBilling.base + path, method: method, body: body)
            await load()
        } catch { self.error = message(error) }
    }
    private func checkAccount() async throws {
        guard try await EchoAuthClient.shared.restore()?.id == accountId else { throw EchoAuthError.signedOut }
    }
    private func savePending() {
        guard let pending, let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: pendingKey)
    }
    private func clearPending() {
        pending = nil
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }
    private func message(_ error: Error) -> String {
        if let failure = error as? EchoAuthError {
            switch failure {
            case .server(401), .signedOut:
                return ui.text(uz: "To‘lovlarni boshqarish uchun hisobga qayta kiring.", en: "Sign in again to manage billing.", ru: "Войдите снова для управления оплатой.")
            case .server(403):
                return ui.text(uz: "Obunani ish maydoni egasi boshqaradi. Avval hisob sozlashni tugating.", en: "Billing is managed by the workspace owner. Complete account setup first.", ru: "Оплатой управляет владелец рабочего пространства. Сначала завершите настройку аккаунта.")
            case .server(402):
                return ui.text(uz: "Karta to‘lovni bajara olmadi. Balans yoki kartani tekshiring.", en: "The card payment was declined. Check your balance or card.", ru: "Платёж по карте отклонён. Проверьте баланс или карту.")
            case .server(409):
                return ui.text(uz: "Holat o‘zgargan yoki to‘lov hali tekshirilmoqda. Natijani yangilang.", en: "The state changed or payment is still being checked. Refresh the result.", ru: "Состояние изменилось или платёж проверяется. Обновите результат.")
            case .server(422):
                return ui.text(uz: "Ma’lumot yoki narxni tekshiring va qayta urinib ko‘ring.", en: "Check the details and current price, then try again.", ru: "Проверьте данные и текущую цену, затем повторите.")
            case .server(429):
                return ui.text(uz: "Juda ko‘p urinish. Biroz kutib qayta urinib ko‘ring.", en: "Too many attempts. Wait a moment and try again.", ru: "Слишком много попыток. Подождите и повторите.")
            default: break
            }
        }
        return ui.text(uz: "Amal yakunlanganini tekshirib bo‘lmadi. Internet aloqasini tekshiring va holatni yangilang.", en: "Could not confirm the result. Check your connection and refresh the status.", ru: "Не удалось подтвердить результат. Проверьте подключение и обновите статус.")
    }
}

private struct EchoAddCardView: View {
    let service: EchoBillingService
    let ui: EchoAppLanguage
    let onAdded: (EchoBilling.Card) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var expiry = ""
    @State private var phone = ""
    @State private var otp = ""
    @State private var enrollment: EchoBilling.Enrollment?
    @State private var isBusy = false
    @State private var error: String?
    @FocusState private var focused: Field?
    private enum Field { case number, expiry, phone, otp }

    private var validPhone: Bool {
        let digits = EchoBilling.digits(phone)
        return digits.isEmpty || digits.count == 12 && digits.hasPrefix("998")
    }
    private var canContinue: Bool {
        if enrollment != nil { return (4...8).contains(EchoBilling.digits(otp).count) }
        return EchoBilling.validCard(number) && EchoBilling.expiry(expiry) != nil && validPhone
    }
    var body: some View {
        NavigationStack {
            Form {
                if let enrollment {
                    Section {
                        MobileLabel(ui.text(uz: "SMS kodini kiriting", en: "Enter the SMS code", ru: "Введите SMS-код"), systemImage: "message")
                        Text(enrollment.phoneHint).font(.subheadline).foregroundStyle(.secondary)
                        SecureField(ui.text(uz: "Tasdiqlash kodi", en: "Verification code", ru: "Код подтверждения"), text: $otp)
                            .textContentType(.oneTimeCode).keyboardType(.numberPad).focused($focused, equals: .otp)
                            .onChange(of: otp) { _, value in otp = String(EchoBilling.digits(value).prefix(8)) }
                        Text(ui.text(uz: "Kod amal qiladi: ", en: "Code expires: ", ru: "Код действует до: ") + EchoBilling.date(enrollment.expiresAt))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        TextField(ui.text(uz: "Karta raqami", en: "Card number", ru: "Номер карты"), text: $number)
                            .keyboardType(.numberPad).textContentType(.creditCardNumber).focused($focused, equals: .number)
                            .onChange(of: number) { _, value in number = String(EchoBilling.digits(value).prefix(16)) }
                        TextField("MM/YY", text: $expiry)
                            .keyboardType(.numberPad).focused($focused, equals: .expiry)
                            .onChange(of: expiry) { _, value in
                                let digits = String(EchoBilling.digits(value).prefix(4))
                                expiry = digits.count > 2 ? String(digits.prefix(2)) + "/" + digits.dropFirst(2) : digits
                            }
                        TextField(ui.text(uz: "Telefon (ixtiyoriy)", en: "Phone (optional)", ru: "Телефон (необязательно)"), text: $phone)
                            .keyboardType(.phonePad).textContentType(.telephoneNumber).focused($focused, equals: .phone)
                    } header: {
                        Text("Uzcard / Humo")
                    } footer: {
                        Text(ui.text(uz: "Telefonni +998 formatida kiriting. Kartani qo‘shish to‘lov yaratmaydi; kartani SMS orqali tasdiqlaysiz.", en: "Use +998 for the phone number. Adding a card does not buy a subscription; you’ll verify the card by SMS.", ru: "Укажите телефон в формате +998. Добавление карты не покупает подписку; подтвердите карту по SMS."))
                    }
                }
                Section {
                    Button { Task { await submit() } } label: {
                        HStack {
                            Spacer()
                            if isBusy { ProgressView() }
                            Text(enrollment == nil ? ui.text(uz: "SMS kodini olish", en: "Get SMS code", ru: "Получить SMS-код") : ui.text(uz: "Kartani tasdiqlash", en: "Verify card", ru: "Подтвердить карту"))
                            Spacer()
                        }.frame(minHeight: 44)
                    }.disabled(isBusy || !canContinue)
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle(ui.text(uz: "Karta qo‘shish", en: "Add card", ru: "Добавить карту"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ui.text(uz: "Bekor qilish", en: "Cancel", ru: "Отмена")) { clearSensitive(); dismiss() }.disabled(isBusy)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(ui.text(uz: "Tayyor", en: "Done", ru: "Готово")) { focused = nil }
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
        .onDisappear { clearSensitive() }
    }
    private func submit() async {
        guard !isBusy, canContinue else { return }
        isBusy = true; error = nil; focused = nil
        defer { isBusy = false }
        do {
            if let enrollment {
                struct Confirm: Encodable { let otp: String }
                let reply = try await service.request(EchoBilling.CardReply.self,
                    path: EchoBilling.base + "/cards/\(enrollment.enrollmentId)/confirm", method: "POST",
                    body: EchoBilling.body(Confirm(otp: EchoBilling.digits(otp))))
                clearSensitive(); onAdded(reply.card); dismiss()
            } else {
                guard let apiExpiry = EchoBilling.expiry(expiry) else { return }
                struct Start: Encodable { let cardNumber: String; let expireDate: String; let phoneNumber: String }
                let digits = EchoBilling.digits(phone)
                let reply = try await service.request(EchoBilling.EnrollmentReply.self, path: EchoBilling.base + "/cards", method: "POST",
                    body: EchoBilling.body(Start(cardNumber: EchoBilling.digits(number), expireDate: apiExpiry,
                                                 phoneNumber: digits.isEmpty ? "" : "+" + digits)))
                clearSensitive(); enrollment = reply.enrollment; focused = .otp
            }
        } catch {
            // Do not surface request/response dumps containing card or OTP values.
            self.error = ui.text(uz: "Karta yoki SMS kodini tekshiring. Kod eskirgan bo‘lsa, kartani qayta qo‘shing.", en: "Check the card or SMS code. If the code expired, close this sheet and add the card again.", ru: "Проверьте карту или SMS-код. Если код истёк, закройте окно и добавьте карту снова.")
            otp = ""
        }
    }
    private func clearSensitive() { number = ""; expiry = ""; phone = ""; otp = "" }
}

private struct EchoBillingSafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
