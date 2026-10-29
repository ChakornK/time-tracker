import SwiftUI

@MainActor
@Observable
final class SocialFeedModel {
    private let api: TrackerAPIClient
    private let token: String
    private(set) var entries: [FeedEntry] = []
    private(set) var nextCursor: String?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    init(api: TrackerAPIClient, token: String) {
        self.api = api
        self.token = token
    }

    func loadFirstPage() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            let page = try await api.feedPage(accessToken: token)
            entries = page.items
            nextCursor = page.nextCursor
        } catch {
            errorMessage = "The feed could not be loaded. Check your connection and try again."
        }
    }

    func loadMore() async {
        guard !isLoadingMore, let nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.feedPage(accessToken: token, cursor: nextCursor)
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
    private let api: TrackerAPIClient
    private let token: String
    private let viewerID: UUID
    private let localLogs: [LocalActivityLog]
    private let categories: [APICategory]

    init(api: TrackerAPIClient, token: String, viewerID: UUID, localLogs: [LocalActivityLog], categories: [APICategory]) {
        self.api = api
        self.token = token
        self.viewerID = viewerID
        self.localLogs = localLogs
        self.categories = categories
        _model = State(initialValue: SocialFeedModel(api: api, token: token))
    }

    /// A running timer lives on the Timer tab, and a synced log arrives with the server's feed.
    private var unsyncedLogs: [LocalActivityLog] {
        localLogs
            .filter { $0.syncState == .pending || $0.syncState == .syncing }
            .sorted { $0.endedAt > $1.endedAt }
    }

    var body: some View {
        content
            .task { await model.loadFirstPage() }
            // Once a log syncs it leaves the device list, so reload to pick up the server's copy.
            .onChange(of: unsyncedLogs.map(\.id)) { old, new in
                if new.count < old.count {
                    Task { await model.loadFirstPage() }
                }
            }
            .navigationTitle("Feed")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        FollowManagementView(api: api, token: token)
                    } label: {
                        Label("People", systemImage: "person.2")
                    }
                    .accessibilityLabel("Manage people you follow")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && !model.hasLoaded && unsyncedLogs.isEmpty {
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
                            FollowManagementView(api: api, token: token)
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
                }
                ForEach(model.entries) { entry in
                    LogRow(content: LogRowContent(entry: entry, viewerID: viewerID))
                        .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
                        .task {
                            if entry.id == model.entries.last?.id {
                                await model.loadMore()
                            }
                        }
                }
                if model.isLoadingMore {
                    ProgressView("Loading more activity")
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
            .refreshable { await model.loadFirstPage() }
        }
    }
}
