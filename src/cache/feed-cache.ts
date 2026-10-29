import type { RedisClient } from "./redis.js";

export interface FeedCandidate {
  id: string;
  createdAt: Date;
}

/**
 * Each user's feed as log IDs ordered by creation time. An entry covers a contiguous run of the newest
 * logs, built from database pages, so fan-out only extends entries that already exist.
 */
export interface FeedCache {
  addForFollowers(
    followerIDs: string[],
    logs: FeedCandidate[],
    retentionSeconds: number,
    options?: { onlyExisting?: boolean },
  ): Promise<void>;
  getCandidates(userId: string, before?: FeedCandidate, limit?: number): Promise<FeedCandidate[] | null>;
  clear(userIDs: string[]): Promise<void>;
}

export class RedisFeedCache implements FeedCache {
  constructor(private readonly client: RedisClient) {}

  async addForFollowers(
    followerIDs: string[],
    logs: FeedCandidate[],
    retentionSeconds: number,
    options: { onlyExisting?: boolean } = {},
  ): Promise<void> {
    if (followerIDs.length === 0 || logs.length === 0) return;

    await Promise.all(followerIDs.map(async (followerId) => {
      const key = feedKey(followerId);
      // Creating an entry here would hold only the new log, which readers would take as the whole feed.
      if (options.onlyExisting && !(await this.client.exists(key))) return;
      const commands = this.client.multi();
      for (const log of logs) {
        commands.zAdd(key, { score: log.createdAt.getTime(), value: log.id });
      }
      const newest = Math.max(...logs.map((log) => log.createdAt.getTime()));
      commands.zRemRangeByScore(key, "-inf", newest - retentionSeconds * 1000);
      await commands.exec();
    }));
  }

  async getCandidates(
    userId: string,
    before?: FeedCandidate,
    limit = 100,
  ): Promise<FeedCandidate[] | null> {
    const key = feedKey(userId);
    const exists = await this.client.exists(key);
    if (!exists) return null;

    const entries = await this.client.zRangeWithScores(key, 0, -1, {
      REV: true,
    });
    const candidates = entries
      .map(({ value, score }) => ({ id: value, createdAt: new Date(score) }))
      .filter((candidate) => !before || isBefore(candidate, before));

    return candidates.slice(0, limit);
  }

  async clear(userIDs: string[]): Promise<void> {
    if (userIDs.length === 0) return;
    await this.client.del(userIDs.map(feedKey));
  }
}

function isBefore(candidate: FeedCandidate, cursor: FeedCandidate): boolean {
  return candidate.createdAt.getTime() < cursor.createdAt.getTime() ||
    (candidate.createdAt.getTime() === cursor.createdAt.getTime() && candidate.id < cursor.id);
}

export function feedKey(userId: string): string {
  return `feed:${userId}`;
}
