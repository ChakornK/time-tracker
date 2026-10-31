import SwiftUI

@MainActor
@Observable
final class FollowManagementModel {
    let social: SocialStore
    private(set) var results: [SocialUser] = []
    private(set) var requests: [FollowRequest] = []
    private(set) var following: [FollowingUser] = []
    private(set) var followers: [FollowerUser] = []
    private(set) var isSearching = false
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var busyUserIDs: Set<UUID> = []
    private(set) var searchedQuery: String?
    private(set) var errorMessage: String?
    var username = ""

    init(social: SocialStore) {
        self.social = social
    }

    private var api: TrackerAPIClient { social.api }
    private var token: String { social.token }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            async let requests = api.followRequests(accessToken: token)
            async let following = api.following(accessToken: token)
            async let followers = api.followers(accessToken: token)
            (self.requests, self.following, self.followers) = try await (requests, following, followers)
            errorMessage = nil
        } catch {
            errorMessage = "People could not be loaded. Pull to refresh."
        }
        await social.refresh()
    }

    /// Searches as the person types, once there are enough characters.
    func search() async {
        let query = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3 else {
            results = []
            searchedQuery = nil
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await api.searchUsers(username: query, accessToken: token)
            // A newer query may have started while this one was in flight.
            guard !Task.isCancelled else { return }
            results = found
            searchedQuery = query
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Search failed. Check your connection and try again."
        }
    }

    /// Follows, unfollows or withdraws a request, depending on where things stand.
    func toggleFollow(userID: UUID, from state: FollowState) async {
        await perform(on: userID, changesFollows: true, failure: "Could not update this follow. Try again.") { [api, token] in
            if state == .notFollowing {
                let status = try await api.follow(userID: userID, accessToken: token)
                self.setFollowState(FollowState(isFollowing: status == .following, isRequested: status == .requested), for: userID)
            } else {
                try await api.unfollow(userID: userID, accessToken: token)
                self.setFollowState(.notFollowing, for: userID)
            }
            self.following = try await api.following(accessToken: token)
        }
    }

    func accept(_ request: FollowRequest) async {
        await perform(on: request.id, changesFollows: true, failure: "Could not accept this request. Try again.") { [api, token] in
            try await api.acceptFollowRequest(from: request.id, accessToken: token)
            self.requests.removeAll { $0.id == request.id }
            self.followers = try await api.followers(accessToken: token)
        }
    }

    func decline(_ request: FollowRequest) async {
        await perform(on: request.id, changesFollows: false, failure: "Could not decline this request. Try again.") { [api, token] in
            try await api.declineFollowRequest(from: request.id, accessToken: token)
            self.requests.removeAll { $0.id == request.id }
        }
        // Declining changes no follows but does change the waiting-request count.
        await social.refresh()
    }

    func remove(_ follower: FollowerUser) async {
        await perform(on: follower.id, changesFollows: true, failure: "Could not remove this follower. Try again.") { [api, token] in
            try await api.removeFollower(userID: follower.id, accessToken: token)
            self.followers.removeAll { $0.id == follower.id }
        }
    }

    /// Runs one change for a person at a time; a second tap while it's running is ignored.
    private func perform(on userID: UUID, changesFollows: Bool, failure: String, _ change: () async throws -> Void) async {
        guard !busyUserIDs.contains(userID) else { return }
        busyUserIDs.insert(userID)
        defer { busyUserIDs.remove(userID) }
        do {
            try await change()
            errorMessage = nil
            if changesFollows {
                social.followsChanged()
            }
        } catch {
            errorMessage = failure
        }
    }

    private func setFollowState(_ state: FollowState, for userID: UUID) {
        if let index = results.firstIndex(where: { $0.id == userID }) {
            results[index].isFollowing = state == .following
            results[index].isRequested = state == .requested
        }
        if let index = followers.firstIndex(where: { $0.id == userID }) {
            followers[index].isFollowing = state == .following
            followers[index].isRequested = state == .requested
        }
    }
}

/// Follow requests, finding people, and the people you follow and who follow you.
struct FollowManagementView: View {
    @State private var model: FollowManagementModel
    @State private var removingFollower: FollowerUser?

    init(social: SocialStore) {
        _model = State(initialValue: FollowManagementModel(social: social))
    }

    var body: some View {
        List {
            if !model.requests.isEmpty {
                Section("Requests") {
                    ForEach(model.requests) { request in
                        PersonRow(social: model.social, userID: request.id, displayName: request.displayName, username: request.username) {
                            HStack(spacing: 8) {
                                Button("Accept") { Task { await model.accept(request) } }
                                    .buttonStyle(.borderedProminent)
                                Button("Decline") { Task { await model.decline(request) } }
                                    .buttonStyle(.bordered)
                            }
                            .controlSize(.small)
                            .frame(minHeight: 44)
                            .disabled(model.busyUserIDs.contains(request.id))
                        }
                    }
                }
            }

            Section("Find people") {
                TextField("Search by username", text: $model.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)

                if model.isSearching && model.results.isEmpty {
                    ProgressView("Searching")
                } else if let query = model.searchedQuery, model.results.isEmpty {
                    Text("No one matches \u{201C}\(query)\u{201D}.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.results) { user in
                        let state = FollowState(isFollowing: user.isFollowing, isRequested: user.isRequested)
                        PersonRow(social: model.social, userID: user.id, displayName: user.displayName, username: user.username, isPrivate: user.isPrivate) {
                            FollowButton(state: state, isBusy: model.busyUserIDs.contains(user.id)) {
                                Task { await model.toggleFollow(userID: user.id, from: state) }
                            }
                        }
                    }
                }
            }

            Section("Following") {
                if !model.hasLoaded {
                    ProgressView("Loading")
                } else if model.following.isEmpty {
                    Text("You aren't following anyone yet. Search above to find people.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.following) { user in
                        PersonRow(social: model.social, userID: user.id, displayName: user.displayName, username: user.username) {
                            FollowButton(state: .following, isBusy: model.busyUserIDs.contains(user.id)) {
                                Task { await model.toggleFollow(userID: user.id, from: .following) }
                            }
                        }
                    }
                }
            }

            Section("Followers") {
                if !model.hasLoaded {
                    ProgressView("Loading")
                } else if model.followers.isEmpty {
                    Text("No one follows you yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.followers) { follower in
                        let state = FollowState(isFollowing: follower.isFollowing, isRequested: follower.isRequested)
                        PersonRow(social: model.social, userID: follower.id, displayName: follower.displayName, username: follower.username) {
                            // Someone you already follow back needs no button here; they're under Following.
                            if state != .following {
                                FollowButton(state: state, followsYou: true, isBusy: model.busyUserIDs.contains(follower.id)) {
                                    Task { await model.toggleFollow(userID: follower.id, from: state) }
                                }
                            }
                        }
                        .swipeActions {
                            Button("Remove", systemImage: "person.badge.minus") {
                                removingFollower = follower
                            }
                            .tint(.red)
                        }
                        .confirmationDialog(
                            "Remove \(follower.displayName)?",
                            isPresented: Binding(
                                get: { removingFollower?.id == follower.id },
                                set: { if !$0 { removingFollower = nil } }
                            ),
                            titleVisibility: .visible
                        ) {
                            Button("Remove follower", role: .destructive) {
                                Task { await model.remove(follower) }
                            }
                        } message: {
                            Text("They stop seeing your activity in their feed. They aren't told, and can follow you again.")
                        }
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    StatusBanner(kind: .error, message: errorMessage)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("People")
        .task { await model.load() }
        .refreshable { await model.load() }
        // Restarting on each keystroke cancels the previous wait, so only a pause in typing searches.
        .task(id: model.username) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await model.search()
        }
    }
}

/// A person who opens their profile when tapped, with an action such as a follow button beside them.
private struct PersonRow<Action: View>: View {
    let social: SocialStore
    let userID: UUID
    let displayName: String
    let username: String
    var isPrivate = false
    @ViewBuilder let action: Action

    var body: some View {
        HStack {
            NavigationLink {
                UserProfileView(social: social, userID: userID)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(displayName)
                            .font(.headline)
                        if isPrivate {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Private account")
                        }
                    }
                    Text("@\(username)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            action
                .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
    }
}
