import Foundation

public protocol NotesServing: Sendable {
    func notes(cursor: String, accountID: String) async throws -> NotesPage
    func saveNote(_ mutation: NoteMutation, accountID: String) async throws -> RemoteNote
}

extension DesktopAPI: NotesServing {
    public func notes(cursor: String = "", accountID: String) async throws -> NotesPage {
        guard cursor.isEmpty || UUID(uuidString: cursor) != nil else { throw VoiceLabError.invalidResponse }
        let suffix = cursor.isEmpty ? "" : "?cursor=\(cursor)"
        let data = try await request("/v1/desktop/notes\(suffix)", accountID: accountID)
        let page = try HTTPClient.decode(NotesPage.self, data: data)
        guard page.notes.count <= 20,
            Set(page.notes.map(\.id)).count == page.notes.count,
            page.nextCursor.isEmpty || UUID(uuidString: page.nextCursor) == page.notes.last?.id,
            page.notes.allSatisfy(validRemoteNote)
        else { throw VoiceLabError.invalidResponse }
        return page
    }

    public func saveNote(_ mutation: NoteMutation, accountID: String) async throws -> RemoteNote {
        let payload = NotePayload(mutation)
        guard payload.title.utf8.count <= 4096, payload.body.utf8.count <= 524_288,
            !payload.title.contains("\0"), !payload.body.contains("\0")
        else {
            throw VoiceLabError.storage(
                "Qayd hajmi juda katta yoki yaroqsiz belgi mavjud. Lokal nusxa saqlangan.")
        }
        let path = "/v1/desktop/notes/\(mutation.id.uuidString.lowercased())"
        let data: Data
        do {
            data = try await request(
                path, method: "PUT", body: JSONEncoder().encode(payload), accountID: accountID)
        } catch VoiceLabError.server(let status, _, _) where status == 409 {
            // Get the authoritative version for lossless conflict handling.
            data = try await request(path, accountID: accountID)
        }
        let note = try HTTPClient.decode(RemoteNote.self, data: data)
        guard note.id == mutation.id, validRemoteNote(note) else { throw VoiceLabError.invalidResponse }
        return note
    }

    private func validRemoteNote(_ note: RemoteNote) -> Bool {
        note.revision > 0 && note.date != nil
            && note.title.utf8.count <= 4096 && note.body.utf8.count <= 524_288
            && (!note.deleted || (note.title.isEmpty && note.body.isEmpty && !note.isPinned))
    }
}

private struct NotePayload: Encodable {
    let title: String
    let body: String
    let isPinned: Bool
    let deleted: Bool
    let expectedRevision: Int
    let mutationID: UUID
    enum CodingKeys: String, CodingKey {
        case title, body, deleted
        case isPinned = "is_pinned"
        case expectedRevision = "expected_revision"
        case mutationID = "mutation_id"
    }
    init(_ mutation: NoteMutation) {
        title = mutation.note?.title ?? ""
        body = mutation.note?.body ?? ""
        isPinned = mutation.note?.isPinned ?? false
        deleted = mutation.note == nil
        expectedRevision = mutation.expectedRevision
        mutationID = mutation.mutationID
    }
}
