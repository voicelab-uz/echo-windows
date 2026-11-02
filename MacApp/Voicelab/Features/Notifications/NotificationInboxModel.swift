import Foundation
import Observation
import VoiceLabCore

@MainActor @Observable
final class NotificationInboxModel {
    private(set) var items: [InboxNotification] = []
    private(set) var unread = 0
    private(set) var isLoading = false
    private(set) var isMarkingRead = false
    private(set) var error: String?
    private(set) var nextCursor = ""
    @ObservationIgnored var onOpen: ((PushRoute) -> Void)?
    @ObservationIgnored private let api: any NotificationInboxServing
    @ObservationIgnored private var owner: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var paginationTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var lastAttempt = Date.distantPast
    @ObservationIgnored private var throughCursor = ""

    init(api: any NotificationInboxServing) { self.api = api }
    deinit { refreshTask?.cancel(); paginationTask?.cancel(); readTask?.cancel() }
    func activate(accountID: String) {
        if owner != accountID { deactivate(); owner = accountID }
        Task { await refresh() }
    }
    func deactivate() {
        generation = UUID()
        refreshTask?.cancel(); refreshTask = nil
        paginationTask?.cancel(); paginationTask = nil
        readTask?.cancel(); readTask = nil
        items = []; unread = 0; owner = nil; nextCursor = ""; throughCursor = ""
        isLoading = false; isMarkingRead = false; error = nil
        lastAttempt = .distantPast; refreshAgain = false
    }
    func refresh(force: Bool = false) async {
        let entryGeneration = generation
        if let paginationTask { await paginationTask.value }
        guard entryGeneration == generation else { return }
        if let task = refreshTask {
            if force { refreshAgain = true }
            await task.value
            return
        }
        guard let owner, force || Date.now.timeIntervalSince(lastAttempt) >= 20 else { return }
        let current = generation
        let task = Task { [weak self, api] in
            guard let self else { return }
            repeat {
                self.refreshAgain = false
                self.lastAttempt = .now
                self.isLoading = true
                do {
                    let page = try await api.notifications(cursor: "", accountID: owner)
                    guard current == self.generation, !Task.isCancelled else { return }
                    // Restart pagination at the new server snapshot. Merging old pages can
                    // skip unseen messages when more than one page arrived between refreshes.
                    self.items = page.items
                    self.nextCursor = page.nextCursor
                    self.throughCursor = page.throughCursor
                    self.unread = page.unread
                    self.error = nil
                } catch {
                    guard current == self.generation, !Task.isCancelled else { return }
                    self.error = AppLocalization.text("Bildirishnomalarni yuklab bo‘lmadi.")
                    self.refreshAgain = false
                }
            } while self.refreshAgain && current == self.generation
            guard current == self.generation else { return }
            self.isLoading = false
            self.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }
    func loadMore() async {
        guard !isLoading, let owner, !nextCursor.isEmpty else { return }
        isLoading = true
        let current = generation
        let cursor = nextCursor
        let task = Task { [weak self, api] in
            guard let self else { return }
            defer {
                if current == self.generation { self.isLoading = false; self.paginationTask = nil }
            }
            do {
                let page = try await api.notifications(cursor: cursor, accountID: owner)
                guard current == self.generation, !Task.isCancelled else { return }
                let ids = Set(self.items.map(\.id))
                self.items.append(contentsOf: page.items.filter { !ids.contains($0.id) })
                self.nextCursor = page.nextCursor; self.unread = page.unread; self.error = nil
            } catch {
                guard current == self.generation, !Task.isCancelled else { return }
                self.error = AppLocalization.text("Bildirishnomalarni yuklab bo‘lmadi.")
            }
        }
        paginationTask = task
        await task.value
    }

    func open(_ item: InboxNotification) {
        guard let owner, let route = PushRoute(userInfo: ["account_id": owner, "destination": item.destination, "category": item.category.rawValue]) else { return }
        onOpen?(route)
        if !item.read { Task { await markRead(id: item.id) } }
    }
    func markRead(id: String? = nil) async {
        let current = generation
        // Clicks on separate messages must not be lost while another read is saving.
        if let readTask { await readTask.value }
        guard current == generation, let owner, id != nil || !throughCursor.isEmpty else { return }
        if readTask != nil { await markRead(id: id); return }
        isMarkingRead = true
        let boundary = throughCursor
        let visibleIDs = Set(items.map(\.id))
        let task = Task { [weak self, api] in
            guard let self else { return }
            defer {
                if current == self.generation { self.isMarkingRead = false; self.readTask = nil }
            }
            do {
                try await api.readNotification(id: id, throughCursor: id == nil ? boundary : nil, accountID: owner)
                guard current == self.generation, !Task.isCancelled else { return }
                for i in self.items.indices where id == self.items[i].id || (id == nil && visibleIDs.contains(self.items[i].id)) {
                    if !self.items[i].read { self.unread = max(0, self.unread - 1) }
                    self.items[i].read = true
                }
                await self.refresh(force: true)
            } catch {
                guard current == self.generation, !Task.isCancelled else { return }
                self.error = AppLocalization.text("Bildirishnoma holatini saqlab bo‘lmadi.")
            }
        }
        readTask = task
        await task.value
    }
}
