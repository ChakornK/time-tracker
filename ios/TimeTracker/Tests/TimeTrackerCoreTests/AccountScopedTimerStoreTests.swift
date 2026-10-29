import Foundation
import Testing
@testable import TimeTrackerCore

@Suite(.serialized)
struct AccountScopedTimerStoreTests {
    @Test @MainActor func rejectsRequestsForAnotherAccount() throws {
        let ownerID = UUID()
        let otherID = UUID()
        let store = AccountScopedTimerStore(store: EmptyTimerStore(), userID: ownerID)

        #expect(throws: TimerStoreError.accountMismatch) {
            try store.currentTimer(userID: otherID)
        }
        #expect(throws: TimerStoreError.accountMismatch) {
            try store.updateTimerNotes(timerID: UUID(), userID: otherID, notes: "Not mine")
        }
        #expect(throws: TimerStoreError.accountMismatch) {
            try store.pendingLogs(userID: otherID)
        }
        #expect(throws: TimerStoreError.accountMismatch) {
            try store.completedLogs(userID: otherID)
        }
        #expect(throws: TimerStoreError.accountMismatch) {
            try store.start(userID: otherID, title: "Other account", notes: nil, categoryIDs: [], visibility: .private, startedAt: .now)
        }
        #expect(throws: TimerStoreError.accountMismatch) {
            try store.stop(timerID: UUID(), userID: otherID, endedAt: .now)
        }
    }

    @Test @MainActor func blocksSecondTimerForConfiguredAccount() throws {
        let ownerID = UUID()
        let underlying = EmptyTimerStore()
        let store = AccountScopedTimerStore(store: underlying, userID: ownerID)
        _ = try store.start(userID: ownerID, title: "First", notes: nil, categoryIDs: [], visibility: .private, startedAt: .now)

        #expect(throws: TimerStoreError.timerAlreadyRunning) {
            try store.start(userID: ownerID, title: "Second", notes: nil, categoryIDs: [], visibility: .private, startedAt: .now)
        }
    }

    @Test @MainActor func bindsNewTimerToConfiguredAccount() throws {
        let ownerID = UUID()
        let store = AccountScopedTimerStore(store: EmptyTimerStore(), userID: ownerID)

        let timer = try store.start(userID: ownerID, title: "Private work", notes: nil, categoryIDs: [], visibility: .private, startedAt: .now)

        #expect(timer.userID == ownerID)
    }
}

@MainActor
private final class EmptyTimerStore: TimerStoreProtocol {
    private var timer: RunningTimer?

    func start(userID: UUID, title: String, notes: String?, categoryIDs: [UUID], visibility: ActivityVisibility, startedAt: Date) throws -> RunningTimer {
        let timer = RunningTimer(userID: userID, title: title, notes: notes, categoryIDs: categoryIDs, visibility: visibility, startedAt: startedAt)
        self.timer = timer
        return timer
    }

    func stop(timerID: UUID, userID: UUID, endedAt: Date) throws -> LocalActivityLog {
        LocalActivityLog(userID: userID, title: "", notes: nil, startedAt: endedAt, endedAt: endedAt, categoryIDs: [], visibility: .private)
    }

    func updateTimerNotes(timerID: UUID, userID: UUID, notes: String?) throws -> RunningTimer {
        guard var timer, timer.id == timerID, timer.userID == userID else { throw TimerStoreError.timerNotFound }
        timer.notes = notes
        self.timer = timer
        return timer
    }

    func currentTimer(userID: UUID) throws -> RunningTimer? { timer?.userID == userID ? timer : nil }
    func pendingLogs(userID: UUID) throws -> [LocalActivityLog] { [] }
    func allLogs(userID: UUID) throws -> [LocalActivityLog] { [] }
    func completedLogs(userID: UUID) throws -> [LocalActivityLog] { [] }
    func markSyncing(idempotencyKey: UUID, userID: UUID) throws {}
    func updatePendingLog(idempotencyKey: UUID, userID: UUID, title: String, notes: String?, categoryIDs: [UUID], visibility: ActivityVisibility) throws {}
    func markSynced(idempotencyKey: UUID, userID: UUID, serverID: UUID) throws {}
    func recordAttempt(idempotencyKey: UUID, userID: UUID, failure: String) throws {}
    func addCompletedLog(userID: UUID, title: String, notes: String?, categoryIDs: [UUID], visibility: ActivityVisibility, startedAt: Date, endedAt: Date) throws -> LocalActivityLog {
        LocalActivityLog(userID: userID, title: title, notes: notes, startedAt: startedAt, endedAt: endedAt, categoryIDs: categoryIDs, visibility: visibility)
    }
}
