import type { Database } from "../db/client.js";
import { DomainError } from "../errors.js";
import type { FeedCursor, FeedPage, FeedQuery, FollowStatus } from "./schemas.js";
import { getFeedFromDatabase } from "./feed-query.js";
import { toDate } from "../db/utils.js";

export class FollowTargetNotFoundError extends DomainError {
  constructor() {
    super(404, "USER_NOT_FOUND", "User not found");
  }
}

export class SelfFollowError extends DomainError {
  constructor() {
    super(400, "SELF_FOLLOW_NOT_ALLOWED", "An account cannot follow itself");
  }
}

export class PrivateProfileError extends DomainError {
  constructor() {
    super(403, "PROFILE_PRIVATE", "This account is private");
  }
}

export interface SocialSummary {
  isPrivate: boolean;
  followerCount: number;
  followingCount: number;
  pendingRequestCount: number;
}

export interface UserProfile {
  id: string;
  username: string;
  displayName: string;
  avatarUrl: string | null;
  isPrivate: boolean;
  followerCount: number;
  followingCount: number;
  relationship: {
    isFollowing: boolean;
    isRequested: boolean;
    followsYou: boolean;
  };
  /** False for a private account the viewer doesn't follow. */
  canViewLogs: boolean;
}

export class SocialService {
  constructor(private readonly db: Database) {}

  /** Follows a public account straight away; a private one gets a request its owner accepts. */
  async follow(followerId: string, followingId: string): Promise<FollowStatus> {
    if (followerId === followingId) throw new SelfFollowError();

    return this.db.transaction().execute(async (transaction) => {
      // Locked so a switch to public can't accept requests between this check and the insert.
      const target = await transaction
        .selectFrom("users")
        .select("is_private")
        .where("id", "=", followingId)
        .forShare()
        .executeTakeFirst();
      if (!target) throw new FollowTargetNotFoundError();

      const existing = await transaction
        .selectFrom("follows")
        .select("follower_id")
        .where("follower_id", "=", followerId)
        .where("following_id", "=", followingId)
        .executeTakeFirst();
      if (existing) return "following";

      if (target.is_private) {
        await transaction
          .insertInto("follow_requests")
          .values({ requester_id: followerId, target_id: followingId })
          .onConflict((conflict) => conflict.columns(["requester_id", "target_id"]).doNothing())
          .execute();
        return "requested";
      }

      await transaction
        .insertInto("follows")
        .values({ follower_id: followerId, following_id: followingId })
        .onConflict((conflict) => conflict.columns(["follower_id", "following_id"]).doNothing())
        .execute();
      return "following";
    });
  }

  /** Also withdraws a pending request. */
  async unfollow(followerId: string, followingId: string): Promise<void> {
    await this.db.transaction().execute(async (transaction) => {
      // The request goes first: if an accept is moving it into `follows` right now, this waits for
      // that to commit, and the follow it created is then deleted below instead of surviving.
      await transaction
        .deleteFrom("follow_requests")
        .where("requester_id", "=", followerId)
        .where("target_id", "=", followingId)
        .execute();
      await transaction
        .deleteFrom("follows")
        .where("follower_id", "=", followerId)
        .where("following_id", "=", followingId)
        .execute();
    });
  }

  async listFollowers(userId: string) {
    const rows = await this.db
      .selectFrom("follows")
      .innerJoin("users", "users.id", "follows.follower_id")
      .leftJoin("follows as back", (join) => join
        .onRef("back.following_id", "=", "follows.follower_id")
        .on("back.follower_id", "=", userId))
      .leftJoin("follow_requests", (join) => join
        .onRef("follow_requests.target_id", "=", "follows.follower_id")
        .on("follow_requests.requester_id", "=", userId))
      .select([
        "users.id",
        "users.username",
        "users.display_name",
        "users.avatar_url",
        "follows.created_at as followed_at",
        "back.following_id as followed_back_id",
        "follow_requests.target_id as requested_id",
      ])
      .where("follows.following_id", "=", userId)
      .orderBy("users.username", "asc")
      .execute();

    return rows.map((row) => ({
      id: row.id,
      username: row.username,
      displayName: row.display_name,
      avatarUrl: row.avatar_url,
      followedAt: toDate(row.followed_at),
      isFollowing: row.followed_back_id !== null,
      isRequested: row.requested_id !== null,
    }));
  }

  async removeFollower(userId: string, followerId: string): Promise<void> {
    await this.db
      .deleteFrom("follows")
      .where("follower_id", "=", followerId)
      .where("following_id", "=", userId)
      .execute();
  }

  async listFollowRequests(userId: string) {
    const rows = await this.db
      .selectFrom("follow_requests")
      .innerJoin("users", "users.id", "follow_requests.requester_id")
      .select([
        "users.id",
        "users.username",
        "users.display_name",
        "users.avatar_url",
        "follow_requests.created_at as requested_at",
      ])
      .where("follow_requests.target_id", "=", userId)
      .orderBy("follow_requests.created_at", "desc")
      .execute();

    return rows.map((row) => ({
      id: row.id,
      username: row.username,
      displayName: row.display_name,
      avatarUrl: row.avatar_url,
      requestedAt: toDate(row.requested_at),
    }));
  }

  /** A request that's already gone, such as one its sender withdrew, is a no-op, like a decline. */
  async acceptFollowRequest(userId: string, requesterId: string): Promise<void> {
    await this.db.transaction().execute(async (transaction) => {
      const request = await transaction
        .deleteFrom("follow_requests")
        .where("requester_id", "=", requesterId)
        .where("target_id", "=", userId)
        .returning("requester_id")
        .executeTakeFirst();
      if (!request) return;

      await transaction
        .insertInto("follows")
        .values({ follower_id: requesterId, following_id: userId })
        .onConflict((conflict) => conflict.columns(["follower_id", "following_id"]).doNothing())
        .execute();
    });
  }

  async declineFollowRequest(userId: string, requesterId: string): Promise<void> {
    await this.db
      .deleteFrom("follow_requests")
      .where("requester_id", "=", requesterId)
      .where("target_id", "=", userId)
      .execute();
  }

  async getSocialSummary(userId: string): Promise<SocialSummary> {
    const row = await this.db
      .selectFrom("users")
      .select((expression) => [
        "users.is_private",
        expression.selectFrom("follows").select(expression.fn.countAll<string>().as("count"))
          .whereRef("follows.following_id", "=", "users.id").as("follower_count"),
        expression.selectFrom("follows").select(expression.fn.countAll<string>().as("count"))
          .whereRef("follows.follower_id", "=", "users.id").as("following_count"),
        expression.selectFrom("follow_requests").select(expression.fn.countAll<string>().as("count"))
          .whereRef("follow_requests.target_id", "=", "users.id").as("request_count"),
      ])
      .where("users.id", "=", userId)
      .executeTakeFirst();
    if (!row) throw new FollowTargetNotFoundError();

    return {
      isPrivate: row.is_private,
      followerCount: Number(row.follower_count ?? 0),
      followingCount: Number(row.following_count ?? 0),
      pendingRequestCount: Number(row.request_count ?? 0),
    };
  }

  /** Going public accepts every pending request, since a public account needs no approval. */
  async setPrivacy(userId: string, isPrivate: boolean): Promise<SocialSummary> {
    await this.db.transaction().execute(async (transaction) => {
      await transaction.updateTable("users").set({ is_private: isPrivate }).where("id", "=", userId).execute();
      if (isPrivate) return;

      const requests = await transaction
        .deleteFrom("follow_requests")
        .where("target_id", "=", userId)
        .returning("requester_id")
        .execute();
      if (requests.length === 0) return;
      await transaction
        .insertInto("follows")
        .values(requests.map((request) => ({ follower_id: request.requester_id, following_id: userId })))
        .onConflict((conflict) => conflict.columns(["follower_id", "following_id"]).doNothing())
        .execute();
    });
    return this.getSocialSummary(userId);
  }

  async getUserProfile(viewerId: string, userId: string): Promise<UserProfile> {
    const user = await this.db
      .selectFrom("users")
      .leftJoin("follows as viewer_follow", (join) => join
        .onRef("viewer_follow.following_id", "=", "users.id")
        .on("viewer_follow.follower_id", "=", viewerId))
      .leftJoin("follows as author_follow", (join) => join
        .onRef("author_follow.follower_id", "=", "users.id")
        .on("author_follow.following_id", "=", viewerId))
      .leftJoin("follow_requests", (join) => join
        .onRef("follow_requests.target_id", "=", "users.id")
        .on("follow_requests.requester_id", "=", viewerId))
      .select([
        "users.id",
        "users.username",
        "users.display_name",
        "users.avatar_url",
        "viewer_follow.follower_id as viewer_follows",
        "author_follow.following_id as follows_viewer",
        "follow_requests.requester_id as requested",
      ])
      .where("users.id", "=", userId)
      .executeTakeFirst();
    if (!user) throw new FollowTargetNotFoundError();

    const summary = await this.getSocialSummary(userId);
    const isFollowing = user.viewer_follows !== null;
    return {
      id: user.id,
      username: user.username,
      displayName: user.display_name,
      avatarUrl: user.avatar_url,
      isPrivate: summary.isPrivate,
      followerCount: summary.followerCount,
      followingCount: summary.followingCount,
      relationship: {
        isFollowing,
        isRequested: user.requested !== null,
        followsYou: user.follows_viewer !== null,
      },
      // Someone a private account follows can see its friends-only logs, so their list isn't closed.
      canViewLogs: viewerId === userId || !summary.isPrivate || isFollowing || user.follows_viewer !== null,
    };
  }

  async getUserLogs(viewerId: string, userId: string, query: FeedQuery): Promise<FeedPage> {
    const profile = await this.getUserProfile(viewerId, userId);
    if (!profile.canViewLogs) throw new PrivateProfileError();
    const { rows, hasMore } = await getFeedFromDatabase(this.db, viewerId, query, userId);
    return pageFromRows(rows, hasMore);
  }

  async listFollowing(userId: string) {
    const rows = await this.db
      .selectFrom("follows")
      .innerJoin("users", "users.id", "follows.following_id")
      .select([
        "users.id",
        "users.username",
        "users.display_name",
        "users.avatar_url",
        "follows.created_at as followed_at",
      ])
      .where("follows.follower_id", "=", userId)
      .orderBy("users.username", "asc")
      .execute();

    return rows.map((row) => ({
      id: row.id,
      username: row.username,
      displayName: row.display_name,
      avatarUrl: row.avatar_url,
      followedAt: toDate(row.followed_at),
    }));
  }

  async searchUsers(userId: string, username: string) {
    const matches = await this.db
      .selectFrom("users")
      .leftJoin("follows", (join) => join
        .onRef("follows.following_id", "=", "users.id")
        .on("follows.follower_id", "=", userId))
      .leftJoin("follow_requests", (join) => join
        .onRef("follow_requests.target_id", "=", "users.id")
        .on("follow_requests.requester_id", "=", userId))
      .select([
        "users.id",
        "users.username",
        "users.display_name",
        "users.is_private",
        "follows.following_id as followed_id",
        "follow_requests.target_id as requested_id",
      ])
      .where("users.id", "!=", userId)
      .where("users.username", "ilike", `%${escapeLikePattern(username)}%`)
      .orderBy("users.username", "asc")
      .limit(30)
      .execute();

    return matches.map((match) => ({
      id: match.id,
      username: match.username,
      displayName: match.display_name,
      isPrivate: match.is_private,
      isFollowing: match.followed_id !== null,
      isRequested: match.requested_id !== null,
    }));
  }

  async getFeedPage(userId: string, query: FeedQuery): Promise<FeedPage> {
    const { rows, hasMore } = await getFeedFromDatabase(this.db, userId, query);
    return pageFromRows(rows, hasMore);
  }

}

function escapeLikePattern(value: string): string {
  return value.replace(/[\\%_]/g, "\\$&");
}

export function decodeCursor(value: string): FeedCursor {
  try {
    const parsed: unknown = JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
    if (
      typeof parsed !== "object" || parsed === null ||
      !("createdAt" in parsed) || typeof parsed.createdAt !== "string" ||
      Number.isNaN(Date.parse(parsed.createdAt)) ||
      !("id" in parsed) || typeof parsed.id !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(parsed.id)
    ) {
      throw new Error("invalid cursor");
    }
    return { createdAt: parsed.createdAt, id: parsed.id };
  } catch {
    throw new Error("Invalid feed cursor");
  }
}

function encodeCursor(cursor: FeedCursor): string {
  return Buffer.from(JSON.stringify(cursor)).toString("base64url");
}

function pageFromRows(rows: Awaited<ReturnType<typeof getFeedFromDatabase>>["rows"], hasMore: boolean): FeedPage {
  const last = rows.at(-1);
  return {
    items: rows,
    nextCursor: hasMore && last
      ? encodeCursor({ createdAt: last.createdAt.toISOString(), id: last.id })
      : null,
  };
}
