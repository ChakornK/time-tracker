import Foundation
import SwiftData

@Model
public final class StoredTimer {
    @Attribute(.unique) public var id: UUID
    public var userID: UUID?
    public var title: String
    public var notes: String?
    public var categoryIDsData: Data
    public var visibilityRawValue: String
    public var startedAt: Date
    /// Optional so stores written before pausing existed migrate without a default.
    public var pausedAt: Date?
    public var pausedSeconds: Double?

    public init(timer: RunningTimer) throws {
        id = timer.id
        userID = timer.userID
        title = timer.title
        notes = timer.notes
        categoryIDsData = try CategoryIDCoding.encode(timer.categoryIDs)
        visibilityRawValue = timer.visibility.rawValue
        startedAt = timer.startedAt
        pausedAt = timer.pausedAt
        pausedSeconds = timer.pausedSeconds
    }

    public var runningTimer: RunningTimer? {
        guard
            let categoryIDs = CategoryIDCoding.decode(categoryIDsData),
            let visibility = ActivityVisibility(rawValue: visibilityRawValue)
        else {
            return nil
        }

        return RunningTimer(
            id: id,
            userID: userID,
            title: title,
            notes: notes,
            categoryIDs: categoryIDs,
            visibility: visibility,
            startedAt: startedAt,
            pausedAt: pausedAt,
            pausedSeconds: pausedSeconds ?? 0
        )
    }
}

@Model
public final class StoredActivityLog {
    @Attribute(.unique) public var id: UUID
    @Attribute(.unique) public var idempotencyKey: UUID
    public var title: String
    public var notes: String?
    public var startedAt: Date
    public var endedAt: Date
    public var categoryIDsData: Data
    public var visibilityRawValue: String
    public var syncStateRawValue: String
    public var serverID: UUID?
    public var retryCount: Int
    public var lastSyncError: String?
    /// Optional so stores written before it existed migrate without a default.
    public var rejectedByServer: Bool?
    public var userID: UUID?

    public init(log: LocalActivityLog) throws {
        id = log.id
        idempotencyKey = log.idempotencyKey
        userID = log.userID
        title = log.title
        notes = log.notes
        startedAt = log.startedAt
        endedAt = log.endedAt
        categoryIDsData = try CategoryIDCoding.encode(log.categoryIDs)
        visibilityRawValue = log.visibility.rawValue
        syncStateRawValue = log.syncState.rawValue
        serverID = log.serverID
        retryCount = log.retryCount
        lastSyncError = log.lastSyncError
        rejectedByServer = log.rejectedByServer
    }

    public var activityLog: LocalActivityLog? {
        guard
            let categoryIDs = CategoryIDCoding.decode(categoryIDsData),
            let visibility = ActivityVisibility(rawValue: visibilityRawValue),
            let syncState = LocalSyncState(rawValue: syncStateRawValue)
        else {
            return nil
        }

        return LocalActivityLog(
            id: id,
            idempotencyKey: idempotencyKey,
            userID: userID,
            title: title,
            notes: notes,
            startedAt: startedAt,
            endedAt: endedAt,
            categoryIDs: categoryIDs,
            visibility: visibility,
            syncState: syncState,
            serverID: serverID,
            retryCount: retryCount,
            lastSyncError: lastSyncError,
            rejectedByServer: rejectedByServer ?? false
        )
    }
}

public enum TimerStoreError: Error, Equatable {
    case timerAlreadyRunning
    case legacyTimerNeedsReview
    case accountMismatch
    case noRunningTimer
    case timerNotFound
    case invalidStoredTimer
    case invalidStoredLog
    case invalidTimeRange
    case logAwaitingSync
}

extension TimerStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .timerAlreadyRunning: "A timer is already running."
        case .legacyTimerNeedsReview: "A timer from an earlier version is still running on this device."
        case .accountMismatch: "This timer belongs to a different account."
        case .noRunningTimer: "No timer is running."
        case .timerNotFound: "The running timer could not be found."
        case .invalidStoredTimer: "The saved timer is unreadable."
        case .invalidStoredLog: "A saved log is unreadable."
        case .invalidTimeRange: "The end time is before the start time."
        case .logAwaitingSync: "This log is still being sent. Try again once it has synced."
        }
    }
}

/// Category IDs are persisted as JSON so the SwiftData schema stays compatible with existing stores.
private enum CategoryIDCoding {
    static func encode(_ ids: [UUID]) throws -> Data {
        try JSONEncoder().encode(ids)
    }

    static func decode(_ data: Data) -> [UUID]? {
        try? JSONDecoder().decode([UUID].self, from: data)
    }
}

private let pendingState = LocalSyncState.pending.rawValue
private let syncingState = LocalSyncState.syncing.rawValue
private let syncedState = LocalSyncState.synced.rawValue

@MainActor
public protocol TimerStoreProtocol {
    func start(
        userID: UUID,
        title: String,
        notes: String?,
        categoryIDs: [UUID],
        visibility: ActivityVisibility,
        startedAt: Date
    ) throws -> RunningTimer
    func stop(timerID: UUID, userID: UUID, endedAt: Date) throws -> LocalActivityLog
    /// Replaces a running timer's notes; they carry into the log when the timer stops.
    func updateTimerNotes(timerID: UUID, userID: UUID, notes: String?) throws -> RunningTimer
    /// Pauses or resumes a running timer. Doing either twice leaves it as it is.
    func setTimerPaused(timerID: UUID, userID: UUID, paused: Bool, at date: Date) throws -> RunningTimer
    /// Throws away a running timer without saving a log, for one started by mistake.
    func discardTimer(timerID: UUID, userID: UUID) throws
    /// Changes a finished log on this device. Throws `logAwaitingSync` when its `changeRoute` says to
    /// wait; a synced log should already have been changed on the server.
    func updateLog(id: UUID, userID: UUID, edit: LogEdit) throws
    /// Removes a finished log from this device, with the same rule as `updateLog`.
    func deleteLog(id: UUID, userID: UUID) throws
    /// Removes a log whatever its sync state, so it's never sent again. For one stuck waiting to sync:
    /// if an earlier send reached the server, that copy stays there and can be changed from the feed.
    func removeFromDevice(id: UUID, userID: UUID) throws
    func currentTimer(userID: UUID) throws -> RunningTimer?
    func pendingLogs(userID: UUID) throws -> [LocalActivityLog]
    func allLogs(userID: UUID) throws -> [LocalActivityLog]
    func completedLogs(userID: UUID) throws -> [LocalActivityLog]
    func markSyncing(idempotencyKey: UUID, userID: UUID) throws
    func updatePendingLog(idempotencyKey: UUID, userID: UUID, title: String, notes: String?, categoryIDs: [UUID], visibility: ActivityVisibility) throws
    func markSynced(idempotencyKey: UUID, userID: UUID, serverID: UUID) throws
    /// `rejected` means the server definitely didn't store the log, as opposed to an unknown outcome.
    func recordAttempt(idempotencyKey: UUID, userID: UUID, failure: String, rejected: Bool) throws
    /// Saves a finished log entered by hand; it syncs like a log from a stopped timer.
    func addCompletedLog(
        userID: UUID,
        title: String,
        notes: String?,
        categoryIDs: [UUID],
        visibility: ActivityVisibility,
        startedAt: Date,
        endedAt: Date
    ) throws -> LocalActivityLog
}

@MainActor
public final class SwiftDataTimerStore: TimerStoreProtocol {
    private let modelContext: ModelContext
    /// `mainContext` does not keep its container alive, and fetching after the container is freed traps.
    private let modelContainer: ModelContainer?
    private let engine: TimerEngine

    /// Uses the container's main context and keeps the container alive for the store's lifetime.
    public init(modelContainer: ModelContainer, engine: TimerEngine = TimerEngine()) {
        self.modelContext = modelContainer.mainContext
        self.modelContainer = modelContainer
        self.engine = engine
    }

    /// The caller must keep the context's container alive, as `ModelContext(container)` does.
    public init(modelContext: ModelContext, engine: TimerEngine = TimerEngine()) {
        self.modelContext = modelContext
        self.modelContainer = nil
        self.engine = engine
    }

    public func start(
        userID: UUID,
        title: String,
        notes: String? = nil,
        categoryIDs: [UUID] = [],
        visibility: ActivityVisibility = .public,
        startedAt: Date = .now
    ) throws -> RunningTimer {
        if try hasUnownedRunningTimer() {
            throw TimerStoreError.legacyTimerNeedsReview
        }
        var timer = try engine.start(
            existing: currentTimer(userID: userID),
            title: title,
            notes: notes,
            categoryIDs: categoryIDs,
            visibility: visibility,
            at: startedAt
        )
        timer.userID = userID
        modelContext.insert(try StoredTimer(timer: timer))
        try modelContext.save()
        return timer
    }

    public func stop(timerID: UUID, userID: UUID, endedAt: Date = .now) throws -> LocalActivityLog {
        let descriptor = FetchDescriptor<StoredTimer>(
            predicate: #Predicate { $0.id == timerID && $0.userID == userID }
        )
        guard let storedTimer = try modelContext.fetch(descriptor).first else {
            throw TimerStoreError.timerNotFound
        }
        guard let timer = storedTimer.runningTimer else {
            throw TimerStoreError.invalidStoredTimer
        }
        let log = try engine.stop(timer: timer, at: endedAt)
        modelContext.insert(try StoredActivityLog(log: log))
        modelContext.delete(storedTimer)
        try modelContext.save()
        return log
    }

    public func updateTimerNotes(timerID: UUID, userID: UUID, notes: String?) throws -> RunningTimer {
        let descriptor = FetchDescriptor<StoredTimer>(
            predicate: #Predicate { $0.id == timerID && $0.userID == userID }
        )
        guard let storedTimer = try modelContext.fetch(descriptor).first else {
            throw TimerStoreError.timerNotFound
        }
        guard var timer = storedTimer.runningTimer else {
            throw TimerStoreError.invalidStoredTimer
        }
        storedTimer.notes = notes
        try modelContext.save()
        timer.notes = notes
        return timer
    }

    public func setTimerPaused(timerID: UUID, userID: UUID, paused: Bool, at date: Date = .now) throws -> RunningTimer {
        let descriptor = FetchDescriptor<StoredTimer>(
            predicate: #Predicate { $0.id == timerID && $0.userID == userID }
        )
        guard let storedTimer = try modelContext.fetch(descriptor).first else {
            throw TimerStoreError.timerNotFound
        }
        guard let timer = storedTimer.runningTimer else {
            throw TimerStoreError.invalidStoredTimer
        }
        let changed = paused
            ? try engine.pause(timer: timer, at: date)
            : try engine.resume(timer: timer, at: date)
        storedTimer.pausedAt = changed.pausedAt
        storedTimer.pausedSeconds = changed.pausedSeconds
        try modelContext.save()
        return changed
    }

    public func discardTimer(timerID: UUID, userID: UUID) throws {
        let descriptor = FetchDescriptor<StoredTimer>(
            predicate: #Predicate { $0.id == timerID && $0.userID == userID }
        )
        guard let storedTimer = try modelContext.fetch(descriptor).first else {
            throw TimerStoreError.timerNotFound
        }
        modelContext.delete(storedTimer)
        try modelContext.save()
    }

    public func updateLog(id: UUID, userID: UUID, edit: LogEdit) throws {
        guard edit.endedAt >= edit.startedAt else { throw TimerStoreError.invalidTimeRange }
        let stored = try changeableLog(id: id, userID: userID)
        stored.title = edit.title.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.notes = LogNotes.cleaned(edit.notes)
        // The old failure no longer describes this log. `rejectedByServer` stays set so it remains editable.
        stored.lastSyncError = nil
        stored.startedAt = edit.startedAt
        stored.endedAt = edit.endedAt
        stored.categoryIDsData = try CategoryIDCoding.encode(edit.categoryIDs)
        stored.visibilityRawValue = edit.visibility.rawValue
        try modelContext.save()
    }

    public func deleteLog(id: UUID, userID: UUID) throws {
        modelContext.delete(try changeableLog(id: id, userID: userID))
        try modelContext.save()
    }

    public func removeFromDevice(id: UUID, userID: UUID) throws {
        var descriptor = FetchDescriptor<StoredActivityLog>(
            predicate: #Predicate { $0.id == id && $0.userID == userID }
        )
        descriptor.fetchLimit = 1
        guard let stored = try modelContext.fetch(descriptor).first else { throw TimerStoreError.invalidStoredLog }
        modelContext.delete(stored)
        try modelContext.save()
    }

    private func changeableLog(id: UUID, userID: UUID) throws -> StoredActivityLog {
        var descriptor = FetchDescriptor<StoredActivityLog>(
            predicate: #Predicate { $0.id == id && $0.userID == userID }
        )
        descriptor.fetchLimit = 1
        guard let stored = try modelContext.fetch(descriptor).first, let log = stored.activityLog else {
            throw TimerStoreError.invalidStoredLog
        }
        guard log.changeRoute != .waitForSync else { throw TimerStoreError.logAwaitingSync }
        return stored
    }

    public func currentTimer(userID: UUID) throws -> RunningTimer? {
        var descriptor = FetchDescriptor<StoredTimer>(
            predicate: #Predicate { $0.userID == userID },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        descriptor.fetchLimit = 1
        guard let stored = try modelContext.fetch(descriptor).first else { return nil }
        guard let timer = stored.runningTimer else { throw TimerStoreError.invalidStoredTimer }
        return timer
    }

    public func pendingLogs(userID: UUID) throws -> [LocalActivityLog] {
        let pending = pendingState
        let syncing = syncingState
        let descriptor = FetchDescriptor<StoredActivityLog>(
            predicate: #Predicate { $0.userID == userID && ($0.syncStateRawValue == pending || $0.syncStateRawValue == syncing) },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        // Logs left in `syncing` by an interrupted sync are retried.
        return try modelContext.fetch(descriptor).map { stored in
            guard var log = stored.activityLog else { throw TimerStoreError.invalidStoredLog }
            log.syncState = .pending
            return log
        }
    }

    public func allLogs(userID: UUID) throws -> [LocalActivityLog] {
        let descriptor = FetchDescriptor<StoredActivityLog>(
            predicate: #Predicate { $0.userID == userID },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).compactMap(\.activityLog)
    }

    public func completedLogs(userID: UUID) throws -> [LocalActivityLog] {
        let synced = syncedState
        let descriptor = FetchDescriptor<StoredActivityLog>(
            predicate: #Predicate { $0.userID == userID && $0.syncStateRawValue == synced },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).compactMap(\.activityLog)
    }

    public func markSyncing(idempotencyKey: UUID, userID: UUID) throws {
        let stored = try storedLog(idempotencyKey: idempotencyKey, userID: userID, requiringState: pendingState)
        stored.syncStateRawValue = syncingState
        try modelContext.save()
    }

    public func updatePendingLog(
        idempotencyKey: UUID,
        userID: UUID,
        title: String,
        notes: String?,
        categoryIDs: [UUID],
        visibility: ActivityVisibility
    ) throws {
        let stored = try storedLog(idempotencyKey: idempotencyKey, userID: userID, requiringState: pendingState)
        stored.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.notes = notes
        stored.categoryIDsData = try CategoryIDCoding.encode(categoryIDs)
        stored.visibilityRawValue = visibility.rawValue
        try modelContext.save()
    }

    public func markSynced(idempotencyKey: UUID, userID: UUID, serverID: UUID) throws {
        let stored = try storedLog(idempotencyKey: idempotencyKey, userID: userID)
        stored.syncStateRawValue = syncedState
        stored.serverID = serverID
        stored.lastSyncError = nil
        stored.rejectedByServer = nil
        try modelContext.save()
    }

    public func recordAttempt(idempotencyKey: UUID, userID: UUID, failure: String, rejected: Bool) throws {
        let stored = try storedLog(idempotencyKey: idempotencyKey, userID: userID)
        // Sticky: one attempt with an unknown outcome may have stored the log, and a later rejection
        // can't undo that.
        stored.rejectedByServer = rejected && (stored.retryCount == 0 || stored.rejectedByServer == true)
        stored.syncStateRawValue = pendingState
        stored.retryCount += 1
        stored.lastSyncError = failure
        try modelContext.save()
    }

    public func addCompletedLog(
        userID: UUID,
        title: String,
        notes: String?,
        categoryIDs: [UUID],
        visibility: ActivityVisibility,
        startedAt: Date,
        endedAt: Date
    ) throws -> LocalActivityLog {
        guard endedAt > startedAt else { throw TimerStoreError.invalidTimeRange }
        let log = LocalActivityLog(
            userID: userID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes,
            startedAt: startedAt,
            endedAt: endedAt,
            categoryIDs: categoryIDs,
            visibility: visibility
        )
        modelContext.insert(try StoredActivityLog(log: log))
        try modelContext.save()
        return log
    }

    private func hasUnownedRunningTimer() throws -> Bool {
        var descriptor = FetchDescriptor<StoredTimer>(predicate: #Predicate { $0.userID == nil })
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    private func storedLog(idempotencyKey: UUID, userID: UUID, requiringState state: String? = nil) throws -> StoredActivityLog {
        var descriptor = FetchDescriptor<StoredActivityLog>(
            predicate: #Predicate { $0.idempotencyKey == idempotencyKey && $0.userID == userID }
        )
        descriptor.fetchLimit = 1
        guard let stored = try modelContext.fetch(descriptor).first, state == nil || stored.syncStateRawValue == state else {
            throw TimerStoreError.invalidStoredLog
        }
        return stored
    }
}
