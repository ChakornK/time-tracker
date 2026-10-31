import type { Database } from "../db/client.js";
import { DomainError } from "../errors.js";
import type { FeedCursor, FeedPage, FeedQuery } from "./schemas.js";
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

export class SocialService {
  constructor(private readonly db: Database) {}

  async follow(followerId: string, followingId: string): Promise<void> {
    if (followerId === followingId) throw new SelfFollowError();

    const target = await this.db
      .selectFrom("users")
      .select("id")
      .where("id", "=", followingId)
      .executeTakeFirst();
    if (!target) throw new FollowTargetNotFoundError();

    await this.db
      .insertInto("follows")
      .values({ follower_id: followerId, following_id: followingId })
      .onConflict((conflict) => conflict.columns(["follower_id", "following_id"]).doNothing())
      .execute();
  }

  async unfollow(followerId: string, followingId: string): Promise<void> {
    await this.db
      .deleteFrom("follows")
      .where("follower_id", "=", followerId)
      .where("following_id", "=", followingId)
      .execute();
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
      .select(["users.id", "users.username", "users.display_name", "follows.following_id as followed_id"])
      .where("users.id", "!=", userId)
      .where("users.username", "ilike", `%${escapeLikePattern(username)}%`)
      .orderBy("users.username", "asc")
      .limit(30)
      .execute();

    return matches.map(({ id, username: matchedUsername, display_name, followed_id }) => ({
      id,
      username: matchedUsername,
      displayName: display_name,
      isFollowing: followed_id !== null,
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
