import SwiftUI

@MainActor
@Observable
final class SocialFeedModel {
    private let social: SocialStore
    private(set) var entries: [FeedEntry] = []
    private(set) var nextCursor: String?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private var isRefreshingNewest = false
    private var needsNewestRefresh = false
    /// A full reload asked for while a load was running, replayed once it finishes.
    private var needsReload = false
    /// Counts first-page loads, so a newest-refresh or next page fetched before one is dropped
    /// instead of mixing the old feed back into the new one.
    private var loadGeneration = 0

    init(social: SocialStore) {
        self.social = social
    }

    private var api: TrackerAPIClient { social.api }
    private var token: String { social.token }

    func loadFirstPage() async {
        guard !isLoading else {
            // Replayed once this load finishes, so a log that synced meanwhile isn't missed.
            needsNewestRefresh = true
            return
        }
        isLoading = true
        // This load already includes anything that synced before it, so only later requests replay.
        needsNewestRefresh = false
        needsReload = false
        loadGeneration += 1
        errorMessage = nil
        do {
            let page = try await api.feedPage(accessToken: token)
            social.absorb(page.items)
            entries = page.items
            nextCursor = page.nextCursor
        } catch {
            errorMessage = "The feed could not be loaded. Check your connection and try again."
        }
        isLoading = false
        hasLoaded = true
        if needsReload {
            await loadFirstPage()
        } else if needsNewestRefresh {
            await refreshNewest()
        }
    }

    /// Replaces everything loaded, for when whose logs belong in the feed changes, such as after a
    /// follow: a followed person's older logs belong further down, so they can't just be prepended.
    func reload() async {
        guard !isLoading else {
            needsReload = true
            return
        }
        await loadFirstPage()
    }

    /// Adds logs newer than the ones already shown, keeping everything loaded so far so the list
    /// doesn't jump back to the top. A request made while one is running is replayed afterward, so a
    /// log that syncs mid-request still arrives.
    func refreshNewest() async {
        guard hasLoaded, !entries.isEmpty else { return await loadFirstPage() }
        guard !isRefreshingNewest else {
            needsNewestRefresh = true
            return
        }
        isRefreshingNewest = true
        defer { isRefreshingNewest = false }
        repeat {
            needsNewestRefresh = false
            let generation = loadGeneration
            do {
                let page = try await api.feedPage(accessToken: token)
                guard generation == loadGeneration else { return }
                social.absorb(page.items)
                let known = Set(entries.map(\.id))
                if page.nextCursor != nil && !page.items.contains(where: { known.contains($0.id) }) {
                    // More than a page arrived since the last load, so there would be a gap below it.
                    entries = page.items
                    nextCursor = page.nextCursor
                } else {
                    entries.insert(contentsOf: page.items.filter { !known.contains($0.id) }, at: 0)
                }
                errorMessage = nil
            } catch {
                errorMessage = "New activity could not be loaded. Pull to refresh."
            }
        } while needsNewestRefresh
    }

    /// Shows an entry after its owner edits it, without reloading the feed.
    func replace(_ entry: FeedEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        }
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func toggleKudos(on entry: FeedEntry) async {
        do {
            try await social.toggleKudos(on: entry)
        } catch {
            errorMessage = "Kudos could not be saved. Try again."
        }
    }

    func loadMore() async {
        guard !isLoadingMore, let nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = loadGeneration
        do {
            let page = try await api.feedPage(accessToken: token, cursor: nextCursor)
            guard generation == loadGeneration else { return }
            social.absorb(page.items)
            var seen = Set(entries.map(\.id))
            entries.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
            self.nextCursor = page.nextCursor
            errorMessage = nil
        } catch {
            errorMessage = "More activity could not be loaded. Try again."
        }
    }

}

/// Your logs and the logs of people you follow, newest first. Your logs that haven't synced yet
/// come from this device and sit at the top until the server has them.
struct SocialFeedView: View {
    @State private var model: SocialFeedModel
    private let social: SocialStore
    private let localLogs: [LocalActivityLog]
    private let categories: [APICategory]
    private let changeLog: LogChanger
    @State private var logActions = LogActionState()
    @State private var profileUserID: UUID?
    @State private var commentsEntry: EntryLink?

    init(
        social: SocialStore,
        localLogs: [LocalActivityLog],
        categories: [APICategory],
        changeLog: @escaping LogChanger
    ) {
        self.social = social
        self.localLogs = localLogs
        self.categories = categories
        self.changeLog = changeLog
        _model = State(initialValue: SocialFeedModel(social: social))
    }

    private var viewerID: UUID { social.viewerID }

    private var pendingRequests: Int { social.summary?.pendingRequestCount ?? 0 }

    /// A running timer lives on the Timer tab, and a synced log arrives with the server's feed.
    private var unsyncedLogs: [LocalActivityLog] {
        localLogs
            .filter { $0.syncState == .pending || $0.syncState == .syncing }
            .sorted { $0.endedAt > $1.endedAt }
    }

    var body: some View {
        content
            .task { await model.loadFirstPage() }
            .task { await social.refresh() }
            // A follow made on any screen changes whose logs belong here.
            .onChange(of: social.followsVersion) {
                Task { await model.reload() }
            }
            .navigationDestination(item: $profileUserID) { userID in
                UserProfileView(social: social, userID: userID)
            }
            .navigationDestination(item: $commentsEntry) { link in
                LogDetailView(social: social, entry: link.entry)
            }
            // A log that syncs leaves the device list, so fetch the server's copy.
            .onChange(of: unsyncedLogs.map(\.id)) { old, new in
                if !Set(old).isSubset(of: Set(new)) {
                    Task { await model.refreshNewest() }
                }
            }
            .navigationTitle("Feed")
            .logActionPresentations(state: $logActions, categories: categories, change: changeLog) { target, change in
                guard let serverID = target.serverID else { return }
                switch change {
                case .removeFromDevice:
                    // Only the device's copy went; a server copy, if any, now shows in its place.
                    break
                case .delete:
                    model.remove(id: serverID)
                case .edit(let edit):
                    guard let entry = model.entries.first(where: { $0.id == serverID }) else { return }
                    let entryCategories = categories
                        .filter { edit.categoryIDs.contains($0.id) }
                        .map { FeedEntry.Category(id: $0.id, name: $0.name, colorHex: $0.colorHex) }
                    model.replace(entry.applying(edit, categories: entryCategories))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        FollowManagementView(social: social)
                    } label: {
                        Label("People", systemImage: "person.2")
                            .overlay(alignment: .topTrailing) {
                                if pendingRequests > 0 {
                                    Text("\(pendingRequests)")
                                        .font(.caption2.weight(.bold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .frame(minWidth: 18, minHeight: 18)
                                        .background(.red, in: .capsule)
                                        .offset(x: 10, y: -8)
                                }
                            }
                    }
                    .accessibilityLabel("People")
                    .accessibilityValue(pendingRequests > 0 ? "\(pendingRequests) follow requests" : "")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded && unsyncedLogs.isEmpty {
            ProgressView("Loading feed")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty && unsyncedLogs.isEmpty, let errorMessage = model.errorMessage {
            ContentUnavailableView {
                Label("Feed unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry") { Task { await model.loadFirstPage() } }
                    .frame(minHeight: 44)
            }
        } else if model.entries.isEmpty && unsyncedLogs.isEmpty {
            // An empty List keeps pull-to-refresh available behind the empty state.
            List {}
                .overlay {
                    ContentUnavailableView {
                        Label("Nothing here yet", systemImage: "clock")
                    } description: {
                        Text("Time you log appears here, along with activity from people you follow.")
                    } actions: {
                        NavigationLink {
                            FollowManagementView(social: social)
                        } label: {
                            Text("Find people")
                                .frame(minWidth: 120, minHeight: 44)
                        }
                        .primaryActionStyle()
                    }
                }
                .refreshable { await model.loadFirstPage() }
        } else {
            List {
                ForEach(unsyncedLogs) { log in
                    LogRow(content: LogRowContent(log: log, categories: categories, author: .you, time: .relative(log.endedAt)))
                        .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
                        .logSwipeActions(LogTarget(log: log), state: $logActions)
                }
                // A log whose send reached the server but whose reply was lost shows once, as the
                // device's row, until its retry confirms it.
                let unsyncedKeys = Set(unsyncedLogs.map(\.idempotencyKey))
                let visibleEntries = model.entries.filter { $0.idempotencyKey.map { !unsyncedKeys.contains($0) } ?? true }
                ForEach(visibleEntries) { entry in
                    let isYours = entry.author.id == viewerID
                    VStack(alignment: .leading, spacing: 8) {
                        LogRow(
                            content: LogRowContent(entry: entry, viewerID: viewerID),
                            onOpenAuthor: isYours ? nil : { profileUserID = entry.author.id },
                            showsVisibility: false
                        )
                        LogSocialBar(
                            entry: social.current(entry),
                            isYours: isYours,
                            isKudosBusy: social.kudosInFlight.contains(entry.id),
                            visibility: isYours ? entry.visibility : nil,
                            onKudos: { Task { await model.toggleKudos(on: entry) } },
                            onComments: { commentsEntry = EntryLink(entry: entry) }
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                    .modifier(OwnLogSwipeActions(
                        target: entry.author.id == viewerID ? LogTarget(entry: entry, localLogs: localLogs) : nil,
                        state: $logActions
                    ))
                    .task {
                        // The last visible row, since the last loaded entry may be hidden above.
                        if entry.id == visibleEntries.last?.id {
                            await model.loadMore()
                        }
                    }
                }
                if model.isLoadingMore || (!model.hasLoaded && model.entries.isEmpty) {
                    ProgressView(model.hasLoaded ? "Loading more activity" : "Loading feed")
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
                if let errorMessage = model.errorMessage {
                    StatusBanner(kind: .error, message: errorMessage, actionTitle: "Retry") {
                        Task {
                            if model.entries.isEmpty {
                                await model.loadFirstPage()
                            } else {
                                await model.loadMore()
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            // Logs on this device change outside `withAnimation`, such as one deleted from the list.
            .animation(.snappy, value: unsyncedLogs.map(\.id))
            .refreshable { await model.loadFirstPage() }
        }
    }
}

/// Swipe actions only on the viewer's own entries; other people's logs can't be changed.
private struct OwnLogSwipeActions: ViewModifier {
    let target: LogTarget?
    @Binding var state: LogActionState

    func body(content: Content) -> some View {
        if let target {
            content.logSwipeActions(target, state: $state)
        } else {
            content
        }
    }
}
