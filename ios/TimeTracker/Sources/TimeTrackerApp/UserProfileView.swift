import SwiftUI

@MainActor
@Observable
final class UserProfileModel {
    let social: SocialStore
    let userID: UUID
    private(set) var profile: UserProfile?
    private(set) var entries: [FeedEntry] = []
    private(set) var nextCursor: String?
    private(set) var isLoadingMore = false
    private(set) var isUpdatingFollow = false
    /// Counts loads, so a next page fetched before a refresh is dropped rather than appended.
    private var loadGeneration = 0
    private(set) var errorMessage: String?

    init(social: SocialStore, userID: UUID) {
        self.social = social
        self.userID = userID
    }

    private var api: TrackerAPIClient { social.api }
    private var token: String { social.token }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let profile = try await api.userProfile(id: userID, accessToken: token)
            guard generation == loadGeneration else { return }
            self.profile = profile
            if profile.canViewLogs {
                let page = try await api.userLogs(id: userID, accessToken: token)
                guard generation == loadGeneration else { return }
                social.absorb(page.items)
                entries = page.items
                nextCursor = page.nextCursor
            } else {
                entries = []
                nextCursor = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = "This profile could not be loaded. Pull to refresh."
        }
    }

    func loadMore() async {
        guard !isLoadingMore, let nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = loadGeneration
        do {
            let page = try await api.userLogs(id: userID, accessToken: token, cursor: nextCursor)
            guard generation == loadGeneration else { return }
            social.absorb(page.items)
            var seen = Set(entries.map(\.id))
            entries.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
            self.nextCursor = page.nextCursor
        } catch {
            errorMessage = "More activity could not be loaded. Try again."
        }
    }

    func toggleFollow() async {
        guard let profile, !isUpdatingFollow else { return }
        isUpdatingFollow = true
        defer { isUpdatingFollow = false }
        do {
            let relationship = profile.relationship
            if relationship.isFollowing || relationship.isRequested {
                try await api.unfollow(userID: userID, accessToken: token)
            } else {
                try await api.follow(userID: userID, accessToken: token)
            }
            social.followsChanged()
            // Following can open the log list and changes the counts, so the whole profile reloads.
            await load()
        } catch {
            errorMessage = "Could not update this follow. Try again."
        }
    }

    func toggleKudos(on entry: FeedEntry) async {
        do {
            try await social.toggleKudos(on: entry)
        } catch {
            errorMessage = "Kudos could not be saved. Try again."
        }
    }
}

/// Someone else's profile: who they are, how you're connected, and the logs you can see.
struct UserProfileView: View {
    @State private var model: UserProfileModel
    @State private var commentsEntry: EntryLink?

    init(social: SocialStore, userID: UUID) {
        _model = State(initialValue: UserProfileModel(social: social, userID: userID))
    }

    var body: some View {
        List {
            if let profile = model.profile {
                header(profile)
                logs(profile)
            } else if model.errorMessage == nil {
                ProgressView("Loading profile")
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }

            if let errorMessage = model.errorMessage {
                StatusBanner(kind: .error, message: errorMessage)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(model.profile.map { "@\($0.username)" } ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .navigationDestination(item: $commentsEntry) { link in
            LogDetailView(social: model.social, entry: link.entry)
        }
    }

    @ViewBuilder
    private func header(_ profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.title2.weight(.semibold))
                    if profile.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Private account")
                    }
                }
                HStack(spacing: 6) {
                    Text("@\(profile.username)")
                    if profile.relationship.followsYou {
                        Text("Follows you")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                countLabel(profile.followerCount, singular: "follower", plural: "followers")
                countLabel(profile.followingCount, singular: "following", plural: "following")
                Spacer(minLength: 8)
                if profile.id != model.social.viewerID {
                    FollowButton(
                        state: FollowState(isFollowing: profile.relationship.isFollowing, isRequested: profile.relationship.isRequested),
                        followsYou: profile.relationship.followsYou,
                        isBusy: model.isUpdatingFollow
                    ) {
                        Task { await model.toggleFollow() }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
    }

    private func countLabel(_ count: Int, singular: String, plural: String) -> some View {
        Text("\(Text("\(count)").fontWeight(.semibold)) \(Text(count == 1 ? singular : plural).foregroundStyle(.secondary))")
            .font(.subheadline)
    }

    @ViewBuilder
    private func logs(_ profile: UserProfile) -> some View {
        if !profile.canViewLogs {
            ContentUnavailableView {
                Label("This account is private", systemImage: "lock")
            } description: {
                Text(profile.relationship.isRequested
                    ? "Your follow request is waiting for \(profile.displayName) to accept it."
                    : "Follow \(profile.displayName) to see their activity.")
            }
            .listRowSeparator(.hidden)
        } else if model.entries.isEmpty {
            ContentUnavailableView(
                "No activity yet",
                systemImage: "clock",
                description: Text("Logs \(profile.displayName) shares with you appear here.")
            )
            .listRowSeparator(.hidden)
        } else {
            ForEach(model.entries) { entry in
                VStack(alignment: .leading, spacing: 10) {
                    LogRow(content: LogRowContent(entry: entry, viewerID: model.social.viewerID))
                    LogSocialBar(
                        entry: model.social.current(entry),
                        isYours: entry.author.id == model.social.viewerID,
                        isKudosBusy: model.social.kudosInFlight.contains(entry.id),
                        onKudos: { Task { await model.toggleKudos(on: entry) } },
                        onComments: { commentsEntry = EntryLink(entry: entry) }
                    )
                }
                .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 10, trailing: 20))
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
        }
    }
}
