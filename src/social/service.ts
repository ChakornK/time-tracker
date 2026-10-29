import type { Database } from "../db/client.js";
import { DomainError } from "../errors.js";
import type { RedisClient } from "../cache/redis.js";
import { RedisFeedCache } from "../cache/feed-cache.js";
import type { FeedCursor, FeedPage, FeedQuery } from "./schemas.js";
import { getFeedFromDatabase } from "./feed-query.js";

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
  private readonly cache: RedisFeedCache | undefined;

  constructor(
    private readonly db: Database,
    redis?: RedisClient,
    private readonly cacheRetentionSeconds = 604800,
  ) {
    this.cache = redis ? new RedisFeedCache(redis) : undefined;
  }

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

    await this.clearFeeds(followerId, followingId);
  }

  async unfollow(followerId: string, followingId: string): Promise<void> {
    await this.db
      .deleteFrom("follows")
      .where("follower_id", "=", followerId)
      .where("following_id", "=", followingId)
      .execute();

    await this.clearFeeds(followerId, followingId);
  }

  async listFollowing(userId: string) {
    return this.db
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
    const cursor = query.cursor ? decodeCursor(query.cursor) : undefined;
    const candidates = await this.readCandidates(userId, cursor, query.limit);
    if (candidates) {
      const cachedPage = await getFeedFromDatabase(this.db, userId, query, candidates);
      // Only a full page with more cached after it is known to be complete. A short page may be the
      // end of the cached run rather than the end of the feed, so it comes from the database.
      const hasMore = cachedPage.hasMore || candidates.length > query.limit;
      if (cachedPage.rows.length === query.limit && hasMore) {
        return pageFromRows(cachedPage.rows, true);
      }
    }

    const authoritativePage = await getFeedFromDatabase(this.db, userId, query);
    if (this.cache) await this.cachePage(userId, authoritativePage.rows);
    return pageFromRows(authoritativePage.rows, authoritativePage.hasMore);
  }

  private async readCandidates(userId: string, cursor: FeedCursor | undefined, limit: number): Promise<string[] | undefined> {
    if (!this.cache) return undefined;

    try {
      const entries = await this.cache.getCandidates(
        userId,
        cursor ? { id: cursor.id, createdAt: new Date(cursor.createdAt) } : undefined,
        limit + 1,
      );
      return entries?.map((entry) => entry.id);
    } catch {
      return undefined;
    }
  }

  private async cachePage(userId: string, rows: Array<{ id: string; createdAt: Date }>): Promise<void> {
    try {
      await this.cache?.addForFollowers(
        [userId],
        rows.map((row) => ({ id: row.id, createdAt: row.createdAt })),
        this.cacheRetentionSeconds,
      );
    } catch {
      return;
    }
  }

  /**
   * A follow change alters which logs both users can see, including friends-only logs, so their cached
   * feeds are dropped and rebuilt from the database on the next read.
   */
  private async clearFeeds(...userIDs: string[]): Promise<void> {
    try {
      await this.cache?.clear(userIDs);
    } catch {
      return;
    }
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
