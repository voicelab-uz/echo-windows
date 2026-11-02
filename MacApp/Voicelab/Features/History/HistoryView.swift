import SwiftUI
import VoiceLabCore

struct HistoryView: View {
    let model: AppModel
    @Environment(\.dictationShortcut) private var shortcut
    /// Typed in the window toolbar's search field.
    var query = ""
    @State private var editing: Transcript?
    @State private var visibleEntry: String?

    private var items: [Transcript] {
        model.library.snapshot.transcripts.filter {
            query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    private func groups(for entries: [Transcript]) -> [HistoryDay] {
        Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.createdAt) }
            .map { HistoryDay(date: $0.key, transcripts: $0.value) }
            .sorted { $0.date > $1.date }
    }
    private var greeting: String {
        guard let name = model.account?.name.split(whereSeparator: \.isWhitespace).first else {
            return AppLocalization.text("Xush kelibsiz")
        }
        return AppLocalization.text("Salom, %@", String(name))
    }

    var body: some View {
        GeometryReader { geometry in
            let entries = items
            let days = groups(for: entries)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    heading.padding(.bottom, 28).id("history-heading")
                    overview(compact: true).padding(.bottom, 28)
                    if let result = model.dictation.result,
                        !model.preferences.retainHistory, !model.dictation.isBusy
                    {
                        Surface {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(result).font(.callout).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Spacer()
                                    Button { TextInsertion.copy(result) } label: {
                                        Label {
                                            Text(AppLocalization.text("Nusxalash"))
                                        } icon: { WorkspaceAssetIcon(name: .copy, size: 16) }
                                    }
                                }
                            }
                        }.padding(.bottom, 24)
                    }
                    Text(AppLocalization.text("So‘nggi faoliyat"))
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                        // Breathing room between the heading and the recordings container.
                        .padding(.bottom, 14)
                    if !model.preferences.retainHistory {
                        Text(AppLocalization.text(
                            "Yangi yozuvlar lokal tarixga saqlanmaydi. Serverdagi tarix akkaunt sozlamalariga bog‘liq."))
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 12)
                    }
                    if model.isLoadingHistory && entries.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).frame(height: 180)
                            .modifier(HomeCard())
                            .padding(.top, 20)
                    } else if entries.isEmpty {
                        EmptyContent(
                            symbol: query.isEmpty ? "waveform" : "magnifyingglass",
                            title: query.isEmpty
                                ? AppLocalization.text("Birinchi fikringizdan boshlang")
                                : AppLocalization.text("Yozuv topilmadi"),
                            subtitle: query.isEmpty
                                ? AppLocalization.text(
                                    "Istalgan ilovada %@ bilan yozishni boshlang. Yozuvlaringiz shu yerda paydo bo‘ladi.",
                                    shortcut.displayName)
                                : AppLocalization.text("Boshqa so‘z bilan izlab ko‘ring.")
                        )
                        .padding(.horizontal, 24).modifier(HomeCard())
                        .padding(.top, 20)
                    } else {
                        // One soft container holds every day and its separate recording cards.
                        ForEach(days) { group in
                            Text(group.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                                .padding(.top, group.id == days.first?.id ? 16 : 22).padding(.bottom, 8)
                                .accessibilityAddTraits(.isHeader)
                                // Span the full width so its strip of the container lines up with the cards.
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .modifier(HistoryContainer(first: group.id == days.first?.id, last: false))
                                .id("day-" + group.id.description)
                            ForEach(group.transcripts) { transcript in
                                HistoryRow(transcript: transcript) { editing = transcript }
                                    .modifier(HistoryCard())
                                    .modifier(HistoryContainer(
                                        first: false,
                                        last: group.id == days.last?.id && transcript.id == group.transcripts.last?.id))
                                    .id(transcript.id)
                            }
                        }
                    }
                    if model.hasMoreHistory {
                        Button(AppLocalization.text("Ko‘proq yuklash")) { Task { await model.loadHistory() } }
                            .buttonStyle(.echo)
                            .disabled(model.isLoadingHistory).frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                }
                // Rows keep their identity and stay direct scroll targets across
                // sidebar/width changes; only their trailing inset changes.
                .scrollTargetLayout()
                .padding(.horizontal, geometry.size.width >= 850 ? 32 : 24).padding(.top, 12).padding(.bottom, 32)
                .frame(maxWidth: 1320).frame(maxWidth: .infinity)
            }
            .scrollPosition(id: $visibleEntry)
        }
        .sheet(item: $editing) { transcript in TranscriptEditor(model: model, transcript: transcript) }
        .task(id: HomeOverviewInput(accountID: model.account?.id, transcripts: model.library.snapshot.transcripts)) {
            await refreshOverview()
        }
    }

    private func overview(compact: Bool) -> some View {
        HomeOverview(
            summary: StatisticsSummary(rows: model.statistics.remote?.days ?? model.statistics.localRows,
                                       period: 182),
            local: model.statistics.remote == nil, compact: compact,
            openStatistics: { model.destination = .statistics })
    }

    private func refreshOverview() async {
        guard let owner = model.account?.id, !model.needsSignIn else { return }
        await model.statistics.updateLocal(model.library.snapshot.transcripts, accountID: owner)
        guard !Task.isCancelled, model.account?.id == owner, !model.needsSignIn else { return }
        // Share the existing cache and in-flight request with the statistics page.
        await model.statistics.refresh(accountID: owner)
    }

    private var heading: some View {
        greetingLabel
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    private var greetingLabel: some View {
        Text(greeting)
            .font(.system(size: 26, weight: .semibold))
            .tracking(-0.5)
            .fixedSize(horizontal: false, vertical: true)
    }

}

private struct HomeOverviewInput: Equatable {
    let accountID: String?
    let transcripts: [Transcript]
}

private struct HomeOverview: View {
    let summary: StatisticsSummary
    let local: Bool
    let compact: Bool
    let openStatistics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppLocalization.text(local ? "Lokal tarix · 6 oy" : "6 oy"))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.bottom, compact ? 12 : 24)
            let layout = compact ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                                 : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
            layout {
                metric(summary.words.formatted(), label: AppLocalization.text("Yozilgan so‘zlar"))
                metric(summary.wordsPerMinute.map { String(Int($0.rounded())) } ?? "—",
                       label: AppLocalization.text("So‘z / daqiqa"))
                metric(summary.currentStreak.formatted(),
                       label: AppLocalization.text("Ketma-ket kunlar"))
            }
            Rectangle().fill(Design.border).frame(height: 1)
                .padding(.top, compact ? 14 : 24).padding(.bottom, compact ? 12 : 18)
            Button(action: openStatistics) {
                HStack {
                    WorkspaceAssetIcon(name: .statistics, size: 16)
                    Text(AppLocalization.text("Statistika"))
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 12))
                }.font(.system(size: 13, weight: .medium)).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(compact ? 18 : 22)
        .modifier(WorkspacePanel(radius: 18, fill: Design.surface))
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: compact ? 27 : 32, weight: .regular, design: .serif))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

/// Home's cards share the soft, outline-free group look used across Settings.
private struct HomeCard: ViewModifier {
    func body(content: Content) -> some View {
        content.background(.fill.quaternary, in: RoundedRectangle(cornerRadius: settingsGroupRadius, style: .continuous))
    }
}

@MainActor
private struct HistoryDay: Identifiable {
    let date: Date
    let transcripts: [Transcript]
    nonisolated var id: Date { date }
    var title: String {
        if Calendar.current.isDateInToday(date) { return AppLocalization.text("Bugun") }
        if Calendar.current.isDateInYesterday(date) { return AppLocalization.text("Kecha") }
        return date.formatted(
            .dateTime.day().month(.wide).year().locale(AppLocalization.shared.language.locale))
    }
}

struct TranscriptEditor: View {
    let model: AppModel
    let transcript: Transcript
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var editorID = UUID()
    @State private var saving = false
    @State private var error: String?
    init(model: AppModel, transcript: Transcript) {
        self.model = model
        self.transcript = transcript
        _text = State(initialValue: transcript.text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppLocalization.text("Matnni tahrirlash")).font(.title2.weight(.semibold))
            TextEditor(text: Binding(get: { text }, set: { value in
                guard !saving, !model.isPreparingUpdate else { return }
                text = value
                model.library.setUnsavedEdit(editorID, isDirty: value != transcript.text)
            })).disabled(saving || model.isPreparingUpdate).font(.body).padding(10).background(
                Design.surface, in: RoundedRectangle(cornerRadius: 10))
            if let error { ErrorBanner(message: error) }
            HStack {
                Text(
                    transcript.isRemote
                        ? AppLocalization.text("O‘zgarish akkauntingizga saqlanadi.")
                        : AppLocalization.text("O‘zgarish shu Mac’da saqlanadi.")
                ).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(AppLocalization.text("Bekor qilish")) {
                    model.library.setUnsavedEdit(editorID, isDirty: false)
                    dismiss()
                }.keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(AppLocalization.text("Saqlash")) {
                    saving = true
                    let submittedText = text
                    Task {
                        do {
                            try await model.saveTranscript(transcript, text: submittedText)
                            model.library.setUnsavedEdit(editorID, isDirty: false)
                            dismiss()
                        } catch { self.error = AppLocalization.error(error) }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(
                    saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 620, height: 420).interactiveDismissDisabled(saving)
        .onAppear { model.library.setUnsavedEdit(editorID, isDirty: text != transcript.text) }
        .onDisappear { model.library.setUnsavedEdit(editorID, isDirty: false) }
    }
}
