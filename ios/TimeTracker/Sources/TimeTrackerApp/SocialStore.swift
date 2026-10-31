import SwiftUI

/// The signed-in person's side of the social graph, shared by the Feed, People, profiles, Profile
/// and Settings so a follow made on one screen shows on the others.
@MainActor
@Observable
final class SocialStore {
    let api: TrackerAPIClient
    let token: String
    let viewerID: UUID
    /// Counts, waiting requests and whether the account is private; nil until first loaded.
    private(set) var summary: SocialSummary?
    /// Changes whenever someone is followed or unfollowed here, so the feed knows to reload.
    private(set) var followsVersion = 0
    /// Kudos and comment counts changed on this device since the entry was last fetched, so every
    /// screen showing the entry agrees without reloading.
    private var counts: [UUID: EntryCounts] = [:]
    /// Counts summary requests, so a refresh sent before a privacy change can't undo it.
    private var summaryGeneration = 0
    /// Entries with a kudos request on its way, which ignore further taps until it answers.
    private(set) var kudosInFlight: Set<UUID> = []

    init(api: TrackerAPIClient, token: String, viewerID: UUID) {
        self.api = api
        self.token = token
        self.viewerID = viewerID
    }

    func refresh() async {
        summaryGeneration += 1
        let generation = summaryGeneration
        // A failed refresh keeps the last counts rather than blanking them.
        if let summary = try? await api.socialSummary(accessToken: token), generation == summaryGeneration {
            self.summary = summary
        }
    }

    /// Called after a follow, unfollow, accept or removal, which change whose logs the feed shows.
    func followsChanged() {
        followsVersion += 1
        Task { await refresh() }
    }

    func setPrivateAccount(_ isPrivate: Bool) async throws {
        summaryGeneration += 1
        summary = try await api.setPrivateAccount(isPrivate, accessToken: token)
        // Going public accepts waiting requests, which adds followers.
        followsChanged()
    }

    /// The entry with any counts changed on this device since it was fetched.
    func current(_ entry: FeedEntry) -> FeedEntry {
        guard let counts = counts[entry.id] else { return entry }
        var entry = entry
        entry.kudosCount = counts.kudosCount
        entry.viewerGaveKudos = counts.viewerGaveKudos
        entry.commentCount = counts.commentCount
        return entry
    }

    /// Freshly fetched entries carry the server's latest counts, which every screen then shows,
    /// including ones holding an older copy of the entry. An entry with a kudos request on its way
    /// keeps its local counts until that answers.
    func absorb(_ entries: [FeedEntry]) {
        for entry in entries where !kudosInFlight.contains(entry.id) {
            counts[entry.id] = EntryCounts(entry)
        }
    }

    /// Kudos on or off, shown at once and put back if the server refuses. A tap while a request
    /// for the same entry is still on its way is ignored.
    func toggleKudos(on entry: FeedEntry) async throws {
        guard !kudosInFlight.contains(entry.id) else { return }
        kudosInFlight.insert(entry.id)
        defer { kudosInFlight.remove(entry.id) }

        let before = EntryCounts(current(entry))
        var optimistic = before
        optimistic.viewerGaveKudos.toggle()
        optimistic.kudosCount = max(0, before.kudosCount + (before.viewerGaveKudos ? -1 : 1))
        counts[entry.id] = optimistic
        do {
            let kudos = before.viewerGaveKudos
                ? try await api.removeKudos(logID: entry.id, accessToken: token)
                : try await api.giveKudos(logID: entry.id, accessToken: token)
            // Only the kudos fields: the comment count may have changed meanwhile.
            counts[entry.id, default: before].kudosCount = kudos.kudosCount
            counts[entry.id, default: before].viewerGaveKudos = kudos.viewerGaveKudos
        } catch {
            counts[entry.id, default: before].kudosCount = before.kudosCount
            counts[entry.id, default: before].viewerGaveKudos = before.viewerGaveKudos
            throw error
        }
    }

    func setCommentCount(_ commentCount: Int, for entry: FeedEntry) {
        var updated = EntryCounts(current(entry))
        updated.commentCount = max(0, commentCount)
        counts[entry.id] = updated
    }
}

/// The parts of a feed entry that other people's kudos and comments change.
struct EntryCounts: Equatable {
    var kudosCount: Int
    var viewerGaveKudos: Bool
    var commentCount: Int

    init(_ entry: FeedEntry) {
        kudosCount = entry.kudosCount
        viewerGaveKudos = entry.viewerGaveKudos
        commentCount = entry.commentCount
    }
}

/// A feed entry to open, held as it was when tapped so the screen it opens doesn't depend on the
/// list it came from still containing it.
struct EntryLink: Hashable, Identifiable {
    let entry: FeedEntry

    var id: UUID { entry.id }

    static func == (lhs: EntryLink, rhs: EntryLink) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// How the viewer stands with someone, as a follow button shows it.
enum FollowState {
    case notFollowing
    case requested
    case following

    init(isFollowing: Bool, isRequested: Bool) {
        self = isFollowing ? .following : isRequested ? .requested : .notFollowing
    }
}

/// Follow, Requested or Following. Tapping Requested withdraws the request; tapping Following
/// unfollows.
struct FollowButton: View {
    let state: FollowState
    var followsYou = false
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Group {
            switch state {
            case .notFollowing:
                Button(followsYou ? "Follow back" : "Follow", action: action)
                    .buttonStyle(.borderedProminent)
            case .requested:
                Button("Requested", action: action)
                    .buttonStyle(.bordered)
                    .accessibilityHint("Withdraws your follow request")
            case .following:
                Button("Following", action: action)
                    .buttonStyle(.bordered)
                    .accessibilityHint("Unfollows")
            }
        }
        .controlSize(.small)
        .frame(minHeight: 44)
        .disabled(isBusy)
    }
}

/// Kudos and comment counts under a feed entry. Kudos can't be given to your own logs, so on those
/// the count is shown without a button.
struct LogSocialBar: View {
    let entry: FeedEntry
    let isYours: Bool
    var isKudosBusy = false
    let onKudos: () -> Void
    let onComments: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            if isYours {
                Label("\(entry.kudosCount)", systemImage: "hands.clap")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(entry.kudosCount) kudos")
            } else {
                Button(action: onKudos) {
                    Label("\(entry.kudosCount)", systemImage: entry.viewerGaveKudos ? "hands.clap.fill" : "hands.clap")
                        .foregroundStyle(entry.viewerGaveKudos ? Color.orange : .secondary)
                }
                .accessibilityLabel(entry.viewerGaveKudos ? "Remove kudos" : "Give kudos")
                .accessibilityValue("\(entry.kudosCount) kudos")
                .disabled(isKudosBusy)
                .sensoryFeedback(.impact(weight: .light), trigger: entry.viewerGaveKudos)
            }
            Button(action: onComments) {
                Label("\(entry.commentCount)", systemImage: "bubble.left")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Comments")
            .accessibilityValue("\(entry.commentCount)")
            Spacer(minLength: 0)
        }
        .font(.subheadline.monospacedDigit())
        .labelStyle(.titleAndIcon)
        // Each button takes its own taps instead of the whole list row.
        .buttonStyle(.borderless)
        .frame(minHeight: 32)
    }
}
