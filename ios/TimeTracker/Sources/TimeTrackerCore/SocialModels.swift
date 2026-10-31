import Foundation

public struct SocialUser: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let username: String
    public let displayName: String
    public var isPrivate: Bool
    public var isFollowing: Bool
    /// A follow request to this private account is waiting for its owner.
    public var isRequested: Bool

    public init(id: UUID, username: String, displayName: String, isPrivate: Bool = false, isFollowing: Bool, isRequested: Bool = false) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.isPrivate = isPrivate
        self.isFollowing = isFollowing
        self.isRequested = isRequested
    }
}

/// What following someone did: a public account is followed at once, a private one gets a request.
public enum FollowStatus: String, Decodable, Sendable {
    case following
    case requested
}

/// Someone who follows you.
public struct FollowerUser: Decodable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let username: String
    public let displayName: String
    public let avatarUrl: URL?
    public let followedAt: Date
    /// You follow them back.
    public var isFollowing: Bool
    public var isRequested: Bool
}

/// Someone asking to follow your private account.
public struct FollowRequest: Decodable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let username: String
    public let displayName: String
    public let avatarUrl: URL?
    public let requestedAt: Date
}

/// Your own follower counts, waiting requests and whether your account is private.
public struct SocialSummary: Decodable, Equatable, Sendable {
    public let isPrivate: Bool
    public let followerCount: Int
    public let followingCount: Int
    public let pendingRequestCount: Int
}

public struct UserProfile: Decodable, Equatable, Identifiable, Sendable {
    public struct Relationship: Decodable, Equatable, Sendable {
        public var isFollowing: Bool
        public var isRequested: Bool
        public let followsYou: Bool
    }

    public let id: UUID
    public let username: String
    public let displayName: String
    public let avatarUrl: URL?
    public let isPrivate: Bool
    public let followerCount: Int
    public let followingCount: Int
    public let relationship: Relationship
    /// False for a private account you don't follow.
    public let canViewLogs: Bool
}

public struct KudosState: Decodable, Equatable, Sendable {
    public let kudosCount: Int
    public let viewerGaveKudos: Bool
}

public struct LogComment: Decodable, Equatable, Identifiable, Sendable {
    public struct Author: Decodable, Equatable, Sendable {
        public let id: UUID
        public let username: String
        public let displayName: String
    }

    public let id: UUID
    public let body: String
    public let createdAt: Date
    public let author: Author
    /// The commenter and the log's author can delete a comment.
    public let canDelete: Bool
}

public struct CommentPage: Decodable, Equatable, Sendable {
    public let comments: [LogComment]
    public let nextCursor: String?
}

public struct FollowingUser: Decodable, Identifiable, Sendable {
    public let id: UUID
    public let username: String
    public let displayName: String
    public let avatarUrl: URL?
    public let followedAt: Date
}

public enum SocialClientError: Error, Equatable {
    case invalidUsername
}

struct UserSearchEnvelope: Decodable {
    let users: [SocialUser]
}

struct FollowingEnvelope: Decodable {
    let following: [FollowingUser]
}

struct FollowPayload: Encodable {
    let userId: UUID
}

struct FollowResponse: Decodable {
    let status: FollowStatus
}

struct FollowersEnvelope: Decodable {
    let followers: [FollowerUser]
}

struct FollowRequestsEnvelope: Decodable {
    let requests: [FollowRequest]
}

struct UserProfileEnvelope: Decodable {
    let user: UserProfile
}

struct PrivacyPayload: Encodable {
    let isPrivate: Bool
}

struct CommentPayload: Encodable {
    let body: String
}

struct CommentEnvelope: Decodable {
    let comment: LogComment
}
