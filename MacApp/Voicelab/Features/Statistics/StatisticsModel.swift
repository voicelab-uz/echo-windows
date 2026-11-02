import Foundation
import Observation
import VoiceLabCore

@MainActor @Observable
final class StatisticsModel {
    private(set) var localRows: [StatisticsDay] = []
    private(set) var localApplications: [DesktopUsageDay] = []
    private(set) var remote: DictationStatistics?
    private(set) var isLoading = false
    private(set) var refreshFailed = false
    @ObservationIgnored private let api: (any StatisticsServing)?
    @ObservationIgnored private var owner: String?
    @ObservationIgnored private var lastAttempt = Date.distantPast
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var localGeneration = UUID()
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var task: Task<Void, Never>?
    init(api: (any StatisticsServing)?) { self.api = api }
    deinit { task?.cancel() }
    func reset() {
        generation = UUID()
        task?.cancel()
        task = nil
        localGeneration = UUID()
        localRows = []
        localApplications = []
        refreshAgain = false
        remote = nil
        owner = nil
        isLoading = false
        refreshFailed = false
        lastAttempt = .distantPast
    }
    func updateLocal(_ records: [Transcript], accountID: String) async {
        if owner != accountID {
            reset()
            owner = accountID
        }
        let version = UUID()
        localGeneration = version
        let rows = await Task.detached(priority: .utility) {
            (StatisticsSummary.localRows(records), DesktopUsageSummary.localRows(records))
        }.value
        guard owner == accountID, version == localGeneration else { return }
        localRows = rows.0
        localApplications = rows.1
    }
    func refresh(accountID: String, force: Bool = false) async {
        if owner != accountID {
            reset()
            owner = accountID
        }
        if let task {
            if force { refreshAgain = true }
            await task.value
            return
        }
        guard let api, force || Date.now.timeIntervalSince(lastAttempt) >= 30 else { return }
        let current = generation
        lastAttempt = .now
        isLoading = true
        let task = Task { [weak self] in
            repeat {
                self?.refreshAgain = false
                do {
                    let result = try await api.statistics(
                        accountID: accountID, timeZone: TimeZone.current.identifier)
                    guard let self, self.generation == current, !Task.isCancelled else { return }
                    self.remote = result
                    self.refreshFailed = false
                } catch {
                    guard let self, self.generation == current, !Task.isCancelled else { return }
                    self.refreshFailed = true
                    self.refreshAgain = false
                }
            } while self?.refreshAgain == true && self?.generation == current
            guard let self, self.generation == current else { return }
            self.task = nil
            self.isLoading = false
        }
        self.task = task
        await task.value
    }
}
