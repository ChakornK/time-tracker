import Foundation

public struct FeedEntry: Codable, Equatable, Sendable, Identifiable {
    public struct Author: Codable, Equatable, Sendable {
        public let id: UUID
        public let username: String
        public let displayName: String
        public let avatarUrl: URL?
    }

    public struct Category: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let colorHex: String

        public init(id: UUID, name: String, colorHex: String) {
            self.id = id
            self.name = name
            self.colorHex = colorHex
        }
    }

    public let id: UUID
    public let title: String
    public let notes: String?
    public let startedAt: Date
    public let endedAt: Date
    public let durationSeconds: Int
    public let visibility: ActivityVisibility
    public let createdAt: Date
    /// Present only on the viewer's own entries, matching the key their device synced the log with.
    public let idempotencyKey: UUID?
    public let author: Author
    public let categories: [Category]

    /// This entry after its owner edits it, so the feed can show the change without reloading.
    public func applying(_ edit: LogEdit, categories: [Category]) -> FeedEntry {
        FeedEntry(
            id: id,
            title: edit.title,
            notes: LogNotes.cleaned(edit.notes),
            startedAt: edit.startedAt,
            endedAt: edit.endedAt,
            durationSeconds: max(0, Int(edit.endedAt.timeIntervalSince(edit.startedAt))),
            visibility: edit.visibility,
            createdAt: createdAt,
            idempotencyKey: idempotencyKey,
            author: author,
            categories: categories
        )
    }

    /// The editable fields, to start an edit from.
    public var logEdit: LogEdit {
        LogEdit(title: title, notes: notes, startedAt: startedAt, endedAt: endedAt, categoryIDs: categories.map(\.id), visibility: visibility)
    }
}

public struct FeedPage: Decodable, Equatable, Sendable {
    public let items: [FeedEntry]
    public let nextCursor: String?
}
