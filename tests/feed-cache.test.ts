import assert from "node:assert/strict";
import test from "node:test";
import { createClient } from "redis";
import { createDatabase } from "../src/db/client.js";
import { loadConfig } from "../src/config.js";
import { RedisFeedCache } from "../src/cache/feed-cache.js";
import { FeedDistributor } from "../src/cache/feed-distributor.js";
import { buildApp } from "../src/app.js";
import { SocialService } from "../src/social/service.js";

const config = loadConfig({
  NODE_ENV: "test",
  DATABASE_URL: "postgres://tracker:tracker@localhost:55432/tracker",
  REDIS_URL: "redis://localhost:6380",
  JWT_SECRET: "a-secret-key-that-is-at-least-32-characters-long",
});

test("Redis feed cache fans out public logs and PostgreSQL repairs misses", async (t) => {
  const database = createDatabase(config);
  const redis = createClient({ url: config.REDIS_URL });
  redis.on("error", () => {});
  await redis.connect();
  const cache = new RedisFeedCache(redis);
  const testUserIDs: string[] = [];
  const testPrefix = `cache_${crypto.randomUUID().slice(0, 8)}`;
  const viewerId = crypto.randomUUID();
  const authorId = crypto.randomUUID();
  testUserIDs.push(viewerId, authorId);
  let app: ReturnType<typeof buildApp> | undefined;

  t.after(async () => {
    if (app) await app.close();
    if (redis.isOpen) {
      await redis.del(`feed:${viewerId}`);
      await redis.quit();
    }
    if (testUserIDs.length) await database.db.deleteFrom("users").where("id", "in", testUserIDs).execute();
    await database.close();
  });

  await database.db.insertInto("users").values([
    { id: viewerId, username: `${testPrefix}-viewer`, display_name: "Viewer", email: `${testPrefix}-viewer@example.test`, password_hash: "hash" },
    { id: authorId, username: `${testPrefix}-author`, display_name: "Author", email: `${testPrefix}-author@example.test`, password_hash: "hash" },
  ]).execute();
  await database.db.insertInto("follows").values({ follower_id: viewerId, following_id: authorId }).execute();

  const logs = await database.db.insertInto("logs").values([
    {
      user_id: authorId,
      title: "Public cached",
      started_at: new Date("2026-03-01T10:00:00Z"),
      ended_at: new Date("2026-03-01T10:30:00Z"),
      visibility: "public",
      idempotency_key: crypto.randomUUID(),
    },
    {
      user_id: authorId,
      title: "Private not cached",
      started_at: new Date("2026-03-01T11:00:00Z"),
      ended_at: new Date("2026-03-01T11:30:00Z"),
      visibility: "private",
      idempotency_key: crypto.randomUUID(),
    },
  ]).returning(["id", "visibility", "created_at"]).execute();

  const distributor = new FeedDistributor(database.db, cache, 86400);
  await Promise.all(logs.map((log) => distributor.addLog(log.id)));
  assert.equal(await cache.getCandidates(viewerId), null, "fan-out must not start a partial feed");

  const social = new SocialService(database.db, redis);
  const cachedPage = await social.getFeedPage(viewerId, { limit: 10 });
  assert.equal(cachedPage.items.length, 1);
  assert.equal(cachedPage.items[0]?.title, "Public cached");
  const indexed = await cache.getCandidates(viewerId);
  assert.deepEqual(indexed?.map((entry) => entry.id), [logs.find((log) => log.visibility === "public")?.id]);

  await redis.del(`feed:${viewerId}`);
  const recoveredPage = await social.getFeedPage(viewerId, { limit: 10 });
  assert.equal(recoveredPage.items.length, 1, JSON.stringify(recoveredPage));
  assert.equal(recoveredPage.items[0]?.title, "Public cached");
  assert.equal((await cache.getCandidates(viewerId))?.length, 1);

  const noCache = new SocialService(database.db);
  const authoritativePage = await noCache.getFeedPage(viewerId, { limit: 10 });
  assert.deepEqual(authoritativePage.items.map((item) => item.id), recoveredPage.items.map((item) => item.id));

  const cacheError = new Error("Redis unavailable");
  const disconnectedCache = {
    addForFollowers: async () => { throw cacheError; },
    getCandidates: async () => { throw cacheError; },
    clear: async () => { throw cacheError; },
  };
  const disconnectedSocial = new SocialService(database.db, disconnectedCache as never);
  const disconnectedPage = await disconnectedSocial.getFeedPage(viewerId, { limit: 10 });
  assert.deepEqual(disconnectedPage.items.map((item) => item.id), authoritativePage.items.map((item) => item.id));

  const publisher = new FeedDistributor(database.db, disconnectedCache, 86400);
  await assert.rejects(() => publisher.addLog(logs[0]!.id), cacheError);

  app = buildApp({ config, db: database.db, redis: redis as never, logger: false });
  await app.ready();
  const publisherAccount = await registerAccount(app, testPrefix, "api-publisher");
  testUserIDs.push(publisherAccount.id);
  const viewerAccount = await registerAccount(app, testPrefix, "api-viewer");
  testUserIDs.push(viewerAccount.id);

  const publicLog = await app.inject({
    method: "POST",
    url: "/api/v1/logs",
    headers: { authorization: `Bearer ${publisherAccount.token}` },
    payload: {
      idempotencyKey: crypto.randomUUID(),
      title: "Visible over API after cache miss",
      startedAt: "2026-03-02T10:00:00.000Z",
      endedAt: "2026-03-02T10:10:00.000Z",
      categoryIds: [],
      visibility: "public",
    },
  });
  assert.equal(publicLog.statusCode, 201);
  const privateLog = await app.inject({
    method: "POST",
    url: "/api/v1/logs",
    headers: { authorization: `Bearer ${publisherAccount.token}` },
    payload: {
      idempotencyKey: crypto.randomUUID(),
      title: "Private API log must stay hidden",
      startedAt: "2026-03-02T11:00:00.000Z",
      endedAt: "2026-03-02T11:10:00.000Z",
      categoryIds: [],
      visibility: "private",
    },
  });
  assert.equal(privateLog.statusCode, 201);

  const follow = await app.inject({
    method: "POST",
    url: "/api/v1/follows",
    headers: { authorization: `Bearer ${viewerAccount.token}` },
    payload: { userId: publisherAccount.id },
  });
  assert.equal(follow.statusCode, 204);

  const apiFeed = await app.inject({
    method: "GET",
    url: "/api/v1/feed?limit=20",
    headers: { authorization: `Bearer ${viewerAccount.token}` },
  });
  assert.equal(apiFeed.statusCode, 200, apiFeed.body);
  assert.ok(apiFeed.json().items.some((item: { title: string }) => item.title === "Visible over API after cache miss"));
  assert.ok(!apiFeed.json().items.some((item: { title: string }) => item.title === "Private API log must stay hidden"));
});

test("cached feeds include your own and friends-only logs, and later pages", async (t) => {
  const database = createDatabase(config);
  const redis = createClient({ url: config.REDIS_URL });
  redis.on("error", () => {});
  await redis.connect();
  const cache = new RedisFeedCache(redis);
  const prefix = `own_${crypto.randomUUID().slice(0, 8)}`;
  const viewerId = crypto.randomUUID();
  const friendId = crypto.randomUUID();

  t.after(async () => {
    await redis.del([`feed:${viewerId}`, `feed:${friendId}`]);
    await redis.quit();
    await database.db.deleteFrom("users").where("id", "in", [viewerId, friendId]).execute();
    await database.close();
  });

  await database.db.insertInto("users").values([
    { id: viewerId, username: `${prefix}-viewer`, display_name: "Viewer", email: `${prefix}-viewer@example.test`, password_hash: "hash" },
    { id: friendId, username: `${prefix}-friend`, display_name: "Friend", email: `${prefix}-friend@example.test`, password_hash: "hash" },
  ]).execute();
  // The friend follows the viewer, which is what lets the viewer see the friend's friends-only logs.
  await database.db.insertInto("follows").values([
    { follower_id: viewerId, following_id: friendId },
    { follower_id: friendId, following_id: viewerId },
  ]).execute();

  const insertLog = async (userId: string, title: string, visibility: "public" | "private" | "friends_only", minute: number) => {
    const row = await database.db.insertInto("logs").values({
      user_id: userId,
      title,
      started_at: new Date("2026-03-01T09:00:00Z"),
      ended_at: new Date("2026-03-01T09:30:00Z"),
      visibility,
      idempotency_key: crypto.randomUUID(),
      // `Generated<Timestamp>` resolves to the column type itself on insert, so Kysely rejects a plain Date.
      created_at: new Date(Date.UTC(2026, 2, 1, 10, minute)) as never,
    }).returning("id").executeTakeFirstOrThrow();
    return row.id;
  };
  for (const minute of [1, 2, 3]) await insertLog(friendId, `Public ${minute}`, "public", minute);

  const social = new SocialService(database.db, redis);
  const firstPage = await social.getFeedPage(viewerId, { limit: 2 });
  assert.deepEqual(firstPage.items.map((item) => item.title), ["Public 3", "Public 2"]);
  assert.ok(firstPage.nextCursor);

  // Only the first page is cached, so the next page must come from the database rather than look empty.
  const secondPage = await social.getFeedPage(viewerId, { limit: 2, cursor: firstPage.nextCursor });
  assert.deepEqual(secondPage.items.map((item) => item.title), ["Public 1"]);

  const distributor = new FeedDistributor(database.db, cache, 86400);
  await distributor.addLog(await insertLog(viewerId, "My private log", "private", 4));
  await distributor.addLog(await insertLog(friendId, "Friends-only log", "friends_only", 5));

  const newest = await social.getFeedPage(viewerId, { limit: 2 });
  assert.deepEqual(newest.items.map((item) => item.title), ["Friends-only log", "My private log"]);

  await social.unfollow(viewerId, friendId);
  assert.equal(await cache.getCandidates(viewerId), null);
  assert.equal(await cache.getCandidates(friendId), null);
});

async function registerAccount(app: ReturnType<typeof buildApp>, prefix: string, role: string) {
  const username = `${prefix}-${role}`;
  const password = "correct horse battery staple";
  const response = await app.inject({
    method: "POST",
    url: "/api/v1/auth/register",
    payload: { username, displayName: role, email: `${username}@example.test`, password },
  });
  assert.equal(response.statusCode, 201, response.body);
  const login = await app.inject({
    method: "POST",
    url: "/api/v1/auth/login",
    payload: { username, password },
  });
  assert.equal(login.statusCode, 200, login.body);
  return { id: response.json().user.id as string, token: login.json().accessToken as string };
}
