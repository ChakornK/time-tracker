import SwiftUI

struct MainTabView: View {
    private enum Tab: Hashable {
        case log
        case timer
        case analytics
        case profile
    }

    let session: AuthSession
    let token: String
    let user: APIUser
    @State private var model: TimerHomeModel
    @State private var selectedTab = Tab.timer
    @Environment(\.scenePhase) private var scenePhase

    init(
        session: AuthSession,
        token: String,
        user: APIUser,
        timerStore: any TimerStoreProtocol,
        liveActivity: LiveActivityController
    ) {
        self.session = session
        self.token = token
        self.user = user
        _model = State(initialValue: TimerHomeModel(
            api: session.api,
            token: token,
            userID: user.id,
            timerStore: timerStore,
            categories: CategoryStore(api: session.api, token: token),
            goals: GoalStore(api: session.api, token: token),
            liveActivity: liveActivity,
            onAuthenticationExpired: session.expireSession
        ))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ActivityLogView(logs: model.logs, api: session.api, token: token)
            }
            .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
            .tag(Tab.log)

            NavigationStack {
                TimerView(model: model)
            }
            .tabItem { Label("Timer", systemImage: "timer") }
            .tag(Tab.timer)

            NavigationStack {
                AnalyticsView(logs: model.summaryLogs, categories: model.categories.categories, goals: model.goals.goals)
            }
            .tabItem { Label("Analytics", systemImage: "chart.bar") }
            .tag(Tab.analytics)

            NavigationStack {
                ProfileAndCategoriesView(
                    user: session.user ?? user,
                    logs: model.summaryLogs,
                    categories: model.categories,
                    goals: model.goals,
                    isCategoryAwaitingSync: { [model] in model.categoryIDsAwaitingSync.contains($0) },
                    onCategoryDeleted: model.categoryWasDeleted
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            SettingsView(
                                api: session.api,
                                token: token,
                                user: session.user ?? user,
                                onProfileChanged: session.updateUser,
                                onSignOut: session.signOut
                            )
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(Tab.profile)
        }
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.refreshRemoteData() }
            }
        }
    }
}
