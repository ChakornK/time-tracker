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
    private var stoppedElsewhereObserver: (any NSObjectProtocol)?
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
            selectedCategoryID = defaultCategoryID
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

    /// Categories with the most recently logged first. Ones never logged follow in their usual order.
    var categoriesByRecency: [APICategory] {
        var lastLogged: [UUID: Date] = [:]
        for log in logs {
            for id in log.categoryIDs {
                lastLogged[id] = max(lastLogged[id] ?? .distantPast, log.endedAt)
            }
        }
        return categories.categories.enumerated()
            .sorted { lhs, rhs in
                switch (lastLogged[lhs.element.id], lastLogged[rhs.element.id]) {
                case let (left?, right?) where left != right: left > right
                case (.some, nil): true
                case (nil, .some): false
                default: lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// The category of the most recently finished log, so the next timer starts where the last one
    /// left off. Falls back to the first category when nothing has been logged.
    private var defaultCategoryID: UUID? {
        categoriesByRecency.first?.id
    }

    var canStart: Bool {
        categories.category(withID: selectedCategoryID) != nil && !categories.isCreating
    }

    private var trimmedNewCategoryName: String {
        newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func load() async {
        observeTimerStoppedElsewhere()
        reloadLocalData()
        publishWidgetSummary()
        await liveActivity.restore(runningTimer)
        activityState = runningTimer.flatMap { liveActivity.state(for: $0.id) }
        await refreshRemoteData()
    }

    /// The block keeps only a weak reference, so a signed-out session's model just stops reacting.
    private func observeTimerStoppedElsewhere() {
        guard stoppedElsewhereObserver == nil else { return }
        stoppedElsewhereObserver = NotificationCenter.default.addObserver(
            forName: .timerStoppedElsewhere,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.timerStoppedElsewhere() }
        }
    }

    private func timerStoppedElsewhere() async {
        reloadLocalData()
        selectedCategoryID = defaultCategoryID
        activityState = nil
        publishWidgetSummary()
        await synchronize()
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
        publishWidgetSummary()
        timerNotes = ""
        lastSavedDurationSeconds = nil
        errorMessage = nil
        await liveActivity.start(for: timer, colorHex: category.colorHex)
        activityState = liveActivity.state(for: timer.id)
    }

    func stop(at date: Date = .now) async {
        guard let timer = runningTimer else { return }
        do {
            let log = try store.stop(timerID: timer.id, userID: userID, endedAt: date)
            lastSavedDurationSeconds = log.durationSeconds
            errorMessage = nil
        } catch TimerStoreError.timerNotFound {
            // Usually already stopped and saved from the Live Activity. Clean up here too, in case the
            // timer went away some other way and no notification follows.
            reloadLocalData()
            await liveActivity.end(timerID: timer.id)
            activityState = nil
            publishWidgetSummary()
            return
        } catch {
            stopFailureMessage = error.localizedDescription
            return
        }
        reloadLocalData()
        selectedCategoryID = defaultCategoryID
        publishWidgetSummary()
        await liveActivity.end(timerID: timer.id)
        activityState = nil
        await synchronize()
    }

    /// Edits or deletes one of the user's logs, wherever it lives: on the server, on this device, or
    /// both. Insights, goals and the widget all read `logs`, so reloading it updates them.
    /// - Parameters:
    ///   - localID: The log on this device, if the change starts from one.
    ///   - serverID: The log on the server, for feed entries that may not be on this device.
    func changeLog(_ change: LogChange, localID: UUID?, serverID: UUID?) async throws {
        let local = logs.first { log in
            (localID != nil && log.id == localID) || (serverID != nil && log.serverID == serverID)
        }
        guard let route = local?.changeRoute ?? serverID.map({ LogChangeRoute.server(id: $0) }) else {
            throw LogChangeError.notFound
        }

        if change == .removeFromDevice {
            guard let local else { throw LogChangeError.notFound }
            try store.removeFromDevice(id: local.id, userID: userID)
            reloadLocalData()
            publishWidgetSummary()
            return
        }

        switch route {
        case .waitForSync:
            throw TimerStoreError.logAwaitingSync
        case .server(let id):
            do {
                switch change {
                case .edit(let edit): try await api.updateLog(id: id, edit: edit, accessToken: token)
                case .delete, .removeFromDevice: try await api.deleteLog(id: id, accessToken: token)
                }
            } catch APIClientError.server(404, _) where change == .delete {
                // Already gone, for example deleted from another device.
            } catch APIClientError.server(404, _) {
                throw LogChangeError.notFound
            } catch let error as APIClientError where error.isUnauthorized {
                expireSession()
                throw error
            } catch let error as APIClientError where LogSyncCoordinator.isDefiniteRejection(error) {
                throw LogChangeError.rejected
            } catch APIClientError.server(let statusCode, _) where statusCode >= 500 {
                throw LogChangeError.serverError
            } catch {
                throw LogChangeError.offline
            }
        case .localOnly:
            break
        }

        if let local {
            switch change {
            case .edit(let edit): try store.updateLog(id: local.id, userID: userID, edit: edit)
            case .delete, .removeFromDevice: try store.deleteLog(id: local.id, userID: userID)
            }
        }
        reloadLocalData()
        publishWidgetSummary()
        // A log fixed on the device, such as one the server had rejected, can be sent right away.
        if route == .localOnly, change != .delete {
            await synchronize()
        }
    }

    /// Throws away the running timer without saving a log, for one started by mistake.
    func discardRunningTimer() async {
        guard let timer = runningTimer else { return }
        do {
            try store.discardTimer(timerID: timer.id, userID: userID)
        } catch TimerStoreError.timerNotFound {
            // Stopped from the Live Activity a moment ago, which saved its time.
            reloadLocalData()
            errorMessage = "The timer had already stopped and its time was saved. Delete it from My logs if you don't want it."
            return
        } catch {
            errorMessage = "The timer could not be discarded. Try again."
            return
        }
        reloadLocalData()
        await liveActivity.end(timerID: timer.id)
        activityState = nil
        publishWidgetSummary()
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
                selectedCategoryID = defaultCategoryID
            }
            if let timer = runningTimer {
                await liveActivity.updateColor(
                    timerID: timer.id,
                    colorHex: categories.category(withID: timer.categoryIDs.first)?.colorHex
                )
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

    /// Hands the widget every finished log, synced or not, so its totals match the app even offline,
    /// plus the running timer so it can tick.
    private func publishWidgetSummary() {
        let finished = logs.filter { $0.syncState != .running }
        let running = runningTimer.map { timer in
            WidgetSnapshot.RunningTimer(
                startedAt: timer.startedAt,
                title: categories.category(withID: timer.categoryIDs.first)?.name ?? timer.title,
                colorHex: categories.category(withID: timer.categoryIDs.first)?.colorHex
            )
        }
        let snapshot = WidgetSnapshot(logs: summaryLogs(from: finished), runningTimer: running)
        WidgetSummaryStorage.publish(snapshot, for: userID, to: WidgetSummaryStorage.sharedDefaults)
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

enum LogChange: Equatable {
    case edit(LogEdit)
    case delete
    /// Drops a log stuck waiting to sync from this device only, so it's never sent again.
    case removeFromDevice
}

enum LogChangeError: LocalizedError {
    case notFound
    case rejected
    case serverError
    case offline

    var errorDescription: String? {
        switch self {
        case .notFound: "This log no longer exists. Pull to refresh."
        case .rejected: "The server didn't accept that change. Check the times and category and try again."
        case .serverError: "The server had a problem saving that change. Try again in a moment."
        case .offline: "The change couldn't reach the server. Check your connection and try again."
        }
    }
}
