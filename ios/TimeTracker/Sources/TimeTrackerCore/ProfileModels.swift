import Foundation

public struct APIUser: Codable, Equatable, Sendable {
    public let id: UUID
    public let username: String
    public var displayName: String
    public let email: String
    public let avatarUrl: URL?
    public let createdAt: Date?

    public init(id: UUID, username: String, displayName: String, email: String, avatarUrl: URL?, createdAt: Date? = nil) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.email = email
        self.avatarUrl = avatarUrl
        self.createdAt = createdAt
    }
}

public struct APICategory: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let colorHex: String
    public let createdAt: Date?

    public init(id: UUID, name: String, colorHex: String, createdAt: Date? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
    }
}

public enum ProfileClientError: Error, Equatable {
    case duplicateCategory
    case duplicateEmail
    case incorrectPassword
}

struct CategoriesEnvelope: Decodable {
    let categories: [APICategory]
}

struct CategoryEnvelope: Decodable {
    let category: APICategory
}

struct UpdateProfilePayload: Encodable {
    let displayName: String
}

struct UpdateEmailPayload: Encodable {
    let email: String
    let currentPassword: String
}

struct CreateCategoryPayload: Encodable {
    let name: String
    let colorHex: String?
}

struct UpdateCategoryPayload: Encodable {
    let name: String
}
