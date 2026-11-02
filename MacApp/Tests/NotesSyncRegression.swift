import Foundation
import VoiceLabCore

@main
struct NotesSyncRegression {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Echo-NotesTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await onboardingReplayPreservesLibrary(in: directory.appendingPathComponent("replay"))
        let secrets = MemorySecrets()
        let api = NotesServer()
        let a = LibraryModel(
            store: LibraryStore(directory: directory.appendingPathComponent("a"), secrets: secrets),
            notesAPI: api)
        let b = LibraryModel(
            store: LibraryStore(directory: directory.appendingPathComponent("b"), secrets: secrets),
            notesAPI: api)
        try await a.open(accountID: "owner")
        try await b.open(accountID: "owner")
        try await idle(a)
        try await idle(b)
        var note = Note()
        note.title = "Shared"
        note.body = "Original 😊"
        note.isPinned = true
        a.saveNote(note)
        await a.syncNotes()
        try await idle(a)
        precondition(a.pendingNotesCount == 0)
        await b.syncNotes()
        try await idle(b)
        precondition(b.snapshot.notes.first?.body == note.body && b.snapshot.notes.first?.isPinned == true)
        print("PASS: two computers upload/download and preserve Unicode/pinning.")

        var other = b.snapshot.notes[0]
        other.body = "Other Mac"
        b.saveNote(other)
        note.body = "Offline laptop"
        a.saveNote(note)
        await b.syncNotes()
        try await idle(b)
        await a.syncNotes()
        try await idle(a)
        precondition(
            a.notesSyncConflict && Set(a.snapshot.notes.map(\.body)) == ["Other Mac", "Offline laptop"])
        await a.syncNotes()
        try await idle(a)
        await b.syncNotes()
        try await idle(b)
        precondition(b.snapshot.notes.count == 2)
        print("PASS: concurrent edits preserve both versions and upload the conflict copy.")

        await api.setOffline(true)
        var offline = Note()
        offline.body = "Saved without internet"
        a.saveNote(offline)
        await a.syncNotes()
        try await idle(a)
        precondition(a.notesSyncError != nil && a.pendingNotesCount == 1)
        try await a.close()
        await api.setOffline(false)
        try await a.open(accountID: "owner")
        try await eventually { a.pendingNotesCount == 0 && !a.isSyncingNotes }
        await b.syncNotes()
        try await idle(b)
        precondition(b.snapshot.notes.contains { $0.id == offline.id && $0.body == offline.body })
        print("PASS: encrypted outbox survives offline close/reopen and uploads automatically.")

        await api.loseNextResponse()
        var lost = Note()
        lost.body = "Response lost after commit"
        a.saveNote(lost)
        await a.syncNotes()
        try await idle(a)
        precondition(a.pendingNotesCount == 1)
        try await a.close()
        try await a.open(accountID: "owner")
        try await eventually { a.pendingNotesCount == 0 && !a.isSyncingNotes }
        let revision = await api.revision(lost.id)
        precondition(revision == 1 && a.snapshot.notes.filter { $0.id == lost.id }.count == 1)
        print("PASS: ambiguous timeout replays the persisted mutation without duplicates.")

        a.removeNote(offline.id)
        await a.syncNotes()
        try await idle(a)
        await b.syncNotes()
        try await idle(b)
        precondition(!b.snapshot.notes.contains { $0.id == offline.id })
        print("PASS: deletions propagate without resurrecting notes.")

        // Hold an upload while typing continues; the newer local edit must win locally.
        await api.holdNextSave()
        var typing = Note()
        typing.body = "Before request"
        a.saveNote(typing)
        let upload = Task { await a.syncNotes() }
        try await eventually { await api.isHeld }
        typing.body = "Typed during upload"
        a.saveNote(typing)
        await api.releaseSave()
        await upload.value
        precondition(a.snapshot.notes.first { $0.id == typing.id }?.body == typing.body)
        await a.syncNotes()
        try await idle(a)
        await b.syncNotes()
        try await idle(b)
        precondition(b.snapshot.notes.first { $0.id == typing.id }?.body == typing.body)
        print("PASS: editing during an upload rebases safely without cancelling the request.")

        // An update pauses sync before the durable flush. A late server response
        // must not erase the saved outbox while the app is preparing to exit.
        await api.holdNextSave()
        var beforeUpdate = Note()
        beforeUpdate.body = "Keep this across an update"
        a.saveNote(beforeUpdate)
        let heldForUpdate = Task { await a.syncNotes() }
        try await eventually { await api.isHeld }
        a.prepareForRelaunch()
        try await a.flush()
        await api.releaseSave()
        await heldForUpdate.value
        precondition(a.pendingNotesCount == 1)
        await a.syncNotes()
        precondition(a.pendingNotesCount == 1, "Paused sync must not start another request.")
        let reopenedStore = LibraryStore(directory: directory.appendingPathComponent("a"), secrets: secrets)
        let preserved = try await reopenedStore.load(accountID: "owner")
        precondition(preserved.notes.contains { $0.id == beforeUpdate.id && $0.body == beforeUpdate.body })
        precondition(preserved.noteSync?.pending.contains { $0.id == beforeUpdate.id } == true)
        a.resumeAfterRelaunchCancellation()
        try await eventually { a.pendingNotesCount == 0 && !a.isSyncingNotes }
        print("PASS: update preparation preserves the durable outbox; canceled installation resumes sync.")

        // An old account's request may finish even after cancellation.
        await api.holdNextSave()
        var late = Note()
        late.body = "Account A private note"
        a.saveNote(late)
        let oldUpload = Task { await a.syncNotes() }
        try await eventually { await api.isHeld }
        try await b.close()
        try await a.close()
        await api.setAccount("second")
        try await a.open(accountID: "second")
        await api.releaseSave()
        await oldUpload.value
        try await idle(a)
        precondition(a.snapshot.notes.isEmpty && a.pendingNotesCount == 0)
        print("PASS: a late response cannot cross an account boundary.")
        try await a.close()
        print("PASS: all Notes synchronization model regressions.")
    }

    @MainActor
    static func onboardingReplayPreservesLibrary(in directory: URL) async throws {
        let secrets = MemorySecrets()
        let store = LibraryStore(directory: directory, secrets: secrets)
        let library = LibraryModel(store: store)
        do {
            try await library.restartOnboarding()
            preconditionFailure("Replay must not succeed before the encrypted library is open.")
        } catch VoiceLabError.storage {}
        try await library.open(accountID: "replay-owner")
        var note = Note()
        note.body = "Unsynced local note — must survive onboarding replay."
        library.saveNote(note)
        library.merge([Transcript(text: "Saved dictation", language: "en", durationMS: 2000)])
        try library.addVocabulary(word: "Echo", replacement: "")
        var finished = OnboardingProgress()
        finished.answers.role = "developer"
        finished.completedExercises = [.tryMessage, .tryEmail]
        finished.complete()
        library.saveOnboarding(finished)
        library.saveOnboardingPracticeDraft("A private voice trial — O‘zbekcha and English.")
        try await library.flush()
        let practiceSaved = try await store.load(accountID: "replay-owner")
        precondition(practiceSaved.onboardingPracticeDraft == library.snapshot.onboardingPracticeDraft)
        let otherAccount = try await store.load(accountID: "other-owner")
        precondition(otherAccount.onboardingPracticeDraft == nil)
        let before = library.snapshot

        try await library.restartOnboarding()
        try await library.close()
        // Reload through the encrypted store, proving the existing encryption key still works.
        try await library.open(accountID: "replay-owner")
        precondition(library.snapshot.notes == before.notes)
        precondition(library.snapshot.transcripts == before.transcripts)
        precondition(library.snapshot.vocabulary == before.vocabulary)
        precondition(library.snapshot.noteSync?.pending == before.noteSync?.pending)
        precondition(library.snapshot.onboardingPracticeDraft == nil,
                     "An explicit onboarding replay should clear only its previous practice draft.")
        let progress = library.snapshot.onboarding!
        precondition(progress.completedAt == nil && progress.step == .aboutYou)
        precondition(progress.answers.role.isEmpty && progress.completedExercises.isEmpty)
        precondition(progress.profileLoaded && !progress.pendingSync)
        try await library.restartOnboarding()
        precondition(library.snapshot.onboarding == progress, "Replay must be idempotent.")
        try await library.close()
        print(
            "PASS: onboarding replay preserves encrypted notes, history, vocabulary and unsynced mutations.")
    }

    @MainActor
    static func idle(_ model: LibraryModel) async throws {
        await Task.yield()
        try await eventually { !model.isSyncingNotes }
    }
    @MainActor
    static func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out waiting for notes sync.")
    }
}

private actor NotesServer: NotesServing {
    var account = "owner"
    var records: [String: [UUID: RemoteNote]] = [:]
    var offline = false
    var loseResponse = false
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    var isHeld: Bool { continuation != nil }
    func setAccount(_ value: String) { account = value }
    func setOffline(_ value: Bool) { offline = value }
    func loseNextResponse() { loseResponse = true }
    func holdNextSave() { hold = true }
    func releaseSave() {
        continuation?.resume()
        continuation = nil
    }
    func revision(_ id: UUID) -> Int? { records[account]?[id]?.revision }
    func notes(cursor: String, accountID: String) async throws -> NotesPage {
        guard accountID == account else { throw VoiceLabError.sessionChanged }
        if offline { throw URLError(.notConnectedToInternet) }
        let items = (records[account] ?? [:]).values.sorted { $0.id.uuidString < $1.id.uuidString }
        return NotesPage(notes: items)
    }
    func saveNote(_ mutation: NoteMutation, accountID: String) async throws -> RemoteNote {
        guard accountID == account else { throw VoiceLabError.sessionChanged }
        if offline { throw URLError(.notConnectedToInternet) }
        let owner = account
        if hold {
            hold = false
            await withCheckedContinuation { continuation = $0 }
        }
        let current = records[owner]?[mutation.id]
        if let current, current.mutationId == mutation.mutationID { return current }
        if let current, current.revision != mutation.expectedRevision || current.deleted { return current }
        let note = RemoteNote(
            id: mutation.id, title: mutation.note?.title ?? "", body: mutation.note?.body ?? "",
            isPinned: mutation.note?.isPinned ?? false, deleted: mutation.note == nil,
            revision: (current?.revision ?? 0) + 1, mutationId: mutation.mutationID,
            updatedAt: ISO8601DateFormatter().string(from: .now))
        records[owner, default: [:]][note.id] = note
        if loseResponse {
            loseResponse = false
            throw URLError(.timedOut)
        }
        return note
    }
}

private final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { data[key] } }
    func write(_ value: Data, key: String) throws { lock.withLock { data[key] = value } }
    func remove(_ key: String) throws { _ = lock.withLock { data.removeValue(forKey: key) } }
}
