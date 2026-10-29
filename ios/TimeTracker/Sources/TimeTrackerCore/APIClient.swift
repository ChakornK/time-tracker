import Foundation

public struct AuthTokenResponse: Decodable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let expiresInSeconds: Int
}

public struct APIErrorResponse: Decodable, Sendable {
    public struct Issue: Decodable, Sendable {
        private enum CodingKeys: String, CodingKey {
            case path
            case message
        }

        /// The top-level request field the issue refers to, such as `email`.
        public let field: String?
        public let message: String?

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
            // Paths can mix names and array indexes; only a leading field name is useful here.
            field = (try? container.decodeIfPresent([String].self, forKey: .path))?.first
        }

        /// The server's message, or a sentence naming the field when the server sent none.
        var userMessage: String {
            if let message { return message }
            guard let field else { return "A field was rejected by the server." }
            let name = field == "displayName" ? "display name" : field
            return "Check the \(name) field."
        }
    }

    public struct Detail: Decodable, Sendable {
        public let code: String
        public let message: String?
        public let issues: [Issue]?
    }
    public let error: Detail
}

public struct LogReceiptResponse: Decodable, Sendable {
    public let id: UUID
    public let idempotencyKey: UUID
    public let created: Bool
}

public enum APIClientError: Error, Equatable {
    case invalidRequest
    case invalidResponse
    case server(statusCode: Int, code: String)
    /// The server rejected specific fields; each message is ready to show to the user.
    case invalidFields([String])
    case decoding

    public var isUnauthorized: Bool {
        if case .server(401, _) = self { return true }
        return false
    }
}

extension APIClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The request could not be built."
        case .invalidResponse, .decoding: "The server returned an unreadable response."
        case .invalidFields(let messages): messages.joined(separator: "\n")
        case .server(401, _): "Your session expired."
        case .server(let statusCode, let code): "The server rejected the request (\(statusCode), \(code))."
        }
    }
}

public struct TrackerAPIClient: Sendable {
    private enum Method: String {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    public let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithOptionalFractionalSeconds
    }

    // MARK: Auth

    public func register(username: String, displayName: String, email: String, password: String) async throws -> APIUser {
        let request = try makeRequest(
            .post,
            "auth/register",
            body: RegisterPayload(username: username, displayName: displayName, email: email, password: password)
        )
        let envelope: UserEnvelope = try await send(request)
        return envelope.user
    }

    public func login(username: String, password: String) async throws -> AuthTokenResponse {
        try await send(encodedLoginRequest(username: username, password: password))
    }

    // MARK: Profile

    public func profile(accessToken: String) async throws -> APIUser {
        let envelope: UserEnvelope = try await send(makeRequest(.get, "me", token: accessToken))
        return envelope.user
    }

    public func updateProfile(displayName: String, accessToken: String) async throws -> APIUser {
        let request = try makeRequest(.patch, "me", body: UpdateProfilePayload(displayName: displayName), token: accessToken)
        let envelope: UserEnvelope = try await send(request)
        return envelope.user
    }

    public func updateEmail(_ email: String, currentPassword: String, accessToken: String) async throws -> APIUser {
        let request = try makeRequest(
            .patch,
            "me/email",
            body: UpdateEmailPayload(email: email, currentPassword: currentPassword),
            token: accessToken
        )
        do {
            let envelope: UserEnvelope = try await send(request)
            return envelope.user
        } catch APIClientError.server(_, "EMAIL_CONFLICT") {
            throw ProfileClientError.duplicateEmail
        } catch APIClientError.server(_, "INCORRECT_PASSWORD") {
            throw ProfileClientError.incorrectPassword
        }
    }

    public func categories(accessToken: String) async throws -> [APICategory] {
        let envelope: CategoriesEnvelope = try await send(makeRequest(.get, "categories", token: accessToken))
        return envelope.categories
    }

    public func createCategory(name: String, colorHex: String? = nil, accessToken: String) async throws -> APICategory {
        let request = try makeRequest(
            .post,
            "categories",
            body: CreateCategoryPayload(name: name, colorHex: colorHex),
            token: accessToken
        )
        do {
            let envelope: CategoryEnvelope = try await send(request)
            return envelope.category
        } catch APIClientError.server(_, "CATEGORY_CONFLICT") {
            throw ProfileClientError.duplicateCategory
        }
    }

    public func renameCategory(id: UUID, to name: String, accessToken: String) async throws -> APICategory {
        let request = try makeRequest(
            .patch,
            "categories/\(id.uuidString)",
            body: UpdateCategoryPayload(name: name),
            token: accessToken
        )
        do {
            let envelope: CategoryEnvelope = try await send(request)
            return envelope.category
        } catch APIClientError.server(_, "CATEGORY_CONFLICT") {
            throw ProfileClientError.duplicateCategory
        }
    }

    public func deleteCategory(id: UUID, accessToken: String) async throws {
        _ = try await perform(makeRequest(.delete, "categories/\(id.uuidString)", token: accessToken))
    }

    // MARK: Goals

    public func goals(accessToken: String) async throws -> [APIGoal] {
        let envelope: GoalsEnvelope = try await send(makeRequest(.get, "goals", token: accessToken))
        return envelope.goals
    }

    public func createGoal(categoryID: UUID, period: GoalPeriod, targetSeconds: Int, accessToken: String) async throws -> APIGoal {
        let request = try makeRequest(
            .post,
            "goals",
            body: CreateGoalPayload(categoryId: categoryID, period: period, targetSeconds: targetSeconds),
            token: accessToken
        )
        do {
            let envelope: GoalEnvelope = try await send(request)
            return envelope.goal
        } catch APIClientError.server(_, "GOAL_CONFLICT") {
            throw GoalClientError.duplicateGoal
        }
    }

    public func updateGoal(id: UUID, targetSeconds: Int, accessToken: String) async throws -> APIGoal {
        let request = try makeRequest(
            .patch,
            "goals/\(id.uuidString)",
            body: UpdateGoalPayload(targetSeconds: targetSeconds),
            token: accessToken
        )
        let envelope: GoalEnvelope = try await send(request)
        return envelope.goal
    }

    public func deleteGoal(id: UUID, accessToken: String) async throws {
        _ = try await perform(makeRequest(.delete, "goals/\(id.uuidString)", token: accessToken))
    }

    // MARK: Social

    public func searchUsers(username: String, accessToken: String) async throws -> [SocialUser] {
        let query = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...50).contains(query.count) else { throw SocialClientError.invalidUsername }
        let request = try makeRequest(.get, "users/search", query: ["username": query], token: accessToken)
        let envelope: UserSearchEnvelope = try await send(request)
        return envelope.users
    }

    public func following(accessToken: String) async throws -> [FollowingUser] {
        let envelope: FollowingEnvelope = try await send(makeRequest(.get, "follows", token: accessToken))
        return envelope.following
    }

    public func follow(userID: UUID, accessToken: String) async throws {
        let request = try makeRequest(.post, "follows", body: FollowPayload(userId: userID), token: accessToken)
        do {
            _ = try await perform(request)
        } catch APIClientError.server(_, "SELF_FOLLOW_NOT_ALLOWED") {
            throw SocialClientError.followConflict
        }
    }

    public func unfollow(userID: UUID, accessToken: String) async throws {
        _ = try await perform(makeRequest(.delete, "follows/\(userID.uuidString)", token: accessToken))
    }

    public func feedPage(accessToken: String, cursor: String? = nil, limit: Int = 20) async throws -> FeedPage {
        guard (1...100).contains(limit) else { throw APIClientError.invalidRequest }
        var query = ["limit": String(limit)]
        if let cursor, !cursor.isEmpty {
            query["cursor"] = cursor
        }
        return try await send(makeRequest(.get, "feed", query: query, token: accessToken))
    }

    // MARK: Logs

    public func createLog(_ log: LocalActivityLog, accessToken: String) async throws -> LogReceiptResponse {
        try await send(encodedLogRequest(log, accessToken: accessToken))
    }

    // MARK: Request building

    public func encodedLoginRequest(username: String, password: String) throws -> URLRequest {
        try makeRequest(.post, "auth/login", body: LoginPayload(username: username, password: password))
    }

    public func encodedLogRequest(_ log: LocalActivityLog, accessToken: String) throws -> URLRequest {
        try makeRequest(.post, "logs", body: CreateLogPayload(log: log), token: accessToken)
    }

    private func makeRequest(
        _ method: Method,
        _ path: String,
        query: [String: String] = [:],
        body: (some Encodable)? = nil as Never?,
        token: String? = nil
    ) throws -> URLRequest {
        let url = baseURL.appending(path: "api/v1/\(path)")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIClientError.invalidRequest
        }
        if !query.isEmpty {
            // URLComponents leaves "+" unescaped, which servers decode as a space.
            components.percentEncodedQueryItems = query.sorted { $0.key < $1.key }.map { name, value in
                let encoded = value
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
                    .replacingOccurrences(of: "+", with: "%2B")
                return URLQueryItem(name: name, value: encoded)
            }
        }
        guard let resolvedURL = components.url else { throw APIClientError.invalidRequest }

        var request = URLRequest(url: resolvedURL)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        return request
    }

    // MARK: Transport

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data = try await perform(request)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIClientError.decoding
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = try? decoder.decode(APIErrorResponse.self, from: data)
            let fieldMessages = body?.error.issues?.map(\.userMessage) ?? []
            if !fieldMessages.isEmpty {
                throw APIClientError.invalidFields(fieldMessages)
            }
            throw APIClientError.server(statusCode: httpResponse.statusCode, code: body?.error.code ?? "UNKNOWN_ERROR")
        }
        return data
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    /// The backend serializes dates with `Date.toISOString()`, which includes milliseconds.
    static var iso8601WithOptionalFractionalSeconds: Self {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(string, strategy: Date.ISO8601FormatStyle()) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date: \(string)")
        }
    }
}

private struct RegisterPayload: Encodable {
    let username: String
    let displayName: String
    let email: String
    let password: String
}

private struct LoginPayload: Encodable {
    let username: String
    let password: String
}

private struct CreateLogPayload: Encodable {
    let idempotencyKey: UUID
    let title: String
    let notes: String?
    let startedAt: Date
    let endedAt: Date
    let categoryIds: [UUID]
    let visibility: ActivityVisibility

    init(log: LocalActivityLog) {
        idempotencyKey = log.idempotencyKey
        title = log.title
        // Also covers logs saved before notes were capped on entry, which would otherwise fail every retry.
        notes = LogNotes.cleaned(log.notes)
        startedAt = log.startedAt
        endedAt = log.endedAt
        categoryIds = log.categoryIDs
        visibility = log.visibility
    }
}

private struct UserEnvelope: Decodable {
    let user: APIUser
}
