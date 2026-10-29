import Foundation

/// The signed-in user's categories, shared by the Timer and Profile tabs so both stay in sync.
@MainActor
@Observable
final class CategoryStore {
    private let api: TrackerAPIClient
    private let token: String
    private(set) var categories: [APICategory] = []
    private(set) var isLoading = false
    /// Whether `categories` reflects the server yet, so an empty list isn't mistaken for "all deleted".
    private(set) var hasLoaded = false
    private(set) var isCreating = false

    init(api: TrackerAPIClient, token: String) {
        self.api = api
        self.token = token
    }

    func category(withID id: UUID?) -> APICategory? {
        categories.first { $0.id == id }
    }

    func reload() async throws {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        categories = try await api.categories(accessToken: token)
        hasLoaded = true
    }

    func create(named name: String) async throws -> APICategory {
        isCreating = true
        defer { isCreating = false }
        let category = try await api.createCategory(name: name, accessToken: token)
        categories.append(category)
        return category
    }

    func rename(_ category: APICategory, to name: String) async throws {
        let renamed = try await api.renameCategory(id: category.id, to: name, accessToken: token)
        if let index = categories.firstIndex(where: { $0.id == category.id }) {
            categories[index] = renamed
        }
    }

    func delete(_ category: APICategory) async throws {
        do {
            try await api.deleteCategory(id: category.id, accessToken: token)
        } catch APIClientError.server(404, _) {
            // Already deleted, for example from another device.
        }
        categories.removeAll { $0.id == category.id }
    }
}
