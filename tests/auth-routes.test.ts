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

test("authentication endpoints", async (t) => {
  const database = createDatabase(config);
  const app = buildApp({ config, db: database.db, logger: false });
  await app.ready();

  t.after(async () => {
    await app.close();
    await database.close();
  });

  await t.test("registers, logs in, and protects the identity endpoint", async () => {
    const username = `user_${crypto.randomUUID().slice(0, 8)}`;
    const email = `${username}@example.test`;
    const password = "p";

    const registration = await app.inject({
      method: "POST",
      url: "/api/v1/auth/register",
      payload: { username, displayName: "Test User", email, password },
    });

    assert.equal(registration.statusCode, 201);
    const user = registration.json().user;
    assert.equal(user.username, username);
    assert.equal(user.email, email);
    assert.equal("passwordHash" in user, false);
    assert.equal("password_hash" in user, false);

    const login = await app.inject({
      method: "POST",
      url: "/api/v1/auth/login",
      payload: { username, password },
    });
    assert.equal(login.statusCode, 200);
    const accessToken = login.json().accessToken as string;
    assert.ok(accessToken);
    assert.equal(login.json().tokenType, "Bearer");
    assert.equal(login.json().expiresInSeconds, 900);

    const protectedResponse = await app.inject({
      method: "GET",
      url: "/api/v1/me",
      headers: { authorization: `Bearer ${accessToken}` },
    });
    assert.equal(protectedResponse.statusCode, 200);
    assert.equal(protectedResponse.json().user.id, user.id);

    const unauthorizedResponse = await app.inject({
      method: "GET",
      url: "/api/v1/me",
    });
    assert.equal(unauthorizedResponse.statusCode, 401);
  });

  await t.test("returns structured input errors and account conflicts", async () => {
    const invalid = await app.inject({
      method: "POST",
      url: "/api/v1/auth/register",
      payload: { username: "x", password: "" },
    });
    assert.equal(invalid.statusCode, 400);
    assert.equal(invalid.json().error.code, "INVALID_REQUEST");

    const username = `dupe_${crypto.randomUUID().slice(0, 8)}`;
    const payload = {
      username,
      displayName: "Duplicate User",
      email: `${username}@example.test`,
      password: "correct horse battery staple",
    };

    const first = await app.inject({ method: "POST", url: "/api/v1/auth/register", payload });
    assert.equal(first.statusCode, 201);
    const duplicate = await app.inject({ method: "POST", url: "/api/v1/auth/register", payload });
    assert.equal(duplicate.statusCode, 409);

    const badLogin = await app.inject({
      method: "POST",
      url: "/api/v1/auth/login",
      payload: { username, password: "wrong password" },
    });
    assert.equal(badLogin.statusCode, 401);
    assert.equal(badLogin.json().error.code, "INVALID_CREDENTIALS");
  });
});
