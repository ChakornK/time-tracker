import Foundation

public struct TimerEngine: Sendable {
    public init() {}

    public func start(
        existing: RunningTimer?,
        title: String,
        notes: String? = nil,
        categoryIDs: [UUID] = [],
        visibility: ActivityVisibility = .public,
        at startedAt: Date
    ) throws -> RunningTimer {
        guard existing == nil else { throw TimerStoreError.timerAlreadyRunning }
        return RunningTimer(
            id: UUID(),
            userID: nil,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes,
            categoryIDs: categoryIDs,
            visibility: visibility,
            startedAt: startedAt
        )
    }

    public func pause(timer: RunningTimer?, at date: Date) throws -> RunningTimer {
        guard var timer else { throw TimerStoreError.noRunningTimer }
        guard timer.pausedAt == nil else { return timer }
        guard date >= timer.startedAt else { throw TimerStoreError.invalidTimeRange }
        timer.pausedAt = date
        return timer
    }

    public func resume(timer: RunningTimer?, at date: Date) throws -> RunningTimer {
        guard var timer else { throw TimerStoreError.noRunningTimer }
        guard let pausedAt = timer.pausedAt else { return timer }
        timer.pausedSeconds += max(0, date.timeIntervalSince(pausedAt))
        timer.pausedAt = nil
        return timer
    }

    /// A log's length is its end minus its start, so paused time is left out by ending the log early:
    /// it starts when the timer did and ends after the active time, never later than `endedAt`.
    public func stop(timer: RunningTimer?, at stoppedAt: Date) throws -> LocalActivityLog {
        guard let timer else { throw TimerStoreError.noRunningTimer }
        guard stoppedAt >= timer.startedAt else { throw TimerStoreError.invalidTimeRange }
        let endedAt = timer.pausedSeconds == 0 && timer.pausedAt == nil
            ? stoppedAt
            : timer.startedAt.addingTimeInterval(timer.elapsedSeconds(at: stoppedAt))

        return LocalActivityLog(
            idempotencyKey: UUID(),
            userID: timer.userID,
            title: timer.title,
            notes: timer.notes,
            startedAt: timer.startedAt,
            endedAt: endedAt,
            categoryIDs: timer.categoryIDs,
            visibility: timer.visibility
        )
    }
}
