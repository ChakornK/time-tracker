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
    /// Bumped by every local change, so a reload that started before one doesn't overwrite it.
    private var revision = 0

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
        let startRevision = revision
        let loaded = try await api.goals(accessToken: token)
        if revision == startRevision {
            goals = loaded
        }
    }

    func create(categoryID: UUID, period: GoalPeriod, targetSeconds: Int) async throws {
        isSaving = true
        defer { isSaving = false }
        let goal = try await api.createGoal(categoryID: categoryID, period: period, targetSeconds: targetSeconds, accessToken: token)
        // A reload that finished mid-request may already hold the new goal.
        goals.removeAll { $0.id == goal.id }
        goals.append(goal)
        revision += 1
    }

    func update(_ goal: APIGoal, targetSeconds: Int) async throws {
        isSaving = true
        defer { isSaving = false }
        let updated = try await api.updateGoal(id: goal.id, targetSeconds: targetSeconds, accessToken: token)
        if let index = goals.firstIndex(where: { $0.id == goal.id }) {
            goals[index] = updated
        }
        revision += 1
    }

    /// Drops goals the server deleted along with their category.
    func removeGoals(forCategoryID categoryID: UUID) {
        goals.removeAll { $0.categoryId == categoryID }
        revision += 1
    }

    func delete(_ goal: APIGoal) async throws {
        do {
            try await api.deleteGoal(id: goal.id, accessToken: token)
        } catch APIClientError.server(404, _) {
            // Already deleted, for example from another device.
        }
        goals.removeAll { $0.id == goal.id }
        revision += 1
    }
}
