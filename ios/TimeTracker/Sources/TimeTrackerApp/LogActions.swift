import SwiftUI

/// A log a swipe acts on: one on this device, a feed entry from the server, or both at once.
struct LogTarget: Identifiable, Equatable {
    let id: UUID
    let localID: UUID?
    let serverID: UUID?
    let edit: LogEdit
    /// A send with an unknown outcome is in flight or was interrupted, so changes wait for sync.
    let waitsForSync: Bool

    private init(id: UUID, localID: UUID?, serverID: UUID?, edit: LogEdit, waitsForSync: Bool) {
        self.id = id
        self.localID = localID
        self.serverID = serverID
        self.edit = edit
        self.waitsForSync = waitsForSync
    }

    init(log: LocalActivityLog) {
        self.init(id: log.id, localID: log.id, serverID: log.serverID, edit: log.logEdit, waitsForSync: log.changeRoute == .waitForSync)
    }

    /// Prefers the copy on this device when there is one, so its sync state decides the route. The
    /// idempotency key also finds a copy whose send reached the server but whose reply was lost, which
    /// has no `serverID` yet and must wait for its retry.
    init(entry: FeedEntry, localLogs: [LocalActivityLog]) {
        if let local = localLogs.first(where: { $0.serverID == entry.id || $0.idempotencyKey == entry.idempotencyKey }) {
            self.init(log: local)
        } else {
            self.init(id: entry.id, localID: nil, serverID: entry.id, edit: entry.logEdit, waitsForSync: false)
        }
    }
}

/// Applies an edit or deletion; `TimerHomeModel.changeLog` in the app.
typealias LogChanger = @MainActor (LogChange, _ localID: UUID?, _ serverID: UUID?) async throws -> Void

/// The state behind a list's log swipe actions. One per list, shared by its rows.
struct LogActionState {
    var editing: LogTarget?
    /// Confirmed in the row's dialog, and carried out by `logActionPresentations`.
    var confirmedDeletion: LogTarget?
    /// Logs slid out of their row while their deletion finishes, until they leave the list.
    var deletingIDs: Set<UUID> = []
    /// A log stuck waiting to sync, offered removal from this device instead.
    var stuck: LogTarget?
    var message: String?
}

/// Edit and Delete on a swipe, with the delete confirmation attached to the row so its popover
/// points at the log being deleted rather than at the top of the list.
private struct LogSwipeActions: ViewModifier {
    let target: LogTarget
    @Binding var state: LogActionState
    /// Kept on the row so opening the dialog doesn't redraw the whole list under it.
    @State private var isConfirmingDeletion = false

    func body(content: Content) -> some View {
        let isDeleting = state.deletingIDs.contains(target.id)
        content
            // Slides on out to the left, the way it was swiped, leaving its space until it's gone.
            .visualEffect { view, proxy in
                view.offset(x: isDeleting ? -proxy.size.width : 0)
            }
            .opacity(isDeleting ? 0 : 1)
            .overlay {
                if isDeleting {
                    ProgressView("Deleting")
                        .controlSize(.small)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(!isDeleting)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // A row on its way out can't be changed again; hit testing alone doesn't stop a swipe.
                if !isDeleting {
                    swipeButtons
                }
            }
            .confirmationDialog("Delete this log?", isPresented: $isConfirmingDeletion, titleVisibility: .visible) {
                Button("Delete log", role: .destructive) {
                    state.confirmedDeletion = target
                }
            } message: {
                Text("Its time is removed from your feed, Insights and goals.")
            }
    }

    @ViewBuilder
    private var swipeButtons: some View {
        // Not `role: .destructive`: List animates a destructive action's row away as if it were
        // deleted, which takes the row's dialog with it before it can be answered.
        Button("Delete", systemImage: "trash") {
            if target.waitsForSync {
                state.stuck = target
            } else {
                isConfirmingDeletion = true
            }
        }
        .tint(.red)
        Button("Edit", systemImage: "pencil") {
            if target.waitsForSync {
                state.stuck = target
            } else {
                state.editing = target
            }
        }
        .tint(.gray)
    }
}

extension View {
    /// Edit and Delete on a swipe, for the person's own logs.
    func logSwipeActions(_ target: LogTarget, state: Binding<LogActionState>) -> some View {
        modifier(LogSwipeActions(target: target, state: state))
    }

    /// The editor and alerts that the swipe actions open, and the deletion a row confirms.
    /// - Parameter onChanged: Runs after a change succeeds, such as updating a feed's copy of the entry.
    func logActionPresentations(
        state: Binding<LogActionState>,
        categories: [APICategory],
        change: @escaping LogChanger,
        onChanged: @escaping (LogTarget, LogChange) -> Void = { _, _ in }
    ) -> some View {
        sheet(item: state.editing) { target in
            LogEditorSheet(log: target.edit, categories: categories) { edit in
                try await change(.edit(edit), target.localID, target.serverID)
                onChanged(target, .edit(edit))
            }
        }
        .onChange(of: state.wrappedValue.confirmedDeletion) { _, target in
            guard let target else { return }
            state.wrappedValue.confirmedDeletion = nil
            guard !state.wrappedValue.deletingIDs.contains(target.id) else { return }
            Task {
                // The slide plays before the change, because a log on this device leaves the list
                // the moment it's deleted and would vanish without being seen to go.
                withAnimation(.easeIn(duration: 0.3)) {
                    _ = state.wrappedValue.deletingIDs.insert(target.id)
                }
                try? await Task.sleep(for: .milliseconds(300))
                do {
                    try await change(.delete, target.localID, target.serverID)
                    withAnimation(.snappy) {
                        onChanged(target, .delete)
                        _ = state.wrappedValue.deletingIDs.remove(target.id)
                    }
                } catch {
                    withAnimation(.snappy) {
                        _ = state.wrappedValue.deletingIDs.remove(target.id)
                    }
                    state.wrappedValue.message = error.localizedDescription
                }
            }
        }
        .alert(
            "This log is still being sent",
            isPresented: Binding(get: { state.wrappedValue.stuck != nil }, set: { if !$0 { state.wrappedValue.stuck = nil } }),
            presenting: state.wrappedValue.stuck
        ) { target in
            Button("Remove from this device", role: .destructive) {
                Task {
                    do {
                        try await change(.removeFromDevice, target.localID, target.serverID)
                        onChanged(target, .removeFromDevice)
                    } catch {
                        state.wrappedValue.message = error.localizedDescription
                    }
                }
            }
            Button("Wait", role: .cancel) {}
        } message: { _ in
            Text("Try again once it has synced. If it's stuck, you can remove it from this device. If it already reached the server, it stays in your feed and can be changed there. If it never did, its time is lost.")
        }
        .alert(
            "Couldn't change this log",
            isPresented: Binding(get: { state.wrappedValue.message != nil }, set: { if !$0 { state.wrappedValue.message = nil } }),
            presenting: state.wrappedValue.message
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}
