import SwiftUI

struct ActivityLogView: View {
    let logs: [LocalActivityLog]
    let api: TrackerAPIClient
    let token: String
    @State private var showingSocialFeed = false

    var body: some View {
        Group {
            if logs.isEmpty {
                ContentUnavailableView {
                    Label("No logged time yet", systemImage: "clock")
                } description: {
                    Text("Completed timers appear here, including logs waiting to sync.")
                } actions: {
                    Text("Start a timer from the Timer tab.")
                        .font(.subheadline)
                }
            } else {
                List(logs) { log in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(log.title)
                                .font(.headline)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            DurationText(log.durationSeconds)
                                .font(.subheadline.monospacedDigit())
                        }

                        Text(log.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Label(syncStatus(for: log), systemImage: syncSymbol(for: log))
                            .font(.caption)
                            .foregroundStyle(log.syncState == .synced ? Color.secondary : Color.orange)
                    }
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Friends") { showingSocialFeed = true }
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .sheet(isPresented: $showingSocialFeed) {
            NavigationStack {
                SocialFeedView(api: api, token: token)
            }
        }
    }

    private func syncStatus(for log: LocalActivityLog) -> String {
        switch log.syncState {
        case .running:
            return "Timer running"
        case .pending, .syncing:
            if let lastSyncError = log.lastSyncError {
                return "Saved on this device, sync failed: \(lastSyncError)"
            }
            return "Saved on this device, waiting to sync"
        case .synced:
            return "Synced"
        }
    }

    private func syncSymbol(for log: LocalActivityLog) -> String {
        log.syncState == .synced ? "checkmark.circle" : "clock.arrow.circlepath"
    }
}
