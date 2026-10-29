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
    var deleting: LogTarget?
    /// A log stuck waiting to sync, offered removal from this device instead.
    var stuck: LogTarget?
    var message: String?
}

extension View {
    /// Edit and Delete on a swipe, for the person's own logs.
    func logSwipeActions(_ target: LogTarget, state: Binding<LogActionState>) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                if target.waitsForSync {
                    state.wrappedValue.stuck = target
                } else {
                    state.wrappedValue.deleting = target
                }
            }
            Button("Edit", systemImage: "pencil") {
                if target.waitsForSync {
                    state.wrappedValue.stuck = target
                } else {
                    state.wrappedValue.editing = target
                }
            }
            .tint(.gray)
        }
    }

    /// The editor, delete confirmation and error alert that the swipe actions open.
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
        .confirmationDialog(
            "Delete this log?",
            isPresented: Binding(get: { state.wrappedValue.deleting != nil }, set: { if !$0 { state.wrappedValue.deleting = nil } }),
            titleVisibility: .visible,
            presenting: state.wrappedValue.deleting
        ) { target in
            Button("Delete log", role: .destructive) {
                Task {
                    do {
                        try await change(.delete, target.localID, target.serverID)
                        onChanged(target, .delete)
                    } catch {
                        state.wrappedValue.message = error.localizedDescription
                    }
                }
            }
        } message: { _ in
            Text("Its time is removed from your feed, Insights and goals.")
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
            Text("Try again once it has synced. If it's stuck, remove it from this device instead. If an earlier send reached the server, it stays in your feed and can be edited or deleted there.")
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
