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

struct SocialFeedView: View {
    @State private var model: SocialFeedModel
    private let api: TrackerAPIClient
    private let token: String

    init(api: TrackerAPIClient, token: String) {
        self.api = api
        self.token = token
        _model = State(initialValue: SocialFeedModel(api: api, token: token))
    }

    var body: some View {
        content
            .task { await model.loadFirstPage() }
            .navigationTitle("Activity")
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
        if model.isLoading && !model.hasLoaded {
            ProgressView("Loading activity")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty, let errorMessage = model.errorMessage {
            ContentUnavailableView {
                Label("Feed unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry") { Task { await model.loadFirstPage() } }
                    .frame(minHeight: 44)
            }
        } else if model.entries.isEmpty {
            // An empty List keeps pull-to-refresh available behind the empty state.
            List {}
                .overlay {
                    ContentUnavailableView {
                        Label("No activity yet", systemImage: "clock")
                    } description: {
                        Text("Follow people to see their public and friends-only activity here.")
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
                ForEach(model.entries) { entry in
                    FeedEntryRow(entry: entry)
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorMessage)
                        Button("Retry") { Task { await model.loadMore() } }
                            .frame(minHeight: 44)
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .refreshable { await model.loadFirstPage() }
        }
    }
}

private struct FeedEntryRow: View {
    let entry: FeedEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.author.displayName)
                        .font(.headline)
                    Text("@\(entry.author.username)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text(entry.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            Text(entry.title)
                .font(.title3.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if let notes = entry.notes, !notes.isEmpty {
                Text(notes)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Label {
                    DurationText(entry.durationSeconds)
                } icon: {
                    Image(systemName: "clock")
                        .accessibilityHidden(true)
                }
                if !entry.categories.isEmpty {
                    Text(entry.categories.map(\.name).joined(separator: ", "))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
