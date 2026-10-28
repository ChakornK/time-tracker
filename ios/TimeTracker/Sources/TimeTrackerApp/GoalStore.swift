import Foundation

/// The signed-in user's goals, shared by the Profile and Analytics tabs so both stay in sync.
@MainActor
@Observable
final class GoalStore {
    private let api: TrackerAPIClient
    private let token: String
    private(set) var goals: [APIGoal] = []
    private(set) var isLoading = false
    private(set) var isSaving = false

    init(api: TrackerAPIClient, token: String) {
        self.api = api
        self.token = token
    }

    func goal(for categoryID: UUID, period: GoalPeriod) -> APIGoal? {
        goals.first { $0.categoryId == categoryID && $0.period == period }
    }

    func reload() async throws {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        goals = try await api.goals(accessToken: token)
    }

    func create(categoryID: UUID, period: GoalPeriod, targetSeconds: Int) async throws {
        isSaving = true
        defer { isSaving = false }
        let goal = try await api.createGoal(categoryID: categoryID, period: period, targetSeconds: targetSeconds, accessToken: token)
        goals.append(goal)
    }

    func update(_ goal: APIGoal, targetSeconds: Int) async throws {
        isSaving = true
        defer { isSaving = false }
        let updated = try await api.updateGoal(id: goal.id, targetSeconds: targetSeconds, accessToken: token)
        if let index = goals.firstIndex(where: { $0.id == goal.id }) {
            goals[index] = updated
        }
    }

    func delete(_ goal: APIGoal) async throws {
        do {
            try await api.deleteGoal(id: goal.id, accessToken: token)
        } catch APIClientError.server(404, _) {
            // Already deleted, for example from another device.
        }
        goals.removeAll { $0.id == goal.id }
    }
}
