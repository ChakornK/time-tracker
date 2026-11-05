import SwiftUI

@MainActor
@Observable
final class LogDetailModel {
    /// The server's limit on a comment's length.
    static let maxCommentLength = 500

    let social: SocialStore
    /// The entry as it was opened; its counts come from `social` so other screens stay in step.
    private let openedEntry: FeedEntry
    private(set) var comments: [LogComment] = []
    private(set) var nextCursor: String?
    private(set) var hasLoaded = false
    private(set) var isLoadingMore = false
    private(set) var isSending = false
    /// The log was deleted or is no longer visible to the viewer.
    private(set) var isUnavailable = false
    private(set) var errorMessage: String?
    var draft = ""
    /// Counts loads, so a next page fetched before a refresh is dropped rather than appended.
    private var loadGeneration = 0

    init(social: SocialStore, entry: FeedEntry) {
        self.social = social
        openedEntry = entry
    }

    private var api: TrackerAPIClient { social.api }
    private var token: String { social.token }

    var entry: FeedEntry { social.current(openedEntry) }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isDraftTooLong: Bool { trimmedDraft.count > Self.maxCommentLength }

    var canSend: Bool {
        !isSending && !isUnavailable && !trimmedDraft.isEmpty && !isDraftTooLong
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let page = try await api.comments(logID: openedEntry.id, accessToken: token)
            guard generation == loadGeneration else { return }
            comments = page.comments
            nextCursor = page.nextCursor
            // With every comment loaded, the count is known exactly, including other people's.
            if page.nextCursor == nil {
                social.setCommentCount(page.comments.count, for: openedEntry)
            }
            errorMessage = nil
        } catch APIClientError.server(404, _) {
            isUnavailable = true
            comments = []
            nextCursor = nil
        } catch {
            errorMessage = "Comments could not be loaded. Pull to refresh."
        }
        hasLoaded = true
    }

    func loadMore() async {
        guard !isLoadingMore, let nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = loadGeneration
        do {
            let page = try await api.comments(logID: openedEntry.id, accessToken: token, cursor: nextCursor)
            guard generation == loadGeneration else { return }
            var seen = Set(comments.map(\.id))
            comments.append(contentsOf: page.comments.filter { seen.insert($0.id).inserted })
            self.nextCursor = page.nextCursor
            if page.nextCursor == nil {
                social.setCommentCount(comments.count, for: openedEntry)
            }
        } catch {
            errorMessage = "More comments could not be loaded. Try again."
        }
    }

    func send() async {
        let sent = draft
        let body = trimmedDraft
        guard canSend else { return }
        isSending = true
        defer { isSending = false }
        let generation = loadGeneration
        do {
            let comment = try await api.addComment(body, logID: openedEntry.id, accessToken: token)
            // Text typed while the comment was posting is kept.
            if draft == sent {
                draft = ""
            }
            errorMessage = nil
            if generation != loadGeneration {
                // A refresh ran while posting and may or may not include the comment, so load again
                // rather than guess at the list and count.
                await load()
            } else {
                // Shown at the end only once every earlier page is loaded; otherwise it arrives in order.
                if nextCursor == nil {
                    comments.append(comment)
                }
                social.setCommentCount(entry.commentCount + 1, for: openedEntry)
            }
        } catch APIClientError.server(404, _) {
            isUnavailable = true
        } catch {
            errorMessage = "Your comment could not be posted. Try again."
        }
    }

    func delete(_ comment: LogComment) async {
        do {
            try await api.deleteComment(id: comment.id, accessToken: token)
            comments.removeAll { $0.id == comment.id }
            social.setCommentCount(entry.commentCount - 1, for: openedEntry)
        } catch {
            errorMessage = "The comment could not be deleted. Try again."
        }
    }

    func toggleKudos() async {
        do {
            try await social.toggleKudos(on: openedEntry)
        } catch {
            errorMessage = "Kudos could not be saved. Try again."
        }
    }
}

/// A log with its kudos and comments, and a field to add a comment.
struct LogDetailView: View {
    @State private var model: LogDetailModel
    @FocusState private var isComposing: Bool

    init(social: SocialStore, entry: FeedEntry) {
        _model = State(initialValue: LogDetailModel(social: social, entry: entry))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    LogRow(
                        content: LogRowContent(entry: model.entry, viewerID: model.social.viewerID),
                        notesLineLimit: nil,
                        showsVisibility: false
                    )
                    LogSocialBar(
                        entry: model.entry,
                        isYours: model.entry.author.id == model.social.viewerID,
                        isKudosBusy: model.social.kudosInFlight.contains(model.entry.id),
                        visibility: model.entry.author.id == model.social.viewerID ? model.entry.visibility : nil,
                        onKudos: { Task { await model.toggleKudos() } },
                        onComments: { isComposing = true }
                    )
                }
            }

            Section("Comments") {
                if model.isUnavailable {
                    Text("This log was deleted or is no longer shared with you.")
                        .foregroundStyle(.secondary)
                } else if !model.hasLoaded {
                    ProgressView("Loading comments")
                } else if model.comments.isEmpty {
                    Text("No comments yet. Be the first.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.comments) { comment in
                        CommentRow(comment: comment)
                            .swipeActions {
                                if comment.canDelete {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        Task { await model.delete(comment) }
                                    }
                                }
                            }
                    }
                    if model.nextCursor != nil {
                        Button(model.isLoadingMore ? "Loading" : "Show more comments") { Task { await model.loadMore() } }
                            .frame(minHeight: 44)
                            .disabled(model.isLoadingMore)
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    StatusBanner(kind: .error, message: errorMessage)
                }
            }
        }
        .navigationTitle("Comments")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .safeAreaInset(edge: .bottom) {
            if !model.isUnavailable {
                composer
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if model.isDraftTooLong {
                Text("Comments can be up to \(LogDetailModel.maxCommentLength) characters.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Add a comment", text: $model.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($isComposing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.background.secondary, in: .rect(cornerRadius: 18))
                Button {
                    Task { await model.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(!model.canSend)
                .accessibilityLabel(model.isSending ? "Posting comment" : "Post comment")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct CommentRow: View {
    let comment: LogComment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(comment.author.displayName)
                    .font(.subheadline.weight(.semibold))
                Text("@\(comment.author.username)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(comment.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(comment.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
