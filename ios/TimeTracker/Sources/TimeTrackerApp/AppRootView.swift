import SwiftUI

struct AppRootView: View {
    let session: AuthSession
    let timerStore: SwiftDataTimerStore
    let liveActivity: LiveActivityController

    var body: some View {
        Group {
            content
        }
        // Neutral, so color in the app only ever means a category.
        .tint(.primary)
    }

    @ViewBuilder
    private var content: some View {
        if let token = session.accessToken, let user = session.user {
            MainTabView(
                session: session,
                token: token,
                user: user,
                timerStore: timerStore,
                liveActivity: liveActivity
            )
            // A new session gets fresh models instead of inheriting the previous account's state.
            .id(token)
        } else if session.accessToken != nil {
            SessionRestoreView(session: session)
        } else {
            AuthenticationView(session: session)
        }
    }
}

private struct SessionRestoreView: View {
    let session: AuthSession

    var body: some View {
        Group {
            if let errorMessage = session.errorMessage {
                ContentUnavailableView {
                    Label("Could not restore your session", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try again") {
                        Task { await session.restoreSession() }
                    }
                    .primaryActionStyle()
                    Button("Sign out", role: .destructive, action: session.signOut)
                }
            } else {
                ProgressView("Restoring your session")
            }
        }
        .task { await session.restoreSession() }
    }
}
