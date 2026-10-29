import assert from "node:assert/strict";
import test from "node:test";
import { createDatabase } from "../src/db/client.js";
import { loadConfig } from "../src/config.js";
import { SocialService } from "../src/social/service.js";

const config = loadConfig({
  NODE_ENV: "test",
  DATABASE_URL: "postgres://tracker:tracker@localhost:55432/tracker",
  JWT_SECRET: "a-secret-key-that-is-at-least-32-characters-long",
});

test("the feed combines your logs with friends' logs, newest first, across pages", async (t) => {
  const database = createDatabase(config);
  const prefix = `feed_${crypto.randomUUID().slice(0, 8)}`;
  const viewerId = crypto.randomUUID();
  const friendId = crypto.randomUUID();
  const strangerId = crypto.randomUUID();

  t.after(async () => {
    await database.db.deleteFrom("users").where("id", "in", [viewerId, friendId, strangerId]).execute();
    await database.close();
  });

  await database.db.insertInto("users").values([viewerId, friendId, strangerId].map((id, index) => ({
    id,
    username: `${prefix}-${index}`,
    display_name: `User ${index}`,
    email: `${prefix}-${index}@example.test`,
    password_hash: "hash",
  }))).execute();
  // The friend follows the viewer back, which is what lets the viewer see the friend's friends-only logs.
  await database.db.insertInto("follows").values([
    { follower_id: viewerId, following_id: friendId },
    { follower_id: friendId, following_id: viewerId },
  ]).execute();

  const insertLog = async (userId: string, title: string, visibility: "public" | "private" | "friends_only", minute: number) => {
    await database.db.insertInto("logs").values({
      user_id: userId,
      title,
      started_at: new Date("2026-03-01T09:00:00Z"),
      ended_at: new Date("2026-03-01T09:30:00Z"),
      visibility,
      idempotency_key: crypto.randomUUID(),
      // `Generated<Timestamp>` resolves to the column type itself on insert, so Kysely rejects a plain Date.
      created_at: new Date(Date.UTC(2026, 2, 1, 10, minute)) as never,
    }).execute();
  };
  await insertLog(friendId, "Friend public", "public", 1);
  await insertLog(viewerId, "My private", "private", 2);
  await insertLog(friendId, "Friend friends-only", "friends_only", 3);
  await insertLog(friendId, "Friend private", "private", 4);
  await insertLog(strangerId, "Stranger public", "public", 5);

  const social = new SocialService(database.db);
  const firstPage = await social.getFeedPage(viewerId, { limit: 2 });
  assert.deepEqual(firstPage.items.map((item) => item.title), ["Friend friends-only", "My private"]);
  // Your own entries carry their idempotency key so your device can match them; others' never do.
  assert.ok(firstPage.items.find((item) => item.title === "My private")?.idempotencyKey);
  assert.equal(firstPage.items.find((item) => item.title === "Friend friends-only")?.idempotencyKey, undefined);
  assert.ok(firstPage.nextCursor);

  const secondPage = await social.getFeedPage(viewerId, { limit: 2, cursor: firstPage.nextCursor });
  assert.deepEqual(secondPage.items.map((item) => item.title), ["Friend public"]);
  assert.equal(secondPage.nextCursor, null);
});
