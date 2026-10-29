import Foundation

public protocol LogSyncAPI: Sendable {
    func createLog(_ log: LocalActivityLog) async throws -> UUID
}

struct TokenizedLogSyncAPI: LogSyncAPI {
    let client: TrackerAPIClient
    let token: String

    func createLog(_ log: LocalActivityLog) async throws -> UUID {
        try await client.createLog(log, accessToken: token).id
    }
}

public struct SyncReport: Equatable, Sendable {
    public var syncedKeys: [UUID]
    public var failedKeys: [UUID]
    /// Set when the server rejected the access token, so retrying cannot succeed until the user signs in again.
    public var requiresAuthentication: Bool

    public init(syncedKeys: [UUID] = [], failedKeys: [UUID] = [], requiresAuthentication: Bool = false) {
        self.syncedKeys = syncedKeys
        self.failedKeys = failedKeys
        self.requiresAuthentication = requiresAuthentication
    }
}

@MainActor
public struct LogSyncCoordinator {
    public init() {}

    public func synchronize(
        logs: [LocalActivityLog],
        api: any LogSyncAPI,
        acknowledge: (UUID, UUID) throws -> Void,
        recordFailure: (UUID, String, Bool) -> Void
    ) async -> SyncReport {
        var report = SyncReport()

        for log in logs {
            do {
                let serverID = try await api.createLog(log)
                try acknowledge(log.idempotencyKey, serverID)
                report.syncedKeys.append(log.idempotencyKey)
            } catch {
                recordFailure(log.idempotencyKey, error.localizedDescription, Self.isDefiniteRejection(error))
                report.failedKeys.append(log.idempotencyKey)
                if (error as? APIClientError)?.isUnauthorized == true {
                    report.requiresAuthentication = true
                }
            }
        }

        return report
    }

    /// Whether the server answered and refused the log, so it stored nothing. Network failures,
    /// timeouts and server errors leave the outcome unknown. A 401 is about the session rather than the
    /// log, and a 409 means a log with this key already exists.
    ///
    /// Relies on `POST /logs` looking up the idempotency key before validating categories, so a retry of
    /// a log the server already stored gets 200 or 409, never a 400. Keep that order in `LogService.create`.
    nonisolated static func isDefiniteRejection(_ error: any Error) -> Bool {
        switch error as? APIClientError {
        case .invalidFields:
            true
        case .server(let statusCode, _):
            (400..<500).contains(statusCode) && ![401, 408, 409, 429].contains(statusCode)
        default:
            false
        }
    }
}

@MainActor
public final class OfflineSyncWorker {
    private let store: any TimerStoreProtocol
    private let api: TrackerAPIClient
    private let tokenProvider: @Sendable () async -> String?
    private let coordinator = LogSyncCoordinator()

    private let userID: UUID

    public init(
        store: any TimerStoreProtocol,
        api: TrackerAPIClient,
        userID: UUID,
        tokenProvider: @escaping @Sendable () async -> String?
    ) {
        self.store = store
        self.api = api
        self.userID = userID
        self.tokenProvider = tokenProvider
    }

    public func synchronize() async throws -> SyncReport {
        guard let token = await tokenProvider() else { return SyncReport() }
        let queuedLogs = try store.pendingLogs(userID: userID)
        for log in queuedLogs {
            try store.markSyncing(idempotencyKey: log.idempotencyKey, userID: userID)
        }

        return await coordinator.synchronize(
            logs: queuedLogs,
            api: TokenizedLogSyncAPI(client: api, token: token),
            acknowledge: { idempotencyKey, serverID in
                try store.markSynced(idempotencyKey: idempotencyKey, userID: userID, serverID: serverID)
            },
            recordFailure: { idempotencyKey, message, rejected in
                try? store.recordAttempt(idempotencyKey: idempotencyKey, userID: userID, failure: message, rejected: rejected)
            }
        )
    }
}
