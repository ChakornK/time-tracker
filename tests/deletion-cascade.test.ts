import assert from "node:assert/strict";
import test from "node:test";
import { loadConfig } from "../src/config.js";
import { createDatabase } from "../src/db/client.js";

const config = loadConfig({
  NODE_ENV: "test",
  DATABASE_URL: "postgres://tracker:tracker@localhost:55432/tracker",
  JWT_SECRET: "a-secret-key-that-is-at-least-32-characters-long",
});

test("foreign-key cascades clean up categories, logs, joins, and follows", async (t) => {
  const database = createDatabase(config);
  const userID = crypto.randomUUID();
  const otherUserID = crypto.randomUUID();
  const categoryID = crypto.randomUUID();
  const logID = crypto.randomUUID();
  const categoryLogID = crypto.randomUUID();
  const idempotencyKey = crypto.randomUUID();
  const categoryLogKey = crypto.randomUUID();

  t.after(async () => {
    await database.db.deleteFrom("users").where("id", "in", [userID, otherUserID]).execute();
    await database.close();
  });

  await database.db.insertInto("users").values([
    { id: userID, username: `cascade_${userID.slice(0, 8)}`, display_name: "Cascade Owner", email: `${userID}@example.test`, password_hash: "test" },
    { id: otherUserID, username: `cascade_${otherUserID.slice(0, 8)}`, display_name: "Cascade Other", email: `${otherUserID}@example.test`, password_hash: "test" },
  ]).execute();
  await database.db.insertInto("follows").values({ follower_id: otherUserID, following_id: userID }).execute();
  await database.db.insertInto("categories").values({ id: categoryID, user_id: userID, name: "Delete me" }).execute();
  await database.db.insertInto("logs").values([
    { id: logID, user_id: userID, title: "Log removed with user", started_at: "2026-02-08T10:00:00Z", ended_at: "2026-02-08T10:10:00Z", idempotency_key: idempotencyKey },
    { id: categoryLogID, user_id: otherUserID, title: "Log survives category delete", started_at: "2026-02-08T11:00:00Z", ended_at: "2026-02-08T11:10:00Z", idempotency_key: categoryLogKey },
  ]).execute();
  await database.db.insertInto("log_categories").values({ log_id: categoryLogID, category_id: categoryID }).execute();

  await database.db.deleteFrom("categories").where("id", "=", categoryID).execute();
  assert.equal(await database.db.selectFrom("log_categories").selectAll().where("log_id", "=", categoryLogID).executeTakeFirst(), undefined);
  assert.ok(await database.db.selectFrom("logs").select("id").where("id", "=", categoryLogID).executeTakeFirst());

  await database.db.deleteFrom("users").where("id", "=", userID).execute();
  assert.equal(await database.db.selectFrom("logs").select("id").where("id", "=", logID).executeTakeFirst(), undefined);
  assert.equal(await database.db.selectFrom("follows").selectAll().where((eb) => eb.or([
    eb("follower_id", "=", userID), eb("following_id", "=", userID),
  ])).executeTakeFirst(), undefined);
  assert.ok(await database.db.selectFrom("users").select("id").where("id", "=", otherUserID).executeTakeFirst());
});
