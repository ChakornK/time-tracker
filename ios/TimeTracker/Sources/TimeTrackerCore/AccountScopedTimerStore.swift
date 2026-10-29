import Foundation

/// Wraps a timer store so every call is checked against a single signed-in account.
@MainActor
public final class AccountScopedTimerStore: TimerStoreProtocol {
    private let store: any TimerStoreProtocol
    private let userID: UUID

    public init(store: any TimerStoreProtocol, userID: UUID) {
        self.store = store
        self.userID = userID
    }

    public func start(
        userID requestedUserID: UUID,
        title: String,
        notes: String?,
        categoryIDs: [UUID],
        visibility: ActivityVisibility,
        startedAt: Date
    ) throws -> RunningTimer {
        try verify(requestedUserID)
        guard try store.currentTimer(userID: userID) == nil else {
            throw TimerStoreError.timerAlreadyRunning
        }
        return try store.start(
            userID: userID,
            title: title,
            notes: notes,
            categoryIDs: categoryIDs,
            visibility: visibility,
            startedAt: startedAt
        )
    }

    public func stop(timerID: UUID, userID requestedUserID: UUID, endedAt: Date) throws -> LocalActivityLog {
        try verify(requestedUserID)
        return try store.stop(timerID: timerID, userID: userID, endedAt: endedAt)
    }

    public func updateTimerNotes(timerID: UUID, userID requestedUserID: UUID, notes: String?) throws -> RunningTimer {
        try verify(requestedUserID)
        return try store.updateTimerNotes(timerID: timerID, userID: userID, notes: notes)
    }

    public func discardTimer(timerID: UUID, userID requestedUserID: UUID) throws {
        try verify(requestedUserID)
        try store.discardTimer(timerID: timerID, userID: userID)
    }

    public func updateLog(id: UUID, userID requestedUserID: UUID, edit: LogEdit) throws {
        try verify(requestedUserID)
        try store.updateLog(id: id, userID: userID, edit: edit)
    }

    public func deleteLog(id: UUID, userID requestedUserID: UUID) throws {
        try verify(requestedUserID)
        try store.deleteLog(id: id, userID: userID)
    }

    public func removeFromDevice(id: UUID, userID requestedUserID: UUID) throws {
        try verify(requestedUserID)
        try store.removeFromDevice(id: id, userID: userID)
    }

    public func currentTimer(userID requestedUserID: UUID) throws -> RunningTimer? {
        try verify(requestedUserID)
        return try store.currentTimer(userID: userID)
    }

    public func pendingLogs(userID requestedUserID: UUID) throws -> [LocalActivityLog] {
        try verify(requestedUserID)
        return try store.pendingLogs(userID: userID)
    }

    public func allLogs(userID requestedUserID: UUID) throws -> [LocalActivityLog] {
        try verify(requestedUserID)
        return try store.allLogs(userID: userID)
    }

    public func completedLogs(userID requestedUserID: UUID) throws -> [LocalActivityLog] {
        try verify(requestedUserID)
        return try store.completedLogs(userID: userID)
    }

    public func markSyncing(idempotencyKey: UUID, userID requestedUserID: UUID) throws {
        try verify(requestedUserID)
        try store.markSyncing(idempotencyKey: idempotencyKey, userID: userID)
    }

    public func updatePendingLog(
        idempotencyKey: UUID,
        userID requestedUserID: UUID,
        title: String,
        notes: String?,
        categoryIDs: [UUID],
        visibility: ActivityVisibility
    ) throws {
        try verify(requestedUserID)
        try store.updatePendingLog(
            idempotencyKey: idempotencyKey,
            userID: userID,
            title: title,
            notes: notes,
            categoryIDs: categoryIDs,
            visibility: visibility
        )
    }

    public func markSynced(idempotencyKey: UUID, userID requestedUserID: UUID, serverID: UUID) throws {
        try verify(requestedUserID)
        try store.markSynced(idempotencyKey: idempotencyKey, userID: userID, serverID: serverID)
    }

    public func recordAttempt(idempotencyKey: UUID, userID requestedUserID: UUID, failure: String, rejected: Bool) throws {
        try verify(requestedUserID)
        try store.recordAttempt(idempotencyKey: idempotencyKey, userID: userID, failure: failure, rejected: rejected)
    }

    public func addCompletedLog(
        userID requestedUserID: UUID,
        title: String,
        notes: String?,
        categoryIDs: [UUID],
        visibility: ActivityVisibility,
        startedAt: Date,
        endedAt: Date
    ) throws -> LocalActivityLog {
        try verify(requestedUserID)
        return try store.addCompletedLog(
            userID: userID,
            title: title,
            notes: notes,
            categoryIDs: categoryIDs,
            visibility: visibility,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    private func verify(_ requestedUserID: UUID) throws {
        guard requestedUserID == userID else { throw TimerStoreError.accountMismatch }
    }
}
