import Foundation
import Testing
@testable import TimeTrackerCore

@Suite(.serialized)
struct APIClientTests {
    @Test func encodesLoginRequestPayload() throws {
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!)
        let request = try client.encodedLoginRequest(username: "demo-user", password: "correct horse battery staple")
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(request.url?.path == "/api/v1/auth/login")
        #expect(request.httpMethod == "POST")
        #expect(payload["username"] == "demo-user")
        #expect(payload["password"] == "correct horse battery staple")
    }

    @Test func loginDecodesBearerTokenAndUsesEndpoint() async throws {
        let responseBody = Data(#"{"accessToken":"signed-token","tokenType":"Bearer","expiresInSeconds":900}"#.utf8)
        let session = stubbedSession { request in
            #expect(request.url?.absoluteString == "https://tracker.example.test/api/v1/auth/login")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            return response(body: responseBody, statusCode: 200)
        }

        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)
        let tokens = try await client.login(username: "demo-user", password: "correct horse battery staple")
        #expect(tokens.accessToken == "signed-token")
        #expect(tokens.tokenType == "Bearer")
        #expect(tokens.expiresInSeconds == 900)
    }

    @Test func profileAttachesBearerTokenAndDecodesUser() async throws {
        let responseBody = Data(#"{"user":{"id":"A93FCBEA-EEA7-4651-99D7-AF544F278DD1","username":"demo-user","displayName":"Demo User","email":"demo@example.test","avatarUrl":null}}"#.utf8)
        let session = stubbedSession { request in
            #expect(request.url?.path == "/api/v1/me")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            return response(body: responseBody, statusCode: 200)
        }

        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)
        let user = try await client.profile(accessToken: "access-token")
        #expect(user.username == "demo-user")
        #expect(user.displayName == "Demo User")
        #expect(user.avatarUrl == nil)
    }

    @Test func categoriesDecodesAuthenticatedResponse() async throws {
        let categoryID = UUID()
        let responseBody = Data("""
        {"categories":[{"id":"\(categoryID)","name":"Writing","colorHex":"#345678","createdAt":"2026-02-08T12:00:00Z"}]}
        """.utf8)
        let session = stubbedSession { request in
            #expect(request.url?.path == "/api/v1/categories")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            return response(body: responseBody, statusCode: 200)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        let categories = try await client.categories(accessToken: "access-token")

        #expect(categories == [APICategory(id: categoryID, name: "Writing", colorHex: "#345678", createdAt: ISO8601DateFormatter().date(from: "2026-02-08T12:00:00Z"))])
    }

    @Test func updateProfileSendsDisplayNameAndDecodesUser() async throws {
        let profileID = UUID()
        let body = Data("""
        {"user":{"id":"\(profileID)","username":"demo-user","displayName":"New Name","email":"demo@example.test","avatarUrl":null,"createdAt":"2026-02-08T12:00:00Z"}}
        """.utf8)
        let session = stubbedSession { request in
            let requestBody = try #require(requestBodyData(request))
            let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: String])
            #expect(payload["displayName"] == "New Name")
            #expect(request.url?.path == "/api/v1/me")
            #expect(request.httpMethod == "PATCH")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            return response(body: body, statusCode: 200)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        let profile = try await client.updateProfile(displayName: "New Name", accessToken: "access-token")

        #expect(profile.id == profileID)
        #expect(profile.displayName == "New Name")
    }

    @Test func createCategoryMapsDuplicateConflict() async throws {
        let body = Data(#"{"error":{"code":"CATEGORY_CONFLICT","message":"Category name already exists"}}"#.utf8)
        let session = stubbedSession { request in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            return response(body: body, statusCode: 409)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        await #expect(throws: ProfileClientError.duplicateCategory) {
            try await client.createCategory(name: "Writing", accessToken: "access-token")
        }
    }

    @Test func renameCategorySendsNameAndMapsConflict() async throws {
        let categoryID = UUID()
        let body = Data("""
        {"category":{"id":"\(categoryID)","name":"Books","colorHex":"#4A6C45","createdAt":"2026-02-08T12:00:00Z"}}
        """.utf8)
        let session = stubbedSession { request in
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/api/v1/categories/\(categoryID.uuidString)")
            let requestBody = try #require(requestBodyData(request))
            let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: String])
            #expect(payload == ["name": "Books"])
            return response(body: body, statusCode: 200)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)
        let category = try await client.renameCategory(id: categoryID, to: "Books", accessToken: "access-token")
        #expect(category.name == "Books")

        let conflict = Data(#"{"error":{"code":"CATEGORY_CONFLICT","message":"exists"}}"#.utf8)
        let conflictClient = TrackerAPIClient(
            baseURL: URL(string: "https://tracker.example.test")!,
            session: stubbedSession { _ in response(body: conflict, statusCode: 409) }
        )
        await #expect(throws: ProfileClientError.duplicateCategory) {
            try await conflictClient.renameCategory(id: categoryID, to: "Writing", accessToken: "access-token")
        }
    }

    @Test func deleteCategoryUsesCategoryPath() async throws {
        let categoryID = UUID()
        let session = stubbedSession { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/api/v1/categories/\(categoryID.uuidString)")
            return response(body: Data(), statusCode: 204)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        try await client.deleteCategory(id: categoryID, accessToken: "access-token")
    }

    @Test func createGoalSendsPayloadAndDecodesGoal() async throws {
        let goalID = UUID()
        let categoryID = UUID()
        let body = Data("""
        {"goal":{"id":"\(goalID)","categoryId":"\(categoryID)","period":"week","targetSeconds":18000,"createdAt":"2026-02-08T12:00:00.000Z"}}
        """.utf8)
        let session = stubbedSession { request in
            #expect(request.url?.path == "/api/v1/goals")
            #expect(request.httpMethod == "POST")
            let requestBody = try #require(requestBodyData(request))
            let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            #expect(payload["categoryId"] as? String == categoryID.uuidString)
            #expect(payload["period"] as? String == "week")
            #expect(payload["targetSeconds"] as? Int == 18_000)
            return response(body: body, statusCode: 201)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        let goal = try await client.createGoal(categoryID: categoryID, period: .week, targetSeconds: 18_000, accessToken: "access-token")

        #expect(goal.id == goalID)
        #expect(goal.period == .week)
    }

    @Test func createGoalMapsDuplicateConflict() async throws {
        let body = Data(#"{"error":{"code":"GOAL_CONFLICT","message":"exists"}}"#.utf8)
        let session = stubbedSession { _ in response(body: body, statusCode: 409) }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        await #expect(throws: GoalClientError.duplicateGoal) {
            try await client.createGoal(categoryID: UUID(), period: .day, targetSeconds: 600, accessToken: "access-token")
        }
    }

    @Test func deleteGoalUsesGoalPath() async throws {
        let goalID = UUID()
        let session = stubbedSession { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/api/v1/goals/\(goalID.uuidString)")
            return response(body: Data(), statusCode: 204)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        try await client.deleteGoal(id: goalID, accessToken: "access-token")
    }

    @Test func updateLogSendsEveryFieldAndClearsNotesWithNull() async throws {
        let logID = UUID()
        let categoryID = UUID()
        let session = stubbedSession { request in
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/api/v1/logs/\(logID.uuidString)")
            let body = try? JSONSerialization.jsonObject(with: requestBodyData(request) ?? Data()) as? [String: Any]
            #expect(body?["title"] as? String == "Reading")
            #expect(body?["notes"] is NSNull)
            #expect(body?["categoryIds"] as? [String] == [categoryID.uuidString])
            #expect(body?["visibility"] as? String == "private")
            #expect(body?["startedAt"] != nil && body?["endedAt"] != nil)
            return response(body: Data(), statusCode: 204)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)
        let edit = LogEdit(
            title: "Reading",
            notes: "   ",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_003_600),
            categoryIDs: [categoryID],
            visibility: .private
        )

        try await client.updateLog(id: logID, edit: edit, accessToken: "access-token")
    }

    @Test func deleteLogUsesLogPath() async throws {
        let logID = UUID()
        let session = stubbedSession { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/api/v1/logs/\(logID.uuidString)")
            return response(body: Data(), statusCode: 204)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        try await client.deleteLog(id: logID, accessToken: "access-token")
    }

    @Test func updateEmailMapsPasswordAndConflictErrors() async throws {
        let wrongPassword = Data(#"{"error":{"code":"INCORRECT_PASSWORD","message":"no"}}"#.utf8)
        let conflict = Data(#"{"error":{"code":"EMAIL_CONFLICT","message":"taken"}}"#.utf8)
        let client = TrackerAPIClient(
            baseURL: URL(string: "https://tracker.example.test")!,
            session: stubbedSession { request in
                #expect(request.url?.path == "/api/v1/me/email")
                #expect(request.httpMethod == "PATCH")
                return response(body: wrongPassword, statusCode: 403)
            }
        )
        await #expect(throws: ProfileClientError.incorrectPassword) {
            try await client.updateEmail("new@example.test", currentPassword: "nope", accessToken: "access-token")
        }

        let conflictClient = TrackerAPIClient(
            baseURL: URL(string: "https://tracker.example.test")!,
            session: stubbedSession { _ in response(body: conflict, statusCode: 409) }
        )
        await #expect(throws: ProfileClientError.duplicateEmail) {
            try await conflictClient.updateEmail("new@example.test", currentPassword: "pw", accessToken: "access-token")
        }
    }

    @Test func createCategoryReturnsCreatedCategory() async throws {
        let categoryID = UUID()
        let body = Data("""
        {"category":{"id":"\(categoryID)","name":"Writing","colorHex":"#4A6C45","createdAt":"2026-02-08T12:00:00Z"}}
        """.utf8)
        let session = stubbedSession { request in
            #expect(request.httpMethod == "POST")
            let requestBody = try #require(requestBodyData(request))
            let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: String])
            #expect(payload["name"] == "Writing")
            return response(body: body, statusCode: 201)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        let category = try await client.createCategory(name: "Writing", accessToken: "access-token")

        #expect(category.id == categoryID)
        #expect(category.colorHex == "#4A6C45")
    }

    @Test func feedPageRequestsCursorAndDecodesEntries() async throws {
        let entryID = UUID()
        let authorID = UUID()
        let body = Data("""
        {"items":[{"id":"\(entryID)","title":"Writing","notes":null,"startedAt":"2026-02-08T10:00:00Z","endedAt":"2026-02-08T11:30:00Z","durationSeconds":5400,"visibility":"friends_only","createdAt":"2026-02-08T11:30:00Z","author":{"id":"\(authorID)","username":"writer","displayName":"Writer","avatarUrl":null},"categories":[]}],"nextCursor":"opaque-cursor+with/slash="}
        """.utf8)
        let session = stubbedSession { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.path == "/api/v1/feed")
            #expect(components.queryItems?.first(where: { $0.name == "limit" })?.value == "20")
            #expect(components.queryItems?.first(where: { $0.name == "cursor" })?.value == "opaque-cursor+with/slash=")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            return response(body: body, statusCode: 200)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        let page = try await client.feedPage(accessToken: "access-token", cursor: "opaque-cursor+with/slash=")

        #expect(page.items.count == 1)
        #expect(page.items[0].id == entryID)
        #expect(page.items[0].author.id == authorID)
        #expect(page.items[0].visibility == .friendsOnly)
        #expect(page.nextCursor == "opaque-cursor+with/slash=")
    }

    @Test func feedRejectsOutOfRangePageLimit() async throws {
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!)
        await #expect(throws: APIClientError.invalidRequest) {
            try await client.feedPage(accessToken: "access-token", limit: 101)
        }
    }

    @Test func searchesUsersWithAuthorizationAndEncodedUsername() async throws {
        let userID = UUID()
        let body = Data("""
        {"users":[{"id":"\(userID)","username":"a+b_writer","displayName":"Writer","isPrivate":true,"isFollowing":false,"isRequested":true}]}
        """.utf8)
        let session = stubbedSession { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.path == "/api/v1/users/search")
            #expect(components.queryItems?.first(where: { $0.name == "username" })?.value == "a+b")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            return response(body: body, statusCode: 200)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        let users = try await client.searchUsers(username: " a+b ", accessToken: "access-token")

        #expect(users == [SocialUser(id: userID, username: "a+b_writer", displayName: "Writer", isPrivate: true, isFollowing: false, isRequested: true)])
    }

    @Test func followingDecodesProtectedList() async throws {
        let userID = UUID()
        let body = Data("""
        {"following":[{"id":"\(userID)","username":"writer","displayName":"Writer","avatarUrl":null,"followedAt":"2026-02-08T12:00:00Z"}]}
        """.utf8)
        let session = stubbedSession { request in
            #expect(request.url?.path == "/api/v1/follows")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            return response(body: body, statusCode: 200)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        let following = try await client.following(accessToken: "access-token")

        #expect(following.count == 1)
        #expect(following[0].id == userID)
        #expect(following[0].displayName == "Writer")
    }

    @Test func followsAndUnfollowsThroughProtectedEndpoints() async throws {
        let userID = UUID()
        let requestCapture = RequestCapture()
        let session = stubbedSession { request in
            let requestIndex = requestCapture.next()
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            if requestIndex == 1 {
                #expect(request.url?.path == "/api/v1/follows")
                #expect(request.httpMethod == "POST")
                let requestBody = try #require(requestBodyData(request))
                let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: String])
                #expect(payload["userId"]?.lowercased() == userID.uuidString.lowercased())
                return response(body: Data(#"{"status":"requested"}"#.utf8), statusCode: 200)
            }
            #expect(request.url?.path == "/api/v1/follows/\(userID.uuidString)")
            #expect(request.httpMethod == "DELETE")
            return response(body: Data(), statusCode: 204)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        #expect(try await client.follow(userID: userID, accessToken: "access-token") == .requested)
        try await client.unfollow(userID: userID, accessToken: "access-token")
        #expect(requestCapture.value == 2)
    }

    @Test func searchRejectsShortUsernameBeforeRequest() async throws {
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!)
        await #expect(throws: SocialClientError.invalidUsername) {
            try await client.searchUsers(username: "ab", accessToken: "access-token")
        }
    }

    @Test func logRequestEncodesTimestampsAsISO8601() throws {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let log = LocalActivityLog(
            title: "Contract log",
            notes: nil,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            categoryIDs: [],
            visibility: .private
        )
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!)
        let request = try client.encodedLogRequest(log, accessToken: "access-token")
        let body = try #require(requestBodyData(request))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(payload["startedAt"] as? String == ISO8601DateFormatter().string(from: startedAt))
        #expect(payload["endedAt"] as? String == ISO8601DateFormatter().string(from: startedAt.addingTimeInterval(60)))
    }

    @Test func failedLoginMapsStructuredServerError() async throws {
        let body = Data(#"{"error":{"code":"INVALID_CREDENTIALS","message":"Invalid username or password"}}"#.utf8)
        let client = TrackerAPIClient(
            baseURL: URL(string: "https://tracker.example.test")!,
            session: stubbedSession { _ in response(body: body, statusCode: 401) }
        )

        await #expect(throws: APIClientError.server(statusCode: 401, code: "INVALID_CREDENTIALS")) {
            try await client.login(username: "missing-user", password: "wrong-password")
        }
    }

    @Test func validationFailureSurfacesFieldMessages() async throws {
        let body = Data(#"{"error":{"code":"INVALID_REQUEST","issues":[{"path":["username"],"code":"invalid_format","message":"Username cannot contain spaces."},{"path":["password"],"code":"too_small","message":"Enter a password."}]}}"#.utf8)
        let client = TrackerAPIClient(
            baseURL: URL(string: "https://tracker.example.test")!,
            session: stubbedSession { _ in response(body: body, statusCode: 400) }
        )

        await #expect(throws: APIClientError.invalidFields(["Username cannot contain spaces.", "Enter a password."])) {
            try await client.register(username: "a b", displayName: "", email: "a@b.co", password: "")
        }
    }

    @Test func validationFailureWithoutMessagesNamesTheFields() async throws {
        let body = Data(#"{"error":{"code":"INVALID_REQUEST","issues":[{"path":["displayName"],"code":"invalid_type"},{"path":["password"],"code":"too_small"}]}}"#.utf8)
        let client = TrackerAPIClient(
            baseURL: URL(string: "https://tracker.example.test")!,
            session: stubbedSession { _ in response(body: body, statusCode: 400) }
        )

        await #expect(throws: APIClientError.invalidFields(["Check the display name field.", "Check the password field."])) {
            try await client.register(username: "galileo", displayName: "", email: "galileo@gmail.com", password: "galileo")
        }
    }

    @Test func followSurfacesSelfFollowError() async throws {
        let body = Data(#"{"error":{"code":"SELF_FOLLOW_NOT_ALLOWED","message":"An account cannot follow itself"}}"#.utf8)
        let client = TrackerAPIClient(
            baseURL: URL(string: "https://tracker.example.test")!,
            session: stubbedSession { _ in response(body: body, statusCode: 400) }
        )

        await #expect(throws: APIClientError.server(statusCode: 400, code: "SELF_FOLLOW_NOT_ALLOWED")) {
            try await client.follow(userID: UUID(), accessToken: "access-token")
        }
    }

    // The bodies below are copied from what the server sends, so a shape mismatch fails here.

    @Test func decodesFollowersAndRequests() async throws {
        let userID = UUID()
        let session = stubbedSession { request in
            if request.url?.path == "/api/v1/followers" {
                return response(body: Data("""
                {"followers":[{"id":"\(userID)","username":"writer","displayName":"Writer","avatarUrl":null,"followedAt":"2026-02-08T12:00:00.123Z","isFollowing":true,"isRequested":false}]}
                """.utf8), statusCode: 200)
            }
            #expect(request.url?.path == "/api/v1/follow-requests")
            return response(body: Data("""
            {"requests":[{"id":"\(userID)","username":"writer","displayName":"Writer","avatarUrl":null,"requestedAt":"2026-02-08T12:00:00.123Z"}]}
            """.utf8), statusCode: 200)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        let followers = try await client.followers(accessToken: "access-token")
        #expect(followers.map(\.id) == [userID])
        #expect(followers[0].isFollowing)
        let requests = try await client.followRequests(accessToken: "access-token")
        #expect(requests.map(\.username) == ["writer"])
    }

    @Test func decodesProfileAndPrivacy() async throws {
        let userID = UUID()
        let session = stubbedSession { request in
            if request.httpMethod == "PUT" {
                #expect(request.url?.path == "/api/v1/me/privacy")
                let body = try #require(requestBodyData(request))
                #expect(String(decoding: body, as: UTF8.self) == #"{"isPrivate":true}"#)
                return response(body: Data(#"{"isPrivate":true,"followerCount":2,"followingCount":1,"pendingRequestCount":3}"#.utf8), statusCode: 200)
            }
            #expect(request.url?.path == "/api/v1/users/\(userID.uuidString)")
            return response(body: Data("""
            {"user":{"id":"\(userID)","username":"writer","displayName":"Writer","avatarUrl":null,"isPrivate":true,"followerCount":4,"followingCount":5,"relationship":{"isFollowing":false,"isRequested":true,"followsYou":true},"canViewLogs":false}}
            """.utf8), statusCode: 200)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        let summary = try await client.setPrivateAccount(true, accessToken: "access-token")
        #expect(summary.pendingRequestCount == 3)
        let profile = try await client.userProfile(id: userID, accessToken: "access-token")
        #expect(profile.relationship.isRequested)
        #expect(!profile.canViewLogs)
        #expect(profile.followerCount == 4)
    }

    @Test func feedEntriesCarryKudosAndComments() async throws {
        let entry = """
        "title":"Reading","notes":null,"startedAt":"2026-02-01T10:00:00.000Z","endedAt":"2026-02-01T10:20:00.000Z","durationSeconds":1200,"visibility":"public","createdAt":"2026-02-01T10:20:01.000Z","author":{"id":"\(UUID())","username":"writer","displayName":"Writer","avatarUrl":null},"categories":[]
        """
        let body = Data("""
        {"items":[{"id":"\(UUID())",\(entry),"kudosCount":2,"viewerGaveKudos":true,"commentCount":1},{"id":"\(UUID())",\(entry)}],"nextCursor":null}
        """.utf8)
        let client = TrackerAPIClient(
            baseURL: URL(string: "https://tracker.example.test")!,
            session: stubbedSession { _ in response(body: body, statusCode: 200) }
        )

        let page = try await client.feedPage(accessToken: "access-token")
        #expect(page.items[0].kudosCount == 2)
        #expect(page.items[0].viewerGaveKudos)
        #expect(page.items[0].commentCount == 1)
        // An entry from a server without kudos decodes with none.
        #expect(page.items[1].kudosCount == 0)
        #expect(!page.items[1].viewerGaveKudos)
    }

    @Test func kudosAndComments() async throws {
        let logID = UUID()
        let commentID = UUID()
        let comment = """
        {"id":"\(commentID)","body":"Nice","createdAt":"2026-02-01T10:21:00.000Z","author":{"id":"\(UUID())","username":"fan","displayName":"Fan"},"canDelete":true}
        """
        let session = stubbedSession { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/v1/logs/\(logID.uuidString)/kudos"):
                return response(body: Data(#"{"kudosCount":1,"viewerGaveKudos":true}"#.utf8), statusCode: 200)
            case ("GET", "/api/v1/logs/\(logID.uuidString)/comments"):
                return response(body: Data(#"{"comments":[\#(comment)],"nextCursor":null}"#.utf8), statusCode: 200)
            case ("POST", "/api/v1/logs/\(logID.uuidString)/comments"):
                let body = try #require(requestBodyData(request))
                #expect(String(decoding: body, as: UTF8.self) == #"{"body":"Nice"}"#)
                return response(body: Data(#"{"comment":\#(comment)}"#.utf8), statusCode: 201)
            default:
                #expect(request.httpMethod == "DELETE")
                #expect(request.url?.path == "/api/v1/comments/\(commentID.uuidString)")
                return response(body: Data(), statusCode: 204)
            }
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        #expect(try await client.giveKudos(logID: logID, accessToken: "access-token") == KudosState(kudosCount: 1, viewerGaveKudos: true))
        let page = try await client.comments(logID: logID, accessToken: "access-token")
        #expect(page.comments.map(\.body) == ["Nice"])
        let added = try await client.addComment("Nice", logID: logID, accessToken: "access-token")
        #expect(added.id == commentID)
        try await client.deleteComment(id: commentID, accessToken: "access-token")
    }

    @Test func decodesTimestampsWithMilliseconds() async throws {
        let body = Data("""
        {"categories":[{"id":"\(UUID())","name":"Writing","colorHex":"#345678","createdAt":"2026-02-08T12:00:00.123Z"}]}
        """.utf8)
        let client = TrackerAPIClient(
            baseURL: URL(string: "https://tracker.example.test")!,
            session: stubbedSession { _ in response(body: body, statusCode: 200) }
        )

        let categories = try await client.categories(accessToken: "access-token")

        let createdAt = try #require(categories.first?.createdAt)
        #expect(abs(createdAt.timeIntervalSince1970 - 1_770_552_000.123) < 0.001)
    }

    @Test func percentEncodesPlusInQueryValues() async throws {
        let session = stubbedSession { request in
            #expect(request.url?.query == "username=a%2Bb")
            return response(body: Data(#"{"users":[]}"#.utf8), statusCode: 200)
        }
        let client = TrackerAPIClient(baseURL: URL(string: "https://tracker.example.test")!, session: session)

        _ = try await client.searchUsers(username: "a+b", accessToken: "access-token")
    }

    private func stubbedSession(
        responder: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)
    ) -> URLSession {
        let protocolType = makeStubProtocol(responder: responder)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolType]
        return URLSession(configuration: configuration)
    }

    private func response(body: Data, statusCode: Int) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: URL(string: "https://tracker.example.test")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let httpBody = request.httpBody { return httpBody }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: 4096)
        if count < 0 { return nil }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private func makeStubProtocol(
    responder: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)
) -> URLProtocol.Type {
    final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var responder: (@Sendable (URLRequest) throws -> (Data, URLResponse))!

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            do {
                let (data, response) = try Self.responder(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    StubURLProtocol.responder = responder
    return StubURLProtocol.self
}
