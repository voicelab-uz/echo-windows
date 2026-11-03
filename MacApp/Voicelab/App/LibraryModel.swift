import Foundation
import Observation
import VoiceLabCore

@MainActor @Observable
final class LibraryModel {
    private(set) var snapshot = LibrarySnapshot()
    private(set) var accountID: String?
    private(set) var isReady = false
    private var unsavedEditors: Set<UUID> = []
    var hasUnsavedEdits: Bool { !unsavedEditors.isEmpty }
    /// Each visible editor owns its lease, so dismissing one cannot clear another's draft.
    func setUnsavedEdit(_ editor: UUID, isDirty: Bool) {
        if isDirty { unsavedEditors.insert(editor) }
        else { unsavedEditors.remove(editor) }
    }
    private(set) var saveError: String?
    private(set) var notesSyncError: String?
    private(set) var notesSyncConflict = false
    private(set) var isSyncingNotes = false
    var pendingNotesCount: Int { snapshot.noteSync?.pending.count ?? 0 }
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let notesAPI: (any NotesServing)?
    @ObservationIgnored private let usageAPI: (any DesktopUsageServing)?
    @ObservationIgnored private var usagePoll: Task<Void, Never>?
    @ObservationIgnored private var usageTask: Task<Void, Never>?
    @ObservationIgnored private var usageRetryAt = Date.distantPast
    @ObservationIgnored private var usageFailures = 0
    private(set) var usageRevision = 0

    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var notesPoll: Task<Void, Never>?
    @ObservationIgnored private var notesDebounce: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var retryAt = Date.distantPast
    @ObservationIgnored private var failedSyncs = 0
    init(store: LibraryStore, notesAPI: (any NotesServing)? = nil, usageAPI: (any DesktopUsageServing)? = nil) {
        self.store = store
        self.notesAPI = notesAPI
        self.usageAPI = usageAPI ?? (notesAPI as? any DesktopUsageServing)
    }
    func open(accountID: String) async throws {
        stopNotesSync()
        try await flush()
        self.accountID = accountID
        snapshot = LibrarySnapshot()
        isReady = false
        let loaded = try await store.load(accountID: accountID)
        guard self.accountID == accountID else { return }
        snapshot = loaded
        var sync = snapshot.noteSync ?? NoteSyncState()
        sync.migrate(snapshot.notes)
        snapshot.noteSync = sync
        isReady = true
        resumeAfterRelaunchCancellation()
    }

    private var preparingForRelaunch = false

    /// Invalidate in-flight sync callbacks while preserving the durable local outbox.
    func prepareForRelaunch() {
        preparingForRelaunch = true
        stopNotesSync()
    }

    func resumeAfterRelaunchCancellation() {
        preparingForRelaunch = false
        guard isReady else { return }
        startNotesSync()
        if usageAPI != nil {
            usagePoll?.cancel()
            let id = generation
            usagePoll = Task { [weak self] in
                while !Task.isCancelled {
                    guard self?.generation == id else { return }
                    await self?.syncUsage()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
        }
    }
    func close() async throws {
        stopNotesSync()
        try await flush()
        accountID = nil
        snapshot = LibrarySnapshot()
        isReady = false
    }

    func restartOnboarding() async throws {
        guard isReady else { throw VoiceLabError.storage("Lokal ma’lumot hali ochilmagan.") }
        var progress = OnboardingProgress()
        // An explicit replay must ask every question, without prefilling the cloud profile.
        progress.profileLoaded = true
        saveOnboardingPracticeDraft(nil)
        saveOnboarding(progress)
        try await flush()
    }
    func merge(_ items: [Transcript]) {
        guard isReady else { return }
        var records = Dictionary(snapshot.transcripts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for var item in items {
            item.usageContext = item.usageContext ?? records[item.id]?.usageContext
            records[item.id] = item
        }
        snapshot.transcripts = records.values.sorted { $0.createdAt > $1.createdAt }
        scheduleSave()
    }
    func removeTranscript(_ id: String) {
        snapshot.transcripts.removeAll { $0.id == id }
        snapshot.pendingUsage?.removeValue(forKey: id)
        scheduleSave()
    }
    /// Queue only successful/sent dictation destinations. Metadata sync must never
    /// delay insertion or show an audio/auth error when the optional endpoint is absent.
    func recordUsage(_ context: DesktopUsageContext, transcript: Transcript, owner: String) {
        guard isReady, accountID == owner else { return }
        if let index = snapshot.transcripts.firstIndex(where: { $0.id == transcript.id }) {
            snapshot.transcripts[index].usageContext = context
        }
        if transcript.isRemote {
            if snapshot.pendingUsage == nil { snapshot.pendingUsage = [:] }
            snapshot.pendingUsage?[transcript.id] = context
        }
        usageRevision += 1
        scheduleSave()
        Task { [weak self] in await self?.syncUsage() }
    }

    func syncUsage() async {
        guard !preparingForRelaunch else { return }
        if let usageTask { await usageTask.value; return }
        guard let usageAPI, let owner = accountID, isReady, Date.now >= usageRetryAt,
              !(snapshot.pendingUsage ?? [:]).isEmpty else { return }
        let id = generation
        let operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == id { self.usageTask = nil } }
            do {
                try await self.flush()
                // Snapshot a bounded batch. Remaining events are picked up by the poll.
                let pending = Array((self.snapshot.pendingUsage ?? [:]).sorted { $0.key < $1.key }.prefix(50))
                for (transcriptID, context) in pending {
                    try Task.checkCancellation()
                    guard self.generation == id, self.accountID == owner else { return }
                    do {
                        try await usageAPI.saveUsageContext(context, transcriptID: transcriptID, accountID: owner)
                    } catch VoiceLabError.server(let status, _, _) where status == 410 {
                        // A deleted/unavailable record cannot accept attribution. This is
                        // distinct from an undeployed endpoint (404), which must be retried.
                    }
                    guard self.generation == id, self.accountID == owner else { return }
                    if self.snapshot.pendingUsage?[transcriptID] == context {
                        self.snapshot.pendingUsage?.removeValue(forKey: transcriptID)
                    }
                    self.usageRevision += 1
                    self.usageFailures = 0
                    self.scheduleSave()
                }
                try await self.flush()
            } catch {
                guard self.generation == id, self.accountID == owner, !Task.isCancelled else { return }
                self.usageFailures += 1
                let delay = min(1800, 30 * pow(2, Double(min(6, self.usageFailures - 1))))
                self.usageRetryAt = Date.now.addingTimeInterval(delay)
                if case VoiceLabError.rateLimited(let retryAt, _) = error {
                    self.usageRetryAt = max(self.usageRetryAt, retryAt)
                }
                if case VoiceLabError.server(let status, _, _) = error, status == 404 {
                    self.usageRetryAt = Date.now.addingTimeInterval(1800)
                }
            }
        }
        usageTask = operation
        await operation.value
    }

    func saveNote(_ note: Note) {
        guard isReady else { return }
        var updated = note
        updated.updatedAt = .now
        if let index = snapshot.notes.firstIndex(where: { $0.id == note.id }) {
            snapshot.notes[index] = updated
        } else {
            snapshot.notes.insert(updated, at: 0)
        }
        snapshot.noteSync?.save(updated)
        scheduleSave()
        requestNotesSync()
    }
    func removeNote(_ id: UUID) {
        guard isReady else { return }
        snapshot.notes.removeAll { $0.id == id }
        snapshot.noteSync?.delete(id)
        scheduleSave()
        requestNotesSync()
    }

    func dismissNotesConflict() { notesSyncConflict = false }

    func requestNotesSync() {
        guard !preparingForRelaunch else { return }
        guard notesAPI != nil, isReady, !isSyncingNotes else { return }
        notesDebounce?.cancel()
        notesDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            await self?.syncNotes()
        }
    }

    private func startNotesSync() {
        guard notesAPI != nil else { return }
        notesPoll?.cancel()
        let id = generation
        notesPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == id else { return }
                await self.syncNotes()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    func stopNotesSync() {
        usagePoll?.cancel()
        usagePoll = nil
        usageTask?.cancel()
        usageTask = nil
        usageRetryAt = .distantPast
        usageFailures = 0
        generation = UUID()
        notesPoll?.cancel()
        notesPoll = nil
        notesDebounce?.cancel()
        notesDebounce = nil
        isSyncingNotes = false
        notesSyncError = nil
        notesSyncConflict = false
        failedSyncs = 0
        retryAt = .distantPast
    }

    func syncNotes() async {
        guard !preparingForRelaunch, let notesAPI, isReady, let owner = accountID,
            !isSyncingNotes, Date.now >= retryAt
        else { return }
        let id = generation
        isSyncingNotes = true
        defer {
            if generation == id {
                isSyncingNotes = false
                if pendingNotesCount > 0, notesSyncError == nil { requestNotesSync() }
            }
        }
        do {
            // Persist the exact mutation IDs before any network write; a lost
            // response can then be replayed safely after relaunch.
            try await flush()
            let pending = snapshot.noteSync?.pending ?? []
            var rejectedNote: (any Error)?
            for mutation in pending {
                try Task.checkCancellation()
                guard owner == accountID, id == generation else { return }
                // A queued edit may have changed while another note was uploading.
                guard snapshot.noteSync?.entries[mutation.id]?.pending?.mutationID == mutation.mutationID
                else { continue }
                let remote: RemoteNote
                do {
                    remote = try await notesAPI.saveNote(mutation, accountID: owner)
                } catch VoiceLabError.storage(let detail) {
                    rejectedNote = VoiceLabError.storage(detail)
                    continue
                } catch VoiceLabError.server(let status, let message, let requestID)
                    where status == 422 || status == 413
                {
                    rejectedNote = VoiceLabError.server(
                        status: status, message: message, requestID: requestID)
                    continue
                }
                try Task.checkCancellation()
                guard owner == accountID, id == generation else { return }
                receiveNote(remote, acknowledging: mutation.mutationID)
                try await flush()
            }
            var cursor = ""
            var cursors = Set<String>()
            repeat {
                try Task.checkCancellation()
                guard owner == accountID, id == generation else { return }
                let page = try await notesAPI.notes(cursor: cursor, accountID: owner)
                try Task.checkCancellation()
                guard owner == accountID, id == generation else { return }
                for remote in page.notes { receiveNote(remote) }
                try await flush()
                cursor = page.nextCursor
                guard cursor.isEmpty || cursors.insert(cursor).inserted else {
                    throw VoiceLabError.invalidResponse
                }
            } while !cursor.isEmpty
            if let rejectedNote { throw rejectedNote }
            notesSyncError = nil
            failedSyncs = 0
            retryAt = .distantPast
        } catch is CancellationError {
        } catch {
            guard owner == accountID, id == generation else { return }
            failedSyncs = min(failedSyncs + 1, 4)
            if case VoiceLabError.rateLimited(let deadline, _) = error {
                retryAt = deadline
            } else {
                retryAt = .now.addingTimeInterval(min(300, 30 * pow(2, Double(failedSyncs - 1))))
            }
            notesSyncError = AppLocalization.text(
                "Qaydlar hozircha faqat shu Mac’da saqlangan. Sinxronlash qayta uriniladi.")
        }
    }

    private func receiveNote(_ remote: RemoteNote, acknowledging mutationID: UUID? = nil) {
        var sync = snapshot.noteSync ?? NoteSyncState()
        var notes = snapshot.notes
        let conflict = sync.receive(
            remote, acknowledging: mutationID, notes: &notes,
            copySuffix: AppLocalization.text(" (boshqa tahrir)"))
        snapshot.noteSync = sync
        if snapshot.notes != notes { snapshot.notes = notes }
        notesSyncConflict = notesSyncConflict || conflict
    }
    func addVocabulary(word: String, replacement: String) throws {
        try saveVocabulary(VocabularyEntry(word: word, replacement: replacement))
    }
    func saveVocabulary(_ entry: VocabularyEntry) throws {
        guard isReady else { throw VoiceLabError.sessionChanged }
        snapshot.vocabulary = try VocabularyRules.saving(entry, in: snapshot.vocabulary)
        scheduleSave()
    }
    @discardableResult
    func importVocabulary(_ text: String, language: VocabularyLanguage) throws -> VocabularyRules.ImportResult
    {
        guard isReady else { throw VoiceLabError.sessionChanged }
        let result = try VocabularyRules.importing(text, language: language, into: snapshot.vocabulary)
        snapshot.vocabulary = result.entries
        if result.added > 0 { scheduleSave() }
        return result
    }
    func clearDictionary() {
        guard isReady else { return }
        snapshot.vocabulary.removeAll { !$0.isPhrase }
        scheduleSave()
    }
    func removeVocabulary(_ id: UUID) {
        guard isReady else { return }
        snapshot.vocabulary.removeAll { $0.id == id }
        scheduleSave()
    }
    func saveQuestionnaireDraft(_ draft: QuestionnaireDraft) {
        guard isReady else { return }
        snapshot.questionnaireDraft = draft
        scheduleSave()
    }
    func saveOnboardingPracticeDraft(_ text: String?) {
        guard isReady, snapshot.onboardingPracticeDraft != text else { return }
        snapshot.onboardingPracticeDraft = text
        scheduleSave()
    }
    func saveOnboarding(_ progress: OnboardingProgress) {
        guard isReady else { return }
        snapshot.onboarding = progress
        scheduleSave()
    }
    func flush() async throws {
        pendingSave?.cancel()
        pendingSave = nil
        guard isReady, let accountID else { return }
        do {
            try await store.save(snapshot, accountID: accountID)
            saveError = nil
        } catch {
            saveError = AppLocalization.error(error)
            throw error
        }
    }
    private func scheduleSave() {
        guard isReady, let accountID else { return }
        pendingSave?.cancel()
        let value = snapshot
        pendingSave = Task {
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                try await store.save(value, accountID: accountID)
                saveError = nil
            } catch is CancellationError {} catch { saveError = AppLocalization.error(error) }
        }
    }
}
