import SwiftUI

struct MainTabView: View {
    private enum Tab: Hashable {
        case timer
        case feed
        case insights
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
                TimerView(model: model)
            }
            .tabItem { Label("Timer", systemImage: "timer") }
            .tag(Tab.timer)

            NavigationStack {
                SocialFeedView(
                    api: session.api,
                    token: token,
                    viewerID: user.id,
                    localLogs: model.logs,
                    categories: model.categories.categories
                )
            }
            .tabItem { Label("Feed", systemImage: "person.2") }
            .tag(Tab.feed)

            NavigationStack {
                AnalyticsView(logs: model.summaryLogs, categories: model.categories.categories, goals: model.goals.goals)
            }
            .tabItem { Label("Insights", systemImage: "chart.bar") }
            .tag(Tab.insights)

            NavigationStack {
                ProfileAndCategoriesView(
                    user: session.user ?? user,
                    logs: model.summaryLogs,
                    localLogs: model.logs,
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
