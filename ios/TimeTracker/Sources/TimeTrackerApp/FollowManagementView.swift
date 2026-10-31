import SwiftUI

@MainActor
@Observable
final class FollowManagementModel {
    private let api: TrackerAPIClient
    private let token: String
    private let onFollowsChanged: () -> Void
    private(set) var results: [SocialUser] = []
    private(set) var following: [FollowingUser] = []
    private(set) var isSearching = false
    private(set) var isLoadingFollowing = false
    private(set) var updatingUserID: UUID?
    private(set) var hasSearched = false
    private(set) var errorMessage: String?
    var username = ""

    init(api: TrackerAPIClient, token: String, onFollowsChanged: @escaping () -> Void) {
        self.api = api
        self.token = token
        self.onFollowsChanged = onFollowsChanged
    }

    func loadFollowing() async {
        guard !isLoadingFollowing else { return }
        isLoadingFollowing = true
        defer { isLoadingFollowing = false }
        do {
            following = try await api.following(accessToken: token)
        } catch {
            errorMessage = "Following list could not be loaded. Try again."
        }
    }

    func search() async {
        let query = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3 else {
            errorMessage = "Enter at least three username characters."
            return
        }
        isSearching = true
        hasSearched = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            results = try await api.searchUsers(username: query, accessToken: token)
        } catch {
            errorMessage = "Users could not be searched. Check your connection and try again."
        }
    }

    func setFollowing(_ shouldFollow: Bool, userID: UUID) async {
        updatingUserID = userID
        errorMessage = nil
        defer { updatingUserID = nil }
        do {
            if shouldFollow {
                try await api.follow(userID: userID, accessToken: token)
            } else {
                try await api.unfollow(userID: userID, accessToken: token)
            }
            onFollowsChanged()
            if let index = results.firstIndex(where: { $0.id == userID }) {
                results[index].isFollowing = shouldFollow
            }
            await loadFollowing()
        } catch {
            errorMessage = shouldFollow ? "Could not follow this account. Try again." : "Could not unfollow this account. Try again."
        }
    }
}

struct FollowManagementView: View {
    @State private var model: FollowManagementModel

    /// - Parameter onFollowsChanged: Runs after a follow or unfollow, so the feed can reload.
    init(api: TrackerAPIClient, token: String, onFollowsChanged: @escaping () -> Void) {
        _model = State(initialValue: FollowManagementModel(api: api, token: token, onFollowsChanged: onFollowsChanged))
    }

    var body: some View {
        List {
            Section("Find people") {
                HStack(spacing: 10) {
                    TextField("Username", text: $model.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await model.search() } }

                    Button(model.isSearching ? "Searching" : "Search") {
                        Task { await model.search() }
                    }
                    .frame(minWidth: 64, minHeight: 44)
                    .disabled(model.isSearching)
                }

                if model.isSearching {
                    ProgressView("Searching usernames")
                } else if model.hasSearched && model.results.isEmpty && model.errorMessage == nil {
                    Text("No accounts matched. Try another username.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.results) { user in
                        PersonRow(displayName: user.displayName, username: user.username) {
                            Button(followButtonTitle(for: user)) {
                                Task { await model.setFollowing(!user.isFollowing, userID: user.id) }
                            }
                            .frame(minWidth: 82, minHeight: 44)
                            .disabled(model.updatingUserID != nil)
                        }
                    }
                }
            }

            Section("Following") {
                if model.isLoadingFollowing && model.following.isEmpty {
                    ProgressView("Loading followed accounts")
                } else if model.following.isEmpty {
                    Text("You are not following anyone yet. Search by username above to find people.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.following) { user in
                        PersonRow(displayName: user.displayName, username: user.username) {
                            Button("Unfollow") {
                                Task { await model.setFollowing(false, userID: user.id) }
                            }
                            .frame(minWidth: 82, minHeight: 44)
                            .disabled(model.updatingUserID != nil)
                        }
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                Section("Could not update people") {
                    Text(errorMessage)
                    Button("Reload following") { Task { await model.loadFollowing() } }
                        .frame(minHeight: 44)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("People")
        .task { await model.loadFollowing() }
    }

    private func followButtonTitle(for user: SocialUser) -> String {
        if model.updatingUserID == user.id { return "Saving" }
        return user.isFollowing ? "Following" : "Follow"
    }
}

private struct PersonRow<Action: View>: View {
    let displayName: String
    let username: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.headline)
                Text("@\(username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            action
        }
        .accessibilityElement(children: .contain)
    }
}
