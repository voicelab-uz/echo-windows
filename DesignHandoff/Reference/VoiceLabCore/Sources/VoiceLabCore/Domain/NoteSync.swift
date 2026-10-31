import Foundation

/// Persisted beside the encrypted notes. Pending mutations survive app restarts.
public struct NoteSyncState: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var revision = 0
        public var pending: NoteMutation?
    }
    public private(set) var entries: [UUID: Entry] = [:]
    public init() {}
    public var pending: [NoteMutation] {
        entries.values.compactMap(\.pending).sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public mutating func migrate(_ notes: [Note]) {
        for note in notes where entries[note.id] == nil { save(note) }
    }
    public mutating func save(_ note: Note) {
        var entry = entries[note.id] ?? Entry()
        entry.pending = NoteMutation(id: note.id, note: note, expectedRevision: entry.revision)
        entries[note.id] = entry
    }
    public mutating func delete(_ id: UUID) {
        var entry = entries[id] ?? Entry()
        entry.pending = NoteMutation(id: id, note: nil, expectedRevision: entry.revision)
        entries[id] = entry
    }

    /// Returns true if a concurrent edit/delete required preserving another version.
    /// Absence from a paginated response is never interpreted as deletion.
    @discardableResult
    public mutating func receive(
        _ remote: RemoteNote, acknowledging mutationID: UUID? = nil,
        notes: inout [Note], copySuffix: String = " (nusxa)"
    ) -> Bool {
        var entry = entries[remote.id] ?? Entry()
        guard remote.revision >= entry.revision else { return false }
        if remote.revision == entry.revision, entry.pending == nil { return false }
        var conflict = false
        if let pending = entry.pending {
            let acknowledged = mutationID != nil && remote.mutationId == mutationID
            if acknowledged && pending.mutationID != mutationID && !remote.deleted {
                // A newer edit arrived while this exact earlier request was in flight.
                entry.revision = remote.revision
                entry.pending = NoteMutation(
                    id: pending.id, note: pending.note, expectedRevision: remote.revision)
                entries[remote.id] = entry
                return false
            }
            if (acknowledged && pending.mutationID == mutationID)
                || remote.matches(pending.note)
            {
                entry.pending = nil
            } else if remote.revision > entry.revision {
                // Keep the remote original and save the local edit under a new ID.
                // A stale deletion instead restores the newer remote version.
                if var copy = pending.note {
                    copy.id = UUID()
                    while !copy.title.isEmpty && copy.title.utf8.count + copySuffix.utf8.count > 4096 {
                        copy.title.removeLast()
                    }
                    copy.title += copySuffix
                    copy.updatedAt = .now
                    notes.append(copy)
                    save(copy)
                }
                entry.pending = nil
                conflict = true
            } else {
                return false
            }
        }
        entry.revision = remote.revision
        entries[remote.id] = entry
        notes.removeAll { $0.id == remote.id }
        if let note = remote.note { notes.append(note) }
        return conflict
    }
}

public struct NoteMutation: Codable, Sendable, Equatable {
    public let id: UUID
    public let mutationID: UUID
    public let note: Note?
    public let expectedRevision: Int
    public init(id: UUID, note: Note?, expectedRevision: Int, mutationID: UUID = UUID()) {
        self.id = id
        self.note = note
        self.expectedRevision = expectedRevision
        self.mutationID = mutationID
    }
}

public struct RemoteNote: Codable, Sendable {
    public let id: UUID
    public let title: String
    public let body: String
    public let isPinned: Bool
    public let deleted: Bool
    public let revision: Int
    public let mutationId: UUID
    public let updatedAt: String
    public init(
        id: UUID, title: String, body: String, isPinned: Bool, deleted: Bool,
        revision: Int, mutationId: UUID, updatedAt: String
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.isPinned = isPinned
        self.deleted = deleted
        self.revision = revision
        self.mutationId = mutationId
        self.updatedAt = updatedAt
    }
    public var date: Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: updatedAt) ?? ISO8601DateFormatter().date(from: updatedAt)
    }
    public var note: Note? {
        guard !deleted, let date else { return nil }
        var note = Note()
        note.id = id
        note.title = title
        note.body = body
        note.isPinned = isPinned
        note.updatedAt = date
        return note
    }
    public func matches(_ note: Note?) -> Bool {
        guard let note else { return deleted }
        return !deleted && title == note.title && body == note.body && isPinned == note.isPinned
    }
}

public struct NotesPage: Decodable, Sendable {
    public let notes: [RemoteNote]
    public let nextCursor: String
    public init(notes: [RemoteNote], nextCursor: String = "") {
        self.notes = notes
        self.nextCursor = nextCursor
    }
}
