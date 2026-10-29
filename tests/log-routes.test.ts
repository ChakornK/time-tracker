import assert from "node:assert/strict";
import test from "node:test";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { createDatabase } from "../src/db/client.js";

const config = loadConfig({
  NODE_ENV: "test",
  DATABASE_URL: "postgres://tracker:tracker@localhost:55432/tracker",
  JWT_SECRET: "a-secret-key-that-is-at-least-32-characters-long",
});

test("log ingestion validates inputs, enforces category ownership, and is idempotent", async (t) => {
  const database = createDatabase(config);
  const app = buildApp({ config, db: database.db, logger: false });
  await app.ready();
  const userIDs: string[] = [];

  t.after(async () => {
    if (userIDs.length) {
      await database.db.deleteFrom("users").where("id", "in", userIDs).execute();
    }
    await app.close();
    await database.close();
  });

  const owner = await createAccount(app, "log_owner");
  const other = await createAccount(app, "log_other");
  userIDs.push(owner.id, other.id);

  const categoryResponse = await app.inject({
    method: "POST",
    url: "/api/v1/categories",
    headers: { authorization: `Bearer ${owner.token}` },
    payload: { name: "Research" },
  });
  assert.equal(categoryResponse.statusCode, 201);
  const categoryID = categoryResponse.json().category.id as string;

  const idempotencyKey = crypto.randomUUID();
  const payload = {
    idempotencyKey,
    title: "Read source material",
    notes: "Offline session",
    startedAt: "2026-01-01T10:00:00.000Z",
    endedAt: "2026-01-01T10:25:00.000Z",
    categoryIds: [categoryID],
    visibility: "private",
  };

  const created = await app.inject({
    method: "POST",
    url: "/api/v1/logs",
    headers: { authorization: `Bearer ${owner.token}` },
    payload,
  });
  assert.equal(created.statusCode, 201);
  assert.equal(created.json().created, true);

  const duplicate = await app.inject({
    method: "POST",
    url: "/api/v1/logs",
    headers: { authorization: `Bearer ${owner.token}` },
    payload,
  });
  assert.equal(duplicate.statusCode, 200);
  assert.equal(duplicate.json().created, false);
  assert.equal(duplicate.json().id, created.json().id);

  const concurrentIdempotencyKey = crypto.randomUUID();
  const concurrentPayload = { ...payload, idempotencyKey: concurrentIdempotencyKey };
  const concurrentResults = await Promise.all([
    app.inject({
      method: "POST",
      url: "/api/v1/logs",
      headers: { authorization: `Bearer ${owner.token}` },
      payload: concurrentPayload,
    }),
    app.inject({
      method: "POST",
      url: "/api/v1/logs",
      headers: { authorization: `Bearer ${owner.token}` },
      payload: concurrentPayload,
    }),
  ]);
  assert.deepEqual(concurrentResults.map((response) => response.statusCode).sort((a, b) => a - b), [200, 201]);
  assert.equal(concurrentResults[0]?.json().id, concurrentResults[1]?.json().id);

  const mismatchedRetry = await app.inject({
    method: "POST",
    url: "/api/v1/logs",
    headers: { authorization: `Bearer ${owner.token}` },
    payload: { ...payload, title: "Different payload" },
  });
  assert.equal(mismatchedRetry.statusCode, 409);

  const wrongOwnerCategory = await app.inject({
    method: "POST",
    url: "/api/v1/logs",
    headers: { authorization: `Bearer ${other.token}` },
    payload: { ...payload, idempotencyKey: crypto.randomUUID() },
  });
  assert.equal(wrongOwnerCategory.statusCode, 400);
  assert.equal(wrongOwnerCategory.json().error.code, "INVALID_CATEGORIES");

  const invalidTime = await app.inject({
    method: "POST",
    url: "/api/v1/logs",
    headers: { authorization: `Bearer ${owner.token}` },
    payload: { ...payload, idempotencyKey: crypto.randomUUID(), endedAt: "2026-01-01T09:00:00.000Z" },
  });
  assert.equal(invalidTime.statusCode, 400);

  const duplicateCategories = await app.inject({
    method: "POST",
    url: "/api/v1/logs",
    headers: { authorization: `Bearer ${owner.token}` },
    payload: { ...payload, idempotencyKey: crypto.randomUUID(), categoryIds: [categoryID, categoryID] },
  });
  assert.equal(duplicateCategories.statusCode, 400);

  const storedLogs = await database.db
    .selectFrom("logs")
    .selectAll()
    .where("user_id", "=", owner.id)
    .execute();
  assert.equal(storedLogs.length, 2);
  assert.equal(storedLogs[0]?.duration_seconds, 1500);
  const links = await database.db
    .selectFrom("log_categories")
    .innerJoin("logs", "logs.id", "log_categories.log_id")
    .select("log_categories.category_id")
    .where("logs.user_id", "=", owner.id)
    .execute();
  assert.equal(links.length, 2);
});

async function createAccount(app: ReturnType<typeof buildApp>, suffix: string) {
  const username = `${suffix}_${crypto.randomUUID().slice(0, 8)}`;
  const password = "correct horse battery staple";
  const response = await app.inject({
    method: "POST",
    url: "/api/v1/auth/register",
    payload: {
      username,
      displayName: suffix,
      email: `${username}@example.test`,
      password,
    },
  });
  assert.equal(response.statusCode, 201);

  const login = await app.inject({
    method: "POST",
    url: "/api/v1/auth/login",
    payload: { username, password },
  });
  assert.equal(login.statusCode, 200);

  return { id: response.json().user.id as string, token: login.json().accessToken as string };
}
