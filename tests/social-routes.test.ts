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

test("follow rules filter feed visibility and paginate without duplicates", async (t) => {
  const database = createDatabase(config);
  const app = buildApp({ config, db: database.db, logger: false });
  await app.ready();
  const userIDs: string[] = [];

  t.after(async () => {
    if (userIDs.length) await database.db.deleteFrom("users").where("id", "in", userIDs).execute();
    await app.close();
    await database.close();
  });

  const viewer = await createAccount(app, "social_viewer");
  const author = await createAccount(app, "social_author");
  const unrelated = await createAccount(app, "social_unrelated");
  userIDs.push(viewer.id, author.id, unrelated.id);

  const search = await app.inject({
    method: "GET",
    url: `/api/v1/users/search?username=${encodeURIComponent(author.username.slice(0, 8))}`,
    headers: { authorization: `Bearer ${viewer.token}` },
  });
  assert.equal(search.statusCode, 200, search.body);
  assert.ok(search.json().users.some((user: { id: string; isFollowing: boolean }) => user.id === author.id && !user.isFollowing));
  assert.ok(!search.json().users.some((user: { id: string }) => user.id === viewer.id));

  const tooShortSearch = await app.inject({
    method: "GET",
    url: "/api/v1/users/search?username=ab",
    headers: { authorization: `Bearer ${viewer.token}` },
  });
  assert.equal(tooShortSearch.statusCode, 400);

  const selfFollow = await app.inject({
    method: "POST",
    url: "/api/v1/follows",
    headers: { authorization: `Bearer ${viewer.token}` },
    payload: { userId: viewer.id },
  });
  assert.equal(selfFollow.statusCode, 400);

  const follow = await app.inject({
    method: "POST",
    url: "/api/v1/follows",
    headers: { authorization: `Bearer ${viewer.token}` },
    payload: { userId: author.id },
  });
  assert.equal(follow.statusCode, 204);

  const followedSearch = await app.inject({
    method: "GET",
    url: `/api/v1/users/search?username=${encodeURIComponent(author.username)}`,
    headers: { authorization: `Bearer ${viewer.token}` },
  });
  assert.equal(followedSearch.json().users.find((user: { id: string }) => user.id === author.id).isFollowing, true);

  const following = await app.inject({
    method: "GET",
    url: "/api/v1/follows",
    headers: { authorization: `Bearer ${viewer.token}` },
  });
  assert.deepEqual(following.json().following.map((user: { id: string }) => user.id), [author.id]);
  // The app decodes these keys as they are, so they must be camelCase.
  assert.deepEqual(Object.keys(following.json().following[0]).sort(), ["avatarUrl", "displayName", "followedAt", "id", "username"]);

  const privateSelf = await createLog(app, author.token, "private-self", "private");
  const publicLog = await createLog(app, author.token, "public-followed", "public");
  const friendsLog = await createLog(app, author.token, "friends-by-author-follow", "friends_only");
  const hiddenPrivate = await createLog(app, author.token, "private-hidden", "private");
  const unrelatedLog = await createLog(app, unrelated.token, "unrelated-public", "public");

  const followBack = await app.inject({
    method: "POST",
    url: "/api/v1/follows",
    headers: { authorization: `Bearer ${author.token}` },
    payload: { userId: viewer.id },
  });
  assert.equal(followBack.statusCode, 204);

  const viewerFeed = await app.inject({
    method: "GET",
    url: "/api/v1/feed?limit=2",
    headers: { authorization: `Bearer ${viewer.token}` },
  });
  assert.equal(viewerFeed.statusCode, 200);
  assert.equal(viewerFeed.json().items.length, 2);
  assert.equal(viewerFeed.json().items[0].title, "friends-by-author-follow");
  assert.equal(viewerFeed.json().nextCursor, null);

  const visibleIDs = viewerFeed.json().items.map((item: { id: string }) => item.id);
  assert.ok(visibleIDs.includes(publicLog.id));
  assert.ok(visibleIDs.includes(friendsLog.id));
  assert.ok(!visibleIDs.includes(privateSelf.id));
  assert.ok(!visibleIDs.includes(hiddenPrivate.id));
  assert.ok(!visibleIDs.includes(unrelatedLog.id));

  const authorFeed = await app.inject({
    method: "GET",
    url: "/api/v1/feed?limit=100",
    headers: { authorization: `Bearer ${author.token}` },
  });
  const authorIDs = authorFeed.json().items.map((item: { id: string }) => item.id);
  assert.ok(authorIDs.includes(privateSelf.id));
  assert.ok(authorIDs.includes(hiddenPrivate.id));

  const ownPublicLog = await createLog(app, viewer.token, "viewer-own-public", "public");
  const cursorSeed = await createLog(app, author.token, "cursor-seed", "public");
  const pageOne = await app.inject({
    method: "GET",
    url: "/api/v1/feed?limit=1",
    headers: { authorization: `Bearer ${viewer.token}` },
  });
  assert.equal(pageOne.statusCode, 200);
  assert.equal(pageOne.json().items.length, 1);
  assert.ok(pageOne.json().nextCursor);
  const pageTwo = await app.inject({
    method: "GET",
    url: `/api/v1/feed?limit=1&cursor=${encodeURIComponent(pageOne.json().nextCursor)}`,
    headers: { authorization: `Bearer ${viewer.token}` },
  });
  assert.equal(pageTwo.statusCode, 200, pageTwo.body);
  assert.equal(pageTwo.json().items.length, 1);
  assert.notEqual(pageOne.json().items[0].id, pageTwo.json().items[0].id);
  assert.ok([privateSelf.id, publicLog.id, friendsLog.id, cursorSeed.id, ownPublicLog.id].includes(pageOne.json().items[0].id));
  const viewerOwnFeed = await app.inject({
    method: "GET",
    url: "/api/v1/feed?limit=100",
    headers: { authorization: `Bearer ${viewer.token}` },
  });
  assert.ok(viewerOwnFeed.json().items.some((item: { id: string }) => item.id === ownPublicLog.id));

  const invalidCursor = await app.inject({
    method: "GET",
    url: "/api/v1/feed?cursor=not-a-cursor",
    headers: { authorization: `Bearer ${viewer.token}` },
  });
  assert.equal(invalidCursor.statusCode, 400);

  const unfollow = await app.inject({
    method: "DELETE",
    url: `/api/v1/follows/${author.id}`,
    headers: { authorization: `Bearer ${viewer.token}` },
  });
  assert.equal(unfollow.statusCode, 204);
  const refreshedFollowing = await app.inject({
    method: "GET",
    url: "/api/v1/follows",
    headers: { authorization: `Bearer ${viewer.token}` },
  });
  assert.deepEqual(refreshedFollowing.json().following, []);
});

async function createLog(app: ReturnType<typeof buildApp>, token: string, title: string, visibility: string) {
  const response = await app.inject({
    method: "POST",
    url: "/api/v1/logs",
    headers: { authorization: `Bearer ${token}` },
    payload: {
      idempotencyKey: crypto.randomUUID(),
      title,
      startedAt: "2026-02-01T10:00:00.000Z",
      endedAt: "2026-02-01T10:20:00.000Z",
      categoryIds: [],
      visibility,
    },
  });
  assert.equal(response.statusCode, 201);
  return response.json() as { id: string };
}

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
  return { id: response.json().user.id as string, username, token: login.json().accessToken as string };
}
