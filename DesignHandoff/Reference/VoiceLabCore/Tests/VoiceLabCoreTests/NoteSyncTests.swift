import Foundation
import Testing

@testable import VoiceLabCore

@Suite struct NoteSyncTests {
    private func remote(_ note: Note?, id: UUID, revision: Int, mutation: UUID = UUID()) -> RemoteNote {
        RemoteNote(
            id: id, title: note?.title ?? "", body: note?.body ?? "", isPinned: note?.isPinned ?? false,
            deleted: note == nil, revision: revision, mutationId: mutation,
            updatedAt: "2026-10-21T00:00:00.123456Z")
    }
    @Test func legacyNotesBecomeDurablePendingMutations() throws {
        var note = Note()
        note.body = "Old local note"
        var state = NoteSyncState()
        state.migrate([note])
        let first = try #require(state.pending.first)
        #expect(first.note == note && first.expectedRevision == 0)
        state.migrate([note])
        #expect(state.pending.first?.mutationID == first.mutationID)
        var snapshot = LibrarySnapshot()
        snapshot.notes = [note]
        snapshot.noteSync = state
        let restored = try JSONDecoder().decode(LibrarySnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.noteSync?.pending == state.pending)
        let legacy = try JSONDecoder().decode(
            LibrarySnapshot.self,
            from: Data(#"{"schemaVersion":1,"transcripts":[],"notes":[],"vocabulary":[]}"#.utf8))
        #expect(legacy.noteSync == nil)
    }
    @Test func uploadAckDoesNotOverwriteTypingDuringRequest() throws {
        var note = Note()
        note.body = "First"
        var notes = [note]
        var state = NoteSyncState()
        state.save(note)
        let sent = try #require(state.pending.first)
        note.body = "Typing continued"
        notes = [note]
        state.save(note)
        let saved = remote(sent.note, id: note.id, revision: 1, mutation: sent.mutationID)
        #expect(!state.receive(saved, acknowledging: sent.mutationID, notes: &notes))
        #expect(notes.first?.body == "Typing continued")
        #expect(state.pending.first?.expectedRevision == 1)
        let next = try #require(state.pending.first)
        #expect(
            !state.receive(
                remote(next.note, id: note.id, revision: 2, mutation: next.mutationID),
                acknowledging: next.mutationID, notes: &notes))
        #expect(state.pending.isEmpty && notes.count == 1)
    }
    @Test func twoDevicesPreserveBothConflictingEdits() throws {
        var original = Note()
        original.body = "Original"
        var notes: [Note] = []
        var state = NoteSyncState()
        state.receive(remote(original, id: original.id, revision: 1), notes: &notes)
        var local = original
        local.body = "Laptop edit"
        notes = [local]
        state.save(local)
        original.body = "Other Mac edit"
        #expect(state.receive(remote(original, id: original.id, revision: 2), notes: &notes))
        #expect(Set(notes.map(\.body)) == ["Laptop edit", "Other Mac edit"])
        let copy = try #require(state.pending.first)
        #expect(copy.id != original.id && copy.expectedRevision == 0)
        state.receive(remote(original, id: original.id, revision: 2), notes: &notes)
        #expect(notes.count == 2 && state.pending.count == 1)
    }
    @Test func deletedRemotePreservesOfflineLocalEditAsCopy() {
        var original = Note()
        original.body = "Before"
        var notes: [Note] = []
        var state = NoteSyncState()
        state.receive(remote(original, id: original.id, revision: 1), notes: &notes)
        original.body = "Offline edit"
        notes = [original]
        state.save(original)
        #expect(state.receive(remote(nil, id: original.id, revision: 2), notes: &notes))
        #expect(notes.count == 1 && notes[0].id != original.id && notes[0].body == "Offline edit")
    }
    @Test func staleDeleteCannotEraseNewerRemoteEdit() {
        var note = Note()
        note.body = "Before"
        var notes: [Note] = []
        var state = NoteSyncState()
        state.receive(remote(note, id: note.id, revision: 1), notes: &notes)
        notes.removeAll()
        state.delete(note.id)
        note.body = "Remote work"
        #expect(state.receive(remote(note, id: note.id, revision: 2), notes: &notes))
        #expect(notes.first?.body == "Remote work" && state.pending.isEmpty)
    }
    @Test func lostResponseReplayAndTombstonesAreIdempotent() throws {
        let note = Note()
        var notes = [note]
        var state = NoteSyncState()
        state.save(note)
        let sent = try #require(state.pending.first)
        let accepted = remote(note, id: note.id, revision: 1, mutation: sent.mutationID)
        state.receive(accepted, acknowledging: sent.mutationID, notes: &notes)
        state.receive(accepted, notes: &notes)
        #expect(notes.count == 1 && state.pending.isEmpty)
        state.delete(note.id)
        notes.removeAll()
        let deletion = try #require(state.pending.first)
        state.receive(
            remote(nil, id: note.id, revision: 2, mutation: deletion.mutationID),
            acknowledging: deletion.mutationID, notes: &notes)
        state.receive(accepted, notes: &notes)  // Delayed old response cannot resurrect it.
        #expect(notes.isEmpty && state.pending.isEmpty)
    }
    @Test func noContentChangeDoesNotCreateConflictCopy() {
        var note = Note()
        note.title = "Same"
        var notes = [note]
        var state = NoteSyncState()
        state.save(note)
        #expect(!state.receive(remote(note, id: note.id, revision: 3), notes: &notes))
        #expect(state.pending.isEmpty && notes.count == 1)
    }
    @Test func localDeleteWhileCreateInFlightRebasesToAcceptedRevision() throws {
        let note = Note()
        var notes = [note]
        var state = NoteSyncState()
        state.save(note)
        let sent = try #require(state.pending.first)
        state.delete(note.id)
        notes.removeAll()
        state.receive(
            remote(note, id: note.id, revision: 1, mutation: sent.mutationID), acknowledging: sent.mutationID,
            notes: &notes)
        #expect(
            notes.isEmpty && state.pending.first?.expectedRevision == 1 && state.pending.first?.note == nil)
    }
}
