import Foundation
import Testing
@testable import TimeTrackerCore

@Suite(.serialized)
@MainActor
struct SyncWorkerTests {
    @Test func workerScopesQueueAndAcknowledgementsToConfiguredAccount() async throws {
        let userID = UUID()
        let log = makeLog(title: "Owned log", userID: userID)
        let store = RecordingTimerStore(log: log)
        let worker = OfflineSyncWorker(
            store: store,
            api: TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!),
            userID: userID
        ) { "access-token" }

        _ = try await worker.synchronize()

        #expect(store.pendingUserIDs == [userID])
        #expect(store.transitionUserIDs == [userID, userID])
    }

    @Test func generatedRetriesPreserveEachLogKeyAndPayload() async {
        for round in 0..<100 {
            let logs = (0..<3).map { index in
                makeLog(title: "round-\(round)-log-\(index)", userID: UUID())
            }
            let api = RecordingLogSyncAPI(failingFirstAttemptFor: Set(logs.map(\.idempotencyKey)))
            let acknowledged = LockedValues<UUID>()
            let failures = LockedValues<UUID>()
            let coordinator = LogSyncCoordinator()
            let originalPayloads = logs.map(LogPayloadSnapshot.init)

            let first = await coordinator.synchronize(
                logs: logs,
                api: api,
                acknowledge: { key, _ in acknowledged.append(key) },
                recordFailure: { key, _, _ in failures.append(key) }
            )
            let retryLogs = logs.filter { failures.values.contains($0.idempotencyKey) }
            let second = await coordinator.synchronize(
                logs: retryLogs,
                api: api,
                acknowledge: { key, _ in acknowledged.append(key) },
                recordFailure: { key, _, _ in failures.append(key) }
            )

            #expect(first.syncedKeys.isEmpty)
            #expect(first.failedKeys == logs.map(\.idempotencyKey))
            #expect(second.failedKeys.isEmpty)
            #expect(second.syncedKeys == logs.map(\.idempotencyKey))
            #expect(acknowledged.values == logs.map(\.idempotencyKey))
            #expect(api.receivedPayloads.map(LogPayloadSnapshot.init) == originalPayloads + originalPayloads)
        }
    }

    @Test func acknowledgementPersistenceFailureRecordsRetryAndContinues() async {
        let logs = [makeLog(title: "first"), makeLog(title: "second")]
        let api = StubLogSyncAPI(failingKey: nil)
        let acknowledged = LockedValues<UUID>()
        let failures = LockedValues<UUID>()
        let report = await LogSyncCoordinator().synchronize(
            logs: logs,
            api: api,
            acknowledge: { key, _ in
                if key == logs[0].idempotencyKey { throw APIClientError.invalidResponse }
                acknowledged.append(key)
            },
            recordFailure: { key, _, _ in failures.append(key) }
        )

        #expect(report.failedKeys == [logs[0].idempotencyKey])
        #expect(report.syncedKeys == [logs[1].idempotencyKey])
        #expect(failures.values == [logs[0].idempotencyKey])
        #expect(acknowledged.values == [logs[1].idempotencyKey])
    }

    @Test func rejectedTokenFlagsReportAsRequiringAuthentication() async {
        struct UnauthorizedLogSyncAPI: LogSyncAPI {
            func createLog(_ log: LocalActivityLog) async throws -> UUID {
                throw APIClientError.server(statusCode: 401, code: "UNAUTHORIZED")
            }
        }
        let log = makeLog(title: "expired")

        let report = await LogSyncCoordinator().synchronize(
            logs: [log],
            api: UnauthorizedLogSyncAPI(),
            acknowledge: { _, _ in },
            recordFailure: { _, _, _ in }
        )

        #expect(report.failedKeys == [log.idempotencyKey])
        #expect(report.requiresAuthentication)
    }

    @Test func syncContinuesAfterFailureAndPreservesIdempotencyKeys() async {
        let logs = [
            makeLog(title: "first"),
            makeLog(title: "second"),
            makeLog(title: "third"),
        ]
        let failingKey = logs[1].idempotencyKey
        let api = StubLogSyncAPI(failingKey: failingKey)
        let acknowledged = LockedValues<(UUID, UUID)>()
        let failures = LockedValues<(UUID, String)>()
        let coordinator = LogSyncCoordinator()

        let report = await coordinator.synchronize(
            logs: logs,
            api: api,
            acknowledge: { key, serverID in acknowledged.append((key, serverID)) },
            recordFailure: { key, message, _ in failures.append((key, message)) }
        )

        #expect(report.syncedKeys == [logs[0].idempotencyKey, logs[2].idempotencyKey])
        #expect(report.failedKeys == [failingKey])
        #expect(acknowledged.values.map(\.0) == report.syncedKeys)
        #expect(failures.values.map(\.0) == [failingKey])
        #expect(api.receivedKeys == logs.map(\.idempotencyKey))
    }

    private func makeLog(title: String, userID: UUID? = nil) -> LocalActivityLog {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return LocalActivityLog(
            idempotencyKey: UUID(),
            userID: userID,
            title: title,
            notes: nil,
            startedAt: start,
            endedAt: start.addingTimeInterval(30),
            categoryIDs: [],
            visibility: .public
        )
    }
}

@MainActor
private final class RecordingTimerStore: TimerStoreProtocol {
    let log: LocalActivityLog
    private(set) var pendingUserIDs: [UUID] = []
    private(set) var transitionUserIDs: [UUID] = []

    init(log: LocalActivityLog) {
        self.log = log
    }

    func start(userID: UUID, title: String, notes: String?, categoryIDs: [UUID], visibility: ActivityVisibility, startedAt: Date) throws -> RunningTimer {
        RunningTimer(userID: userID, title: title, notes: notes, categoryIDs: categoryIDs, visibility: visibility, startedAt: startedAt)
    }

    func stop(timerID: UUID, userID: UUID, endedAt: Date) throws -> LocalActivityLog { log }
    func discardTimer(timerID: UUID, userID: UUID) throws {}
    func updateLog(id: UUID, userID: UUID, edit: LogEdit) throws {}
    func deleteLog(id: UUID, userID: UUID) throws {}
    func removeFromDevice(id: UUID, userID: UUID) throws {}
    func updateTimerNotes(timerID: UUID, userID: UUID, notes: String?) throws -> RunningTimer {
        throw TimerStoreError.noRunningTimer
    }
    func currentTimer(userID: UUID) throws -> RunningTimer? { nil }

    func pendingLogs(userID: UUID) throws -> [LocalActivityLog] {
        pendingUserIDs.append(userID)
        return [log]
    }

    func allLogs(userID: UUID) throws -> [LocalActivityLog] { [log] }

    func completedLogs(userID: UUID) throws -> [LocalActivityLog] { [] }

    func markSyncing(idempotencyKey: UUID, userID: UUID) throws {
        transitionUserIDs.append(userID)
    }

    func updatePendingLog(idempotencyKey: UUID, userID: UUID, title: String, notes: String?, categoryIDs: [UUID], visibility: ActivityVisibility) throws {}

    func markSynced(idempotencyKey: UUID, userID: UUID, serverID: UUID) throws {
        transitionUserIDs.append(userID)
    }

    func recordAttempt(idempotencyKey: UUID, userID: UUID, failure: String, rejected: Bool) throws {
        transitionUserIDs.append(userID)
    }

    func addCompletedLog(userID: UUID, title: String, notes: String?, categoryIDs: [UUID], visibility: ActivityVisibility, startedAt: Date, endedAt: Date) throws -> LocalActivityLog {
        LocalActivityLog(userID: userID, title: title, notes: notes, startedAt: startedAt, endedAt: endedAt, categoryIDs: categoryIDs, visibility: visibility)
    }
}

private struct LogPayloadSnapshot: Equatable {
    let idempotencyKey: UUID
    let title: String
    let startedAt: Date
    let endedAt: Date
    let categoryIDs: [UUID]
    let visibility: ActivityVisibility

    init(_ log: LocalActivityLog) {
        idempotencyKey = log.idempotencyKey
        title = log.title
        startedAt = log.startedAt
        endedAt = log.endedAt
        categoryIDs = log.categoryIDs
        visibility = log.visibility
    }
}

private struct RecordingLogSyncAPI: LogSyncAPI {
    let failingFirstAttemptFor: Set<UUID>
    private let attempts = LockedValues<UUID>()
    private let received = LockedValues<LocalActivityLog>()

    var receivedPayloads: [LocalActivityLog] { received.values }

    func createLog(_ log: LocalActivityLog) async throws -> UUID {
        received.append(log)
        let attempt = attempts.appendAndCount(log.idempotencyKey)
        if attempt == 1, failingFirstAttemptFor.contains(log.idempotencyKey) {
            throw APIClientError.server(statusCode: 503, code: "SERVICE_UNAVAILABLE")
        }
        return UUID()
    }
}

private struct StubLogSyncAPI: LogSyncAPI {
    let failingKey: UUID?
    private let received = LockedValues<UUID>()

    var receivedKeys: [UUID] { received.values }

    func createLog(_ log: LocalActivityLog) async throws -> UUID {
        received.append(log.idempotencyKey)
        if log.idempotencyKey == failingKey {
            throw APIClientError.server(statusCode: 503, code: "SERVICE_UNAVAILABLE")
        }
        return UUID()
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    @discardableResult
    func appendAndCount(_ value: Value) -> Int where Value: Equatable {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
        return storage.filter { $0 == value }.count
    }
}
