import assert from "node:assert/strict";
import test from "node:test";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { createDatabase } from "../src/db/client.js";

const config = loadConfig({
  NODE_ENV: "test",
  DATABASE_URL: "postgres://tracker:tracker@localhost:55432/tracker",
  REDIS_URL: "redis://localhost:6380",
  JWT_SECRET: "a-secret-key-that-is-at-least-32-characters-long",
});

test("profiles and categories are scoped to the authenticated user", async (t) => {
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

  const userA = await createAccount(app, "profile_a");
  const userB = await createAccount(app, "profile_b");
  registeredUsers.push(userA.id, userB.id);

  const profile = await app.inject({
    method: "GET",
    url: "/api/v1/me",
    headers: { authorization: `Bearer ${userA.token}` },
  });
  assert.equal(profile.statusCode, 200);
  assert.equal(profile.json().user.id, userA.id);
  assert.equal("password_hash" in profile.json().user, false);

  const updated = await app.inject({
    method: "PATCH",
    url: "/api/v1/me",
    headers: { authorization: `Bearer ${userA.token}` },
    payload: { displayName: "Updated Display", avatarUrl: null },
  });
  assert.equal(updated.statusCode, 200);
  assert.equal(updated.json().user.displayName, "Updated Display");
  assert.equal(updated.json().user.avatarUrl, null);

  const category = await app.inject({
    method: "POST",
    url: "/api/v1/categories",
    headers: { authorization: `Bearer ${userA.token}` },
    payload: { name: "Focus", colorHex: "#AABBCC" },
  });
  assert.equal(category.statusCode, 201);
  assert.equal(category.json().category.name, "Focus");

  const duplicate = await app.inject({
    method: "POST",
    url: "/api/v1/categories",
    headers: { authorization: `Bearer ${userA.token}` },
    payload: { name: "Focus" },
  });
  assert.equal(duplicate.statusCode, 409);

  const categoriesA = await app.inject({
    method: "GET",
    url: "/api/v1/categories",
    headers: { authorization: `Bearer ${userA.token}` },
  });
  assert.deepEqual(categoriesA.json().categories.map((item: { name: string }) => item.name), ["Focus"]);

  const categoriesB = await app.inject({
    method: "GET",
    url: "/api/v1/categories",
    headers: { authorization: `Bearer ${userB.token}` },
  });
  assert.deepEqual(categoriesB.json().categories, []);
});

test("changing email requires the current password and a free address", async (t) => {
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

  const userA = await createAccount(app, "email_a");
  const userB = await createAccount(app, "email_b");
  registeredUsers.push(userA.id, userB.id);
  const headers = { authorization: `Bearer ${userA.token}` };
  const newEmail = `email_${crypto.randomUUID().slice(0, 8)}@example.test`;

  const wrongPassword = await app.inject({
    method: "PATCH",
    url: "/api/v1/me/email",
    headers,
    payload: { email: newEmail, currentPassword: "not the password" },
  });
  assert.equal(wrongPassword.statusCode, 403);
  assert.equal(wrongPassword.json().error.code, "INCORRECT_PASSWORD");

  const invalid = await app.inject({
    method: "PATCH",
    url: "/api/v1/me/email",
    headers,
    payload: { email: "not-an-email", currentPassword: "correct horse battery staple" },
  });
  assert.equal(invalid.statusCode, 400);

  const taken = await app.inject({
    method: "PATCH",
    url: "/api/v1/me/email",
    headers,
    payload: { email: userB.email.toUpperCase(), currentPassword: "correct horse battery staple" },
  });
  assert.equal(taken.statusCode, 409);
  assert.equal(taken.json().error.code, "EMAIL_CONFLICT");

  const unchanged = await app.inject({ method: "GET", url: "/api/v1/me", headers });
  assert.equal(unchanged.json().user.email, userA.email);

  const changed = await app.inject({
    method: "PATCH",
    url: "/api/v1/me/email",
    headers,
    payload: { email: newEmail.toUpperCase(), currentPassword: "correct horse battery staple" },
  });
  assert.equal(changed.statusCode, 200);
  assert.equal(changed.json().user.email, newEmail);
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

  return {
    id: response.json().user.id as string,
    email: response.json().user.email as string,
    token: login.json().accessToken as string,
  };
}
