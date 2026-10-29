import Foundation
import WidgetKit

@MainActor
@Observable
final class TimerHomeModel {
    let categories: CategoryStore
    let goals: GoalStore
    private let api: TrackerAPIClient
    private let token: String
    private let userID: UUID
    private let store: AccountScopedTimerStore
    private let liveActivity: LiveActivityController
    private let onAuthenticationExpired: () -> Void
    private var hasExpiredSession = false

    private(set) var runningTimer: RunningTimer?
    /// All saved logs for the account, newest first, including logs waiting to sync.
    private(set) var logs: [LocalActivityLog] = []
    private(set) var syncInProgress = false
    private(set) var lastSavedDurationSeconds: Int?
    private(set) var activityState: TimerActivityAttributes.ContentState?
    var selectedCategoryID: UUID?
    var newCategoryName = ""
    /// Notes for the next timer, entered before it starts.
    var timerNotes = ""
    var visibility: ActivityVisibility = .public
    var errorMessage: String?
    var stopFailureMessage: String?

    init(
        api: TrackerAPIClient,
        token: String,
        userID: UUID,
        timerStore: any TimerStoreProtocol,
        categories: CategoryStore,
        goals: GoalStore,
        liveActivity: LiveActivityController,
        onAuthenticationExpired: @escaping () -> Void
    ) {
        self.api = api
        self.token = token
        self.userID = userID
        self.store = AccountScopedTimerStore(store: timerStore, userID: userID)
        self.categories = categories
        self.goals = goals
        self.liveActivity = liveActivity
        self.onAuthenticationExpired = onAuthenticationExpired
    }

    var pendingLogCount: Int {
        logs.count { $0.syncState != .synced }
    }

    /// Categories that a running timer or an unsynced log still references. The server rejects
    /// logs with unknown categories, so deleting one of these would leave a log that never syncs.
    var categoryIDsAwaitingSync: Set<UUID> {
        var ids = Set(runningTimer?.categoryIDs ?? [])
        for log in logs where log.syncState != .synced {
            ids.formUnion(log.categoryIDs)
        }
        return ids
    }

    func categoryWasDeleted(_ categoryID: UUID) {
        goals.removeGoals(forCategoryID: categoryID)
        if selectedCategoryID == categoryID {
            selectedCategoryID = categories.categories.first?.id
        }
        publishWidgetSummary()
    }

    /// Logs as Analytics, goals, and the widget count them: time logged to a deleted category is left out.
    var summaryLogs: [ProductivitySummaryLog] {
        summaryLogs(from: logs)
    }

    private func summaryLogs(from logs: [LocalActivityLog]) -> [ProductivitySummaryLog] {
        let all = logs.map(\.productivitySummaryLog)
        // Until categories load, an empty list would look like every category was deleted.
        guard categories.hasLoaded else { return all }
        return all.keepingCategories(Set(categories.categories.map(\.id)))
    }

    var canStart: Bool {
        categories.category(withID: selectedCategoryID) != nil && !categories.isCreating
    }

    private var trimmedNewCategoryName: String {
        newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func load() async {
        reloadLocalData()
        publishWidgetSummary()
        await liveActivity.restore(runningTimer)
        activityState = runningTimer.flatMap { liveActivity.state(for: $0.id) }
        await refreshRemoteData()
    }

    func refreshRemoteData() async {
        await synchronize()
        await reloadCategories()
        await reloadGoals()
    }

    func start(at date: Date = .now) async {
        guard let category = categories.category(withID: selectedCategoryID) else {
            errorMessage = "Choose or add a category before starting."
            return
        }
        let timer: RunningTimer
        do {
            timer = try store.start(
                userID: userID,
                title: category.name,
                notes: LogNotes.cleaned(timerNotes),
                categoryIDs: [category.id],
                visibility: visibility,
                startedAt: date
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        runningTimer = timer
        selectedCategoryID = nil
        timerNotes = ""
        lastSavedDurationSeconds = nil
        errorMessage = nil
        await liveActivity.start(for: timer)
        activityState = liveActivity.state(for: timer.id)
    }

    func stop(at date: Date = .now) async {
        guard let timer = runningTimer else { return }
        do {
            let log = try store.stop(timerID: timer.id, userID: userID, endedAt: date)
            lastSavedDurationSeconds = log.durationSeconds
            errorMessage = nil
        } catch {
            stopFailureMessage = error.localizedDescription
            return
        }
        reloadLocalData()
        publishWidgetSummary()
        await liveActivity.end(timerID: timer.id)
        activityState = nil
        await synchronize()
    }

    /// Replaces the running timer's notes, which are saved with its log when it stops.
    func updateNotes(_ notes: String) {
        guard let timer = runningTimer else {
            errorMessage = "The timer already stopped, so its notes couldn't be changed."
            return
        }
        do {
            runningTimer = try store.updateTimerNotes(timerID: timer.id, userID: userID, notes: LogNotes.cleaned(notes))
            errorMessage = nil
        } catch TimerStoreError.timerNotFound {
            // Stopped from the Live Activity or widget while the notes were open.
            reloadLocalData()
            errorMessage = "The timer already stopped, so its notes couldn't be changed."
        } catch {
            errorMessage = "Notes could not be saved. Try again."
        }
    }

    /// Saves time the user enters by hand, then syncs it in the background.
    func addManualLog(
        categoryID: UUID,
        startedAt: Date,
        duration: TimeInterval,
        visibility: ActivityVisibility,
        notes: String?
    ) throws {
        guard let category = categories.category(withID: categoryID) else {
            throw ManualLogError.missingCategory
        }
        guard duration > 0 else { throw ManualLogError.emptyDuration }
        let endedAt = startedAt.addingTimeInterval(duration)
        guard endedAt <= .now else { throw ManualLogError.endsInFuture }

        let log = try store.addCompletedLog(
            userID: userID,
            title: category.name,
            notes: LogNotes.cleaned(notes),
            categoryIDs: [category.id],
            visibility: visibility,
            startedAt: startedAt,
            endedAt: endedAt
        )
        lastSavedDurationSeconds = log.durationSeconds
        errorMessage = nil
        reloadLocalData()
        publishWidgetSummary()
        Task { await synchronize() }
    }

    func synchronize() async {
        guard !syncInProgress else { return }
        syncInProgress = true
        defer { syncInProgress = false }

        let worker = OfflineSyncWorker(store: store, api: api, userID: userID) { [token] in token }
        do {
            let report = try await worker.synchronize()
            reloadLocalData()
            publishWidgetSummary()
            if report.requiresAuthentication {
                expireSession()
            } else if report.failedKeys.isEmpty {
                errorMessage = nil
            } else if let details = logs.lazy.compactMap(\.lastSyncError).first {
                errorMessage = "\(report.failedKeys.count) saved log(s) could not sync: \(details)"
            } else {
                errorMessage = "\(report.failedKeys.count) saved log(s) could not sync. They remain on this device; tap Sync now to retry."
            }
        } catch {
            reloadLocalData()
            errorMessage = "Sync could not start. Your logs remain saved on this device. \(error.localizedDescription)"
        }
    }

    func addCategory() async {
        let name = trimmedNewCategoryName
        guard !name.isEmpty else {
            errorMessage = "Enter a category name."
            return
        }
        do {
            let category = try await categories.create(named: name)
            selectedCategoryID = category.id
            newCategoryName = ""
            errorMessage = nil
        } catch ProfileClientError.duplicateCategory {
            errorMessage = "That category already exists. Pick it from your categories."
        } catch {
            errorMessage = "Category could not be added. Check your connection and try again."
        }
    }

    private func reloadCategories() async {
        do {
            try await categories.reload()
            if categories.category(withID: selectedCategoryID) == nil {
                selectedCategoryID = categories.categories.first?.id
            }
            publishWidgetSummary()
        } catch let error as APIClientError where error.isUnauthorized {
            expireSession()
        } catch {
            errorMessage = "Categories could not be refreshed."
        }
    }

    private func reloadGoals() async {
        do {
            try await goals.reload()
        } catch let error as APIClientError where error.isUnauthorized {
            expireSession()
        } catch {
            errorMessage = "Goals could not be refreshed."
        }
    }

    private func expireSession() {
        guard !hasExpiredSession else { return }
        hasExpiredSession = true
        onAuthenticationExpired()
    }

    private func reloadLocalData() {
        do {
            runningTimer = try store.currentTimer(userID: userID)
            logs = try store.allLogs(userID: userID)
        } catch {
            errorMessage = "Saved logs are unavailable: \(error.localizedDescription)"
        }
    }

    private func publishWidgetSummary() {
        let syncedLogs = logs.filter { $0.syncState == .synced }
        let summary = ProductivitySummary(logs: summaryLogs(from: syncedLogs))
        WidgetSummaryStorage.publish(summary, for: userID, to: WidgetSummaryStorage.sharedDefaults)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSummaryStorage.widgetKind)
    }
}

enum ManualLogError: LocalizedError {
    case missingCategory
    case emptyDuration
    case endsInFuture

    var errorDescription: String? {
        switch self {
        case .missingCategory: "Choose a category."
        case .emptyDuration: "Enter how long you spent."
        case .endsInFuture: "That time hasn't happened yet. Choose an earlier start or a shorter duration."
        }
    }
}
