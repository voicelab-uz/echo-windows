import SwiftUI
import VoiceLabCore

struct StatisticsHeatmap: View {
    let days: [StatisticsSummary.Day]
    let usage: DesktopUsageSummary
    let tint: Color
    private var calendar: Calendar {
        var value = Calendar.current
        value.locale = AppLocalization.shared.language.locale
        return value
    }
    private var leading: Int {
        guard let first = days.first else { return 0 }
        return (calendar.component(.weekday, from: first.date) - calendar.firstWeekday + 7) % 7
    }
    private var columns: Int { max(1, (days.count + leading + 6) / 7) }
    var body: some View {
        GeometryReader { geometry in
            let maximum = max(1, days.map(\.words).max() ?? 0)
            let cell = min(20, max(3, (geometry.size.width - 32) / CGFloat(columns) - 4))
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 4) {
                    Color.clear.frame(height: 14)
                    ForEach(0..<7) { row in
                        Text(
                            calendar.veryShortStandaloneWeekdaySymbols[
                                (calendar.firstWeekday - 1 + row) % 7]
                        )
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .frame(width: 22, height: cell)
                    }
                }.accessibilityHidden(true)
                HStack(alignment: .top, spacing: 4) {
                    ForEach(0..<columns, id: \.self) { column in
                        VStack(spacing: 4) {
                            Text(monthLabel(column)).font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize().frame(width: cell, height: 14, alignment: .leading)
                                .accessibilityHidden(true)
                            ForEach(0..<7) { row in
                                let index = column * 7 + row - leading
                                if days.indices.contains(index) {
                                    let day = days[index]
                                    StatisticsDayCell(
                                        day: day,
                                        usage: usage.days[
                                            StatisticsSummary.dayKey(day.date, calendar: calendar)],
                                        color: tint.opacity(opacity(day, maximum: maximum)), size: cell)
                                } else {
                                    Color.clear.frame(width: cell, height: cell).accessibilityHidden(true)
                                }
                            }
                        }
                    }
                }
            }
        }.frame(height: 186)
    }
    private func opacity(_ day: StatisticsSummary.Day, maximum: Int) -> Double {
        guard day.recordings > 0 else { return 0.07 }
        return 0.25 + 0.75 * sqrt(Double(day.words) / Double(maximum))
    }
    private func monthLabel(_ column: Int) -> String {
        let index = max(0, column * 7 - leading)
        guard days.indices.contains(index) else { return "" }
        let date = days[index].date
        // Leave enough room for labels; do not collide in a short seven-day view.
        guard column == 0 || (column >= 3 && calendar.component(.day, from: date) <= 7) else { return "" }
        return date.formatted(.dateTime.month(.abbreviated).locale(AppLocalization.shared.language.locale))
    }
}

private struct StatisticsDayCell: View {
    let day: StatisticsSummary.Day
    let usage: DesktopUsageSummary.Day?
    let color: Color
    let size: CGFloat
    @State private var showingDetail = false
    @State private var hoverTask: Task<Void, Never>?

    private var appCount: String {
        if let usage { return usage.apps.count.formatted() }
        return day.recordings == 0 ? "0" : "—"
    }
    private var dateTitle: String {
        day.date.formatted(.dateTime.day().month(.wide).year().locale(AppLocalization.shared.language.locale))
    }
    var body: some View {
        Button {
            showingDetail.toggle()
        } label: {
            RoundedRectangle(cornerRadius: min(3, size / 4)).fill(color).frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenDescription)
        .onHover { inside in
            hoverTask?.cancel()
            if inside {
                hoverTask = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                    showingDetail = true
                }
            } else {
                showingDetail = false
            }
        }
        .onDisappear { hoverTask?.cancel() }
        .popover(isPresented: $showingDetail, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 18) {
                Text(dateTitle).font(.system(size: 12, weight: .semibold))
                VStack(spacing: 12) {
                    detail("Jami so‘zlar", value: day.words.formatted())
                    detail("Ishlatilgan ilovalar", value: appCount)
                    detail("Eng ko‘p ishlatilgan ilova", value: usage?.topApp?.name ?? "—")
                }
            }.padding(18).frame(width: 285)
        }
    }
    private var spokenDescription: String {
        let words = AppLocalization.text("%d so‘z", day.words)
        let apps = AppLocalization.text("Ishlatilgan ilovalar") + ": " + appCount
        return [dateTitle, words, apps].joined(separator: ", ")
    }
    private func detail(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(AppLocalization.text(title)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }.font(.system(size: 12))
    }
}
