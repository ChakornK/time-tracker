import type { Database } from "../db/client.js";
import { toDate } from "../db/utils.js";
import type { FeedCache } from "./feed-cache.js";

export class FeedDistributor {
  constructor(
    private readonly db: Database,
    private readonly cache: FeedCache,
    private readonly retentionSeconds: number,
  ) {}

  /**
   * Adds a new log to the cached feed of everyone who can see it: the author, followers for a public
   * log, and the people the author follows for a friends-only log.
   */
  async addLog(logId: string): Promise<void> {
    const log = await this.db
      .selectFrom("logs")
      .select(["id", "user_id", "visibility", "created_at"])
      .where("id", "=", logId)
      .executeTakeFirst();

    if (!log) return;

    const readers = new Set([log.user_id]);
    if (log.visibility === "public") {
      const followers = await this.db
        .selectFrom("follows")
        .select("follower_id")
        .where("following_id", "=", log.user_id)
        .execute();
      for (const row of followers) readers.add(row.follower_id);
    } else if (log.visibility === "friends_only") {
      const friends = await this.db
        .selectFrom("follows")
        .select("following_id")
        .where("follower_id", "=", log.user_id)
        .execute();
      for (const row of friends) readers.add(row.following_id);
    }

    await this.cache.addForFollowers(
      [...readers],
      [{ id: log.id, createdAt: toDate(log.created_at) }],
      this.retentionSeconds,
      { onlyExisting: true },
    );
  }
}
