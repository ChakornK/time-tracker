import Foundation

public enum ActivityVisibility: String, Codable, CaseIterable, Sendable {
    case `public`
    case `private`
    case friendsOnly = "friends_only"
}

public enum LocalSyncState: String, Codable, Sendable {
    case running
    case pending
    case syncing
    case synced
}

public struct RunningTimer: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var userID: UUID?
    public var title: String
    public var notes: String?
    public var categoryIDs: [UUID]
    public var visibility: ActivityVisibility
    public let startedAt: Date

    public init(
        id: UUID = UUID(),
        userID: UUID? = nil,
        title: String,
        notes: String? = nil,
        categoryIDs: [UUID] = [],
        visibility: ActivityVisibility = .public,
        startedAt: Date = .now
    ) {
        self.id = id
        self.userID = userID
        self.title = title
        self.notes = notes
        self.categoryIDs = categoryIDs
        self.visibility = visibility
        self.startedAt = startedAt
    }

    public func elapsedSeconds(at date: Date = .now) -> TimeInterval {
        max(0, date.timeIntervalSince(startedAt))
    }
}

public struct LocalActivityLog: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let idempotencyKey: UUID
    public var userID: UUID?
    public var title: String
    public var notes: String?
    public var startedAt: Date
    public var endedAt: Date
    public var categoryIDs: [UUID]
    public var visibility: ActivityVisibility
    public var syncState: LocalSyncState
    public var serverID: UUID?
    public var retryCount: Int
    public var lastSyncError: String?
    /// The last send got a definite rejection, such as an unknown category, so the server holds no
    /// copy of this log and it can be fixed on the device.
    public var rejectedByServer: Bool

    public init(
        id: UUID = UUID(),
        idempotencyKey: UUID = UUID(),
        userID: UUID? = nil,
        title: String,
        notes: String?,
        startedAt: Date,
        endedAt: Date,
        categoryIDs: [UUID],
        visibility: ActivityVisibility,
        syncState: LocalSyncState = .pending,
        serverID: UUID? = nil,
        retryCount: Int = 0,
        lastSyncError: String? = nil,
        rejectedByServer: Bool = false
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.userID = userID
        self.title = title
        self.notes = notes
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.categoryIDs = categoryIDs
        self.visibility = visibility
        self.syncState = syncState
        self.serverID = serverID
        self.retryCount = retryCount
        self.lastSyncError = lastSyncError
        self.rejectedByServer = rejectedByServer
    }

    public var durationSeconds: Int {
        max(0, Int(endedAt.timeIntervalSince(startedAt)))
    }
}

public enum LogNotes {
    /// The server's limit, which counts UTF-16 code units the way JavaScript string length does.
    public static let maximumUTF16Length = 10_000

    /// Trimmed notes, or `nil` when there are none, so an empty field never saves blank notes. Long
    /// notes are cut to the server's limit on a character boundary, since a longer note would make the
    /// log fail to sync on every retry.
    public static func cleaned(_ notes: String?) -> String? {
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf16.count > maximumUTF16Length else { return trimmed }
        var length = 0
        let fitting = trimmed.prefix { character in
            length += character.utf16.count
            return length <= maximumUTF16Length
        }
        return String(fitting)
    }
}

/// The fields a person can change on a finished log.
public struct LogEdit: Equatable, Sendable {
    public var title: String
    public var notes: String?
    public var startedAt: Date
    public var endedAt: Date
    public var categoryIDs: [UUID]
    public var visibility: ActivityVisibility

    public init(title: String, notes: String?, startedAt: Date, endedAt: Date, categoryIDs: [UUID], visibility: ActivityVisibility) {
        self.title = title
        self.notes = notes
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.categoryIDs = categoryIDs
        self.visibility = visibility
    }
}

/// Where an edit or deletion of a log has to happen.
public enum LogChangeRoute: Equatable, Sendable {
    /// On the server first, then mirrored on this device.
    case server(id: UUID)
    /// Only on this device: the log has never been sent.
    case localOnly
    /// Not until the log syncs. A send was attempted with an unknown outcome and may have reached the
    /// server, so a changed retry would be rejected as a different log under the same idempotency key.
    case waitForSync
}

extension LocalActivityLog {
    public var changeRoute: LogChangeRoute {
        switch syncState {
        case .synced:
            serverID.map { .server(id: $0) } ?? .waitForSync
        case .pending where (retryCount == 0 && lastSyncError == nil) || rejectedByServer:
            .localOnly
        case .pending, .syncing, .running:
            .waitForSync
        }
    }
}

