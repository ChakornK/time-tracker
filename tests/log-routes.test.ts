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

test("owners can edit and delete their logs, and nobody else can", async (t) => {
  const database = createDatabase(config);
  const app = buildApp({ config, db: database.db, logger: false });
  await app.ready();
  const owner = await createAccount(app, "log_editor");
  const other = await createAccount(app, "log_intruder");

  t.after(async () => {
    await database.db.deleteFrom("users").where("id", "in", [owner.id, other.id]).execute();
    await app.close();
    await database.close();
  });

  const auth = (token: string) => ({ authorization: `Bearer ${token}` });
  const category = async (token: string, name: string) => {
    const response = await app.inject({ method: "POST", url: "/api/v1/categories", headers: auth(token), payload: { name } });
    assert.equal(response.statusCode, 201);
    return response.json().category.id as string;
  };
  const writing = await category(owner.token, "Writing");
  const reading = await category(owner.token, "Reading");
  const foreign = await category(other.token, "Not yours");

  const created = await app.inject({
    method: "POST",
    url: "/api/v1/logs",
    headers: auth(owner.token),
    payload: {
      idempotencyKey: crypto.randomUUID(),
      title: "Writing",
      startedAt: "2026-01-01T09:00:00.000Z",
      endedAt: "2026-01-01T17:00:00.000Z",
      categoryIds: [writing],
      visibility: "public",
    },
  });
  const logID = created.json().id as string;
  const patch = (token: string, payload: object, id = logID) =>
    app.inject({ method: "PATCH", url: `/api/v1/logs/${id}`, headers: auth(token), payload });

  // Left running too long: trim the end, switch category, and add notes.
  const edited = await patch(owner.token, {
    title: "Reading",
    endedAt: "2026-01-01T10:30:00.000Z",
    categoryIds: [reading],
    visibility: "private",
    notes: "Stopped late",
  });
  assert.equal(edited.statusCode, 204, edited.body);
  const stored = await database.db.selectFrom("logs").selectAll().where("id", "=", logID).executeTakeFirstOrThrow();
  assert.equal(stored.title, "Reading");
  assert.equal(stored.duration_seconds, 5400);
  assert.equal(stored.visibility, "private");
  assert.equal(stored.notes, "Stopped late");
  const links = await database.db.selectFrom("log_categories").select("category_id").where("log_id", "=", logID).execute();
  assert.deepEqual(links.map((link) => link.category_id), [reading]);

  // Times are checked against the stored log when only one of them changes.
  const backwards = await patch(owner.token, { startedAt: "2026-01-01T11:00:00.000Z" });
  assert.equal(backwards.statusCode, 400);
  assert.equal(backwards.json().error.code, "INVALID_LOG_TIMES");
  assert.equal((await patch(owner.token, {})).statusCode, 400);
  assert.equal((await patch(owner.token, { categoryIds: [foreign] })).json().error.code, "INVALID_CATEGORIES");
  assert.equal((await patch(owner.token, { notes: null })).statusCode, 204);

  // Another account sees the log as missing for both edit and delete.
  const intruderEdit = await patch(other.token, { title: "Mine now" });
  assert.equal(intruderEdit.statusCode, 404);
  assert.equal(intruderEdit.json().error.code, "LOG_NOT_FOUND");
  const intruderDelete = await app.inject({ method: "DELETE", url: `/api/v1/logs/${logID}`, headers: auth(other.token) });
  assert.equal(intruderDelete.statusCode, 404);

  const deleted = await app.inject({ method: "DELETE", url: `/api/v1/logs/${logID}`, headers: auth(owner.token) });
  assert.equal(deleted.statusCode, 204);
  assert.equal(await database.db.selectFrom("logs").select("id").where("id", "=", logID).executeTakeFirst(), undefined);
  assert.equal((await database.db.selectFrom("log_categories").select("log_id").where("log_id", "=", logID).execute()).length, 0);
  const again = await app.inject({ method: "DELETE", url: `/api/v1/logs/${logID}`, headers: auth(owner.token) });
  assert.equal(again.statusCode, 404);
  assert.equal((await patch(owner.token, { title: "Gone" }, "not-a-uuid")).statusCode, 400);
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
