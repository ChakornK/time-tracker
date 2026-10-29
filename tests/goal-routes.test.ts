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

test("goals are scoped to the authenticated user and unique per category and period", async (t) => {
  const database = createDatabase(config);
  const app = buildApp({ config, db: database.db, logger: false });
  await app.ready();
  const registeredUsers: string[] = [];

  t.after(async () => {
    if (registeredUsers.length) {
      await database.db.deleteFrom("users").where("id", "in", registeredUsers).execute();
    }
    await app.close();
    await database.close();
  });

  const userA = await createAccount(app, "goal_a");
  const userB = await createAccount(app, "goal_b");
  registeredUsers.push(userA.id, userB.id);
  const authA = { authorization: `Bearer ${userA.token}` };
  const authB = { authorization: `Bearer ${userB.token}` };

  const category = await app.inject({ method: "POST", url: "/api/v1/categories", headers: authA, payload: { name: "Reading" } });
  const categoryId = category.json().category.id as string;

  const created = await app.inject({
    method: "POST",
    url: "/api/v1/goals",
    headers: authA,
    payload: { categoryId, period: "week", targetSeconds: 18_000 },
  });
  assert.equal(created.statusCode, 201);
  const goal = created.json().goal;
  assert.equal(goal.categoryId, categoryId);
  assert.equal(goal.period, "week");
  assert.equal(goal.targetSeconds, 18_000);

  const daily = await app.inject({
    method: "POST",
    url: "/api/v1/goals",
    headers: authA,
    payload: { categoryId, period: "day", targetSeconds: 3_600 },
  });
  assert.equal(daily.statusCode, 201);

  const duplicate = await app.inject({
    method: "POST",
    url: "/api/v1/goals",
    headers: authA,
    payload: { categoryId, period: "week", targetSeconds: 7_200 },
  });
  assert.equal(duplicate.statusCode, 409);
  assert.equal(duplicate.json().error.code, "GOAL_CONFLICT");

  const invalid = await app.inject({
    method: "POST",
    url: "/api/v1/goals",
    headers: authA,
    payload: { categoryId, period: "year", targetSeconds: 0 },
  });
  assert.equal(invalid.statusCode, 400);

  const foreignCategory = await app.inject({
    method: "POST",
    url: "/api/v1/goals",
    headers: authB,
    payload: { categoryId, period: "week", targetSeconds: 3_600 },
  });
  assert.equal(foreignCategory.statusCode, 404);

  const listA = await app.inject({ method: "GET", url: "/api/v1/goals", headers: authA });
  assert.deepEqual(listA.json().goals.map((item: { period: string }) => item.period), ["week", "day"]);
  const listB = await app.inject({ method: "GET", url: "/api/v1/goals", headers: authB });
  assert.deepEqual(listB.json().goals, []);

  const foreignUpdate = await app.inject({
    method: "PATCH",
    url: `/api/v1/goals/${goal.id}`,
    headers: authB,
    payload: { targetSeconds: 3_600 },
  });
  assert.equal(foreignUpdate.statusCode, 404);

  const updated = await app.inject({
    method: "PATCH",
    url: `/api/v1/goals/${goal.id}`,
    headers: authA,
    payload: { targetSeconds: 21_600 },
  });
  assert.equal(updated.statusCode, 200);
  assert.equal(updated.json().goal.targetSeconds, 21_600);

  const foreignDelete = await app.inject({ method: "DELETE", url: `/api/v1/goals/${goal.id}`, headers: authB });
  assert.equal(foreignDelete.statusCode, 404);

  const deleted = await app.inject({ method: "DELETE", url: `/api/v1/goals/${goal.id}`, headers: authA });
  assert.equal(deleted.statusCode, 204);
  const deletedAgain = await app.inject({ method: "DELETE", url: `/api/v1/goals/${goal.id}`, headers: authA });
  assert.equal(deletedAgain.statusCode, 404);

  await database.db.deleteFrom("categories").where("id", "=", categoryId).execute();
  const afterCategoryDelete = await app.inject({ method: "GET", url: "/api/v1/goals", headers: authA });
  assert.deepEqual(afterCategoryDelete.json().goals, []);
});

async function createAccount(app: ReturnType<typeof buildApp>, suffix: string) {
  const username = `${suffix}_${crypto.randomUUID().slice(0, 8)}`;
  const response = await app.inject({
    method: "POST",
    url: "/api/v1/auth/register",
    payload: {
      username,
      displayName: suffix,
      email: `${username}@example.test`,
      password: "correct horse battery staple",
    },
  });
  assert.equal(response.statusCode, 201);

  const login = await app.inject({
    method: "POST",
    url: "/api/v1/auth/login",
    payload: { username, password: "correct horse battery staple" },
  });
  assert.equal(login.statusCode, 200);

  return { id: response.json().user.id as string, token: login.json().accessToken as string };
}
