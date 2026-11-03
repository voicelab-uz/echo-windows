import SwiftUI
import VoiceLabCore

struct StatisticsView: View {
    let app: AppModel
    @State private var now = Date.now
    @State private var showsSource = false
    @State private var isVisible = false
    /// The typing speed time saved is measured against; editable from the Time saved card.
    @AppStorage("typingWordsPerMinute") private var typingSpeed = 40
    @State private var editsTypingSpeed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Charts follow the app's accent (VoiceLab, macOS, or a chosen color), like every other page.
    private var chartTint: Color { Design.tint }

    private var rows: [StatisticsDay] {
        app.statistics.remote?.days ?? app.statistics.localRows
    }
    private var summary: StatisticsSummary { StatisticsSummary(rows: rows, period: 182, now: now) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heading.padding(.bottom, 16)
                        .modifier(StatisticsEntrance(isVisible: isVisible, order: 0))
                    let data = summary
                    let usage = DesktopUsageSummary(
                        rows: usageRows,
                        validDays: Set(
                            data.days.map { StatisticsSummary.dayKey($0.date, calendar: .current) }))
                    if geometry.size.width >= 850 {
                        // The first two cards together align with the left chart below.
                        HStack(spacing: 24) {
                            HStack(spacing: 24) {
                                speed(data)
                                recordings(data)
                            }.frame(maxWidth: .infinity)
                            words(data).frame(maxWidth: .infinity)
                        }
                        savings(data)
                        HStack(alignment: .top, spacing: 24) {
                            desktopUsage(usage)
                            activity(data, usage: usage)
                        }
                        sourceBreakdown
                    } else {
                        HStack(spacing: 16) {
                            speed(data)
                            recordings(data)
                        }
                        words(data)
                        savings(data)
                        sourceBreakdown
                        desktopUsage(usage)
                        activity(data, usage: usage)
                    }
                }
                .padding(geometry.size.width >= 900 ? 40 : 24)
                .frame(maxWidth: 1280).frame(maxWidth: .infinity)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: app.account?.id) { await refresh() }
        .onChange(of: app.library.usageRevision) { _, _ in Task { await refresh(force: true) } }
        .onChange(of: app.library.snapshot.transcripts) { _, _ in Task { await refresh(force: true) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
            _ in
            Task { await refresh() }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 12) {
                Text(AppLocalization.text("Statistika"))
                    .font(.system(size: 27, weight: .semibold)).tracking(-0.5)
                Spacer()
                if app.statistics.isLoading { ProgressView().controlSize(.small) }
                Button {
                    showsSource.toggle()
                } label: {
                    Image(systemName: "info.circle").font(.system(size: 16))
                        .foregroundStyle(.secondary).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.text("Ma’lumotlar haqida"))
                .popover(isPresented: $showsSource) { sourceNotice.padding(18).frame(width: 300) }
            }
            HStack {
                Text(AppLocalization.text("Foydalanish"))
                    .font(.system(size: 14, weight: .medium))
                    .padding(.bottom, 14)
                    .overlay(alignment: .bottom) { Rectangle().fill(chartTint).frame(height: 2) }
                Spacer()
                Text(AppLocalization.text(app.statistics.remote == nil ? "Lokal tarix · 6 oy" : "6 oy"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 14)
            }
            .background(alignment: .bottom) { Rectangle().fill(Design.border).frame(height: 1) }
        }
    }

    private func card<Content: View>(height: CGFloat, order: Int, @ViewBuilder content: () -> Content)
        -> some View
    {
        content().frame(maxWidth: .infinity, alignment: .topLeading).frame(height: height, alignment: .top)
            .padding(18)
            .background(Design.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Design.border, lineWidth: 1))
            .modifier(StatisticsEntrance(isVisible: isVisible, order: order))
    }

    private func number(_ value: String, title: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(value).font(.system(size: 30, weight: .medium)).monospacedDigit()
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: value)
            Text(AppLocalization.text(title))
                .font(.system(size: 11, weight: .medium)).tracking(0.7)
                .foregroundStyle(.secondary).textCase(.uppercase)
                .lineLimit(2)
        }.accessibilityElement(children: .combine)
    }

    private func caption(_ title: String) -> some View {
        Text(AppLocalization.text(title))
            .font(.system(size: 11, weight: .medium)).tracking(0.7)
            .foregroundStyle(.secondary).textCase(.uppercase).lineLimit(1)
    }

    /// The speed sits inside its own half-circle gauge, so the card has no empty corner.
    private func speed(_ data: StatisticsSummary) -> some View {
        let value = data.wordsPerMinute.map { String(Int($0.rounded())) } ?? "—"
        let progress = (isVisible || reduceMotion) ? min(1, max(0, (data.wordsPerMinute ?? 0) / 200)) : 0
        return card(height: 150, order: 1) {
            VStack(spacing: 8) {
                caption("So‘z / daqiqa").frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: .bottom) {
                    StatisticsSpeedArc().stroke(Design.selection, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    StatisticsSpeedArc().trim(from: 0, to: progress)
                        .stroke(chartTint, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.65), value: progress)
                    Text(value).font(.system(size: 26, weight: .medium)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                }
                .frame(height: 72).padding(.horizontal, 10)
                HStack { Text("0"); Spacer(); Text("200+") }
                    .font(.system(size: 10)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
        }.help(AppLocalization.text("Yozuv vaqti bo‘yicha o‘rtacha"))
    }

    private func recordings(_ data: StatisticsSummary) -> some View {
        card(height: 150, order: 2) {
            VStack(alignment: .leading, spacing: 20) {
                number(data.recordings.formatted(), title: "Yozuvlar")
                Divider()
                Text(AppLocalization.text("%d faol kun", data.activeDays))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    /// The total on the left; the last seven days fill the right instead of empty space.
    private func words(_ data: StatisticsSummary) -> some View {
        card(height: 150, order: 3) {
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 20) {
                    number(data.words.formatted(), title: "Yozilgan so‘zlar")
                    Spacer(minLength: 0)
                    Label("Echo", systemImage: "desktopcomputer")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                StatisticsWeekBars(days: Array(data.days.suffix(7)), tint: chartTint, isVisible: isVisible || reduceMotion)
                    .frame(maxWidth: 260)
            }
        }
    }

    // MARK: Time saved

    /// Seconds saved: how long typing the words would take, minus the time spent speaking.
    private func secondsSaved(words: Int, durationMs: Int) -> Double {
        let speed = Double(min(200, max(10, typingSpeed)))
        return max(0, Double(words) / speed * 60 - Double(durationMs) / 1000)
    }

    /// "4h 20m", "12m", or "< 1m", in the interface language.
    private static func formatSaved(_ seconds: Double) -> String {
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .narrow)
            .locale(AppLocalization.shared.language.locale)
        guard seconds >= 60 else { return "< " + Duration.seconds(60).formatted(style) }
        return Duration.seconds(Int(seconds)).formatted(style)
    }

    private var todayRows: [StatisticsDay] {
        let key = StatisticsSummary.dayKey(Calendar.current.startOfDay(for: now), calendar: .current)
        return rows.filter { $0.day == key }
    }

    /// Time saved, today and average length in one strip of three, divided like a table.
    private func savings(_ data: StatisticsSummary) -> some View {
        let rows = todayRows
        let todayWords = rows.reduce(0) { $0 + $1.words }
        let todayRecordings = rows.reduce(0) { $0 + $1.recordings }
        let todaySaved = secondsSaved(words: todayWords, durationMs: rows.reduce(0) { $0 + $1.durationMs })
        let average = data.recordings > 0 ? Int((Double(data.words) / Double(data.recordings)).rounded()) : nil
        return card(height: 92, order: 4) {
            HStack(spacing: 0) {
                strip(Self.formatSaved(secondsSaved(words: data.words, durationMs: data.durationMs)),
                      title: "Tejalgan vaqt",
                      detail: AppLocalization.text("%d so‘z/daqiqa yozish tezligiga nisbatan", typingSpeed),
                      tint: chartTint, editDetail: { editsTypingSpeed = true })
                    .popover(isPresented: $editsTypingSpeed, arrowEdge: .bottom) { typingSpeedEditor }
                Divider().padding(.horizontal, 18)
                strip(todayWords.formatted(), title: "Bugungi so‘zlar",
                      detail: AppLocalization.text("%d ta yozuv · %@ tejaldi", todayRecordings, Self.formatSaved(todaySaved)))
                Divider().padding(.horizontal, 18)
                strip(average.map { $0.formatted() } ?? "—", title: "O‘rtacha uzunlik",
                      detail: AppLocalization.text("Har bir yozuvdagi so‘zlar"))
            }
        }
    }

    /// Pick the typing speed time saved is compared with (10–200 words per minute).
    private var typingSpeedEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.text("Yozish tezligingiz")).font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                TextField("", value: $typingSpeed, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 64).monospacedDigit()
                    .onSubmit { typingSpeed = min(200, max(10, typingSpeed)) }
                Stepper("", value: $typingSpeed, in: 10...200, step: 5).labelsHidden()
                Text(AppLocalization.text("So‘z / daqiqa")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(AppLocalization.text("Vaqt shu tezlikka nisbatan hisoblanadi."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(width: 260)
        .onDisappear { typingSpeed = min(200, max(10, typingSpeed)) }
    }

    private func strip(_ value: String, title: String, detail: String, tint: Color? = nil,
                       editDetail: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.system(size: 24, weight: .medium)).monospacedDigit()
                    .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                    .lineLimit(1).minimumScaleFactor(0.6)
                caption(title)
            }
            if let editDetail {
                Button(action: editDetail) {
                    HStack(spacing: 5) {
                        Text(detail).lineLimit(1).minimumScaleFactor(0.8)
                        WorkspaceAssetIcon(name: .edit, size: 11)
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(AppLocalization.text("Yozish tezligingiz"))
            } else {
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var usageRows: [DesktopUsageDay] {
        // Do not add local events to a server aggregate: a response may have been
        // lost after commit. Prefer local attribution until its outbox settles.
        if !(app.library.snapshot.pendingUsage ?? [:]).isEmpty { return app.statistics.localApplications }
        return app.statistics.remote?.applications ?? app.statistics.localApplications
    }

    private var sourceBreakdown: some View {
        // Current servers send the device split separately in `platform_days`; older ones put
        // a platform on each day row. Local history (server not reached) has only this Mac.
        let split = app.statistics.remote?.platformDays ?? rows
        let desktop = split.filter { $0.platform != "ios" }.reduce(0) { $0 + $1.recordings }
        let mobile = split.filter { $0.platform == "ios" }.reduce(0) { $0 + $1.recordings }
        return card(height: 104, order: 4) {
            HStack {
                number(desktop.formatted(), title: "Mac")
                Divider()
                number(mobile.formatted(), title: "iPhone")
            }
        }
    }

    private func desktopUsage(_ usage: DesktopUsageSummary) -> some View {
        card(height: 360, order: 4) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    Text(AppLocalization.text("Desktop usage"))
                        .font(.system(size: 23, weight: .semibold)).tracking(-0.4)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    Text(AppLocalization.text("%d ta ilova", usage.apps.count))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                VStack(spacing: 14) {
                    ForEach(usage.categories) { category in
                        let ratio =
                            usage.recordings > 0 ? Double(category.recordings) / Double(usage.recordings) : 0
                        let progress = (isVisible || reduceMotion) ? ratio : 0
                        HStack(spacing: 12) {
                            Image(systemName: category.id.symbol)
                                .font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 22)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4).fill(chartTint.opacity(0.10))
                                    RoundedRectangle(cornerRadius: 4).fill(chartTint.opacity(0.65))
                                        .frame(width: geometry.size.width * progress)
                                        .animation(
                                            reduceMotion ? nil : .easeInOut(duration: 0.65), value: progress)
                                    Text(ratio, format: .percent.precision(.fractionLength(0)))
                                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                        .padding(.horizontal, 8)
                                }
                            }.frame(height: 30)
                            Text("\(category.recordings) " + AppLocalization.text(category.id.title))
                                .font(.system(size: 11, weight: .medium)).lineLimit(2)
                                .frame(width: 132, alignment: .leading)
                        }.accessibilityElement(children: .combine)
                    }
                }
                if usage.recordings == 0 {
                    Text(
                        AppLocalization.text("Yangi diktovkalarda ishlatilgan ilovalar shu yerda ko‘rinadi.")
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func activity(_ data: StatisticsSummary, usage: DesktopUsageSummary) -> some View {
        card(height: 360, order: 5) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    Text(AppLocalization.text("%d kun ketma-ket", data.currentStreak))
                        .font(.system(size: 23, weight: .semibold)).tracking(-0.4)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    Text(AppLocalization.text("Eng uzun: %d kun", data.longestStreak))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                StatisticsHeatmap(days: data.days, usage: usage, tint: chartTint)
                HStack(spacing: 6) {
                    Text(AppLocalization.text("Kam"))
                    ForEach([0.08, 0.25, 0.5, 0.75, 1.0], id: \.self) { opacity in
                        RoundedRectangle(cornerRadius: 2).fill(chartTint.opacity(opacity)).frame(
                            width: 12, height: 12)
                    }
                    Text(AppLocalization.text("Ko‘p"))
                }.font(.system(size: 10)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
    }

    private var sourceNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                AppLocalization.text(
                    app.statistics.remote == nil
                        ? "Shu Mac’da yuklangan tarix asosida. To‘liq tarix yuklanmagan bo‘lishi mumkin."
                        : "Hisobingizdagi saqlangan yozuvlar asosida. O‘chirilgan yozuvlar hisoblanmaydi."))
            Text(
                AppLocalization.text(
                    "Ilovalar faqat ularga matn yuborilgan diktovkalarda hisoblanadi. Eski yozuvlar uchun ilova noma’lum."
                ))
            if !(app.library.snapshot.pendingUsage ?? [:]).isEmpty {
                Text(
                    AppLocalization.text("Ilovalar statistikasi hozir shu Mac’dagi tarixdan ko‘rsatilmoqda."))
            }
            if app.statistics.refreshFailed {
                Text(
                    AppLocalization.text("Yangilash amalga oshmadi. Oxirgi olingan ma’lumot ko‘rsatilmoqda."))
                Button(AppLocalization.text("Qayta urinish")) { Task { await refresh(force: true) } }
                    .disabled(app.statistics.isLoading)
            }
        }.font(.system(size: 12)).foregroundStyle(.secondary)
    }

    private func refresh(force: Bool = false) async {
        now = .now
        guard let owner = app.account?.id, !app.needsSignIn else { return }
        await app.statistics.updateLocal(app.library.snapshot.transcripts, accountID: owner)
        guard app.account?.id == owner, !app.needsSignIn else { return }
        await app.statistics.refresh(accountID: owner, force: force)
    }
}

/// Animate presentation only; layout changes and data refreshes never replay the entrance.
private struct StatisticsEntrance: ViewModifier {
    let isVisible: Bool
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isVisible || reduceMotion ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 10)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.38).delay(Double(order) * 0.045),
                value: isVisible)
    }
}

private struct StatisticsSpeedArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Fit a true semicircle even when the metric card becomes narrow.
        let radius = min(rect.width / 2, rect.height)
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.maxY), radius: radius,
            startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        return path
    }
}

extension DesktopUsageContext.Category {
    var title: String {
        switch self {
        case .personal: "Shaxsiy xabarlar"
        case .other: "Boshqa vazifalar"
        case .ai: "AI so‘rovlari"
        case .email: "Email"
        case .work: "Ish xabarlari"
        case .documents: "Hujjatlar"
        }
    }
    var symbol: String {
        switch self {
        case .personal: "message"
        case .other: "infinity"
        case .ai: "sparkles"
        case .email: "envelope"
        case .work: "bubble.left.and.text.bubble.right"
        case .documents: "doc.text"
        }
    }
}

/// Seven slim bars for the last week's words, with weekday initials underneath.
private struct StatisticsWeekBars: View {
    let days: [StatisticsSummary.Day]
    let tint: Color
    let isVisible: Bool

    var body: some View {
        let peak = max(1, days.map(\.words).max() ?? 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    GeometryReader { geometry in
                        let fraction = isVisible ? CGFloat(day.words) / CGFloat(peak) : 0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(day.words > 0 ? tint.opacity(Calendar.current.isDateInToday(day.date) ? 1 : 0.55)
                                                : Color.primary.opacity(0.08))
                            .frame(height: max(4, geometry.size.height * fraction))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .animation(.easeOut(duration: 0.6), value: fraction)
                    }
                    Text(day.date, format: .dateTime.weekday(.narrow).locale(AppLocalization.shared.language.locale))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .help("\(day.words)")
            }
        }
        .accessibilityHidden(true)
    }
}
