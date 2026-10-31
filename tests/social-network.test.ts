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

type App = ReturnType<typeof buildApp>;

function setUp(t: test.TestContext) {
  const database = createDatabase(config);
  const app = buildApp({ config, db: database.db, logger: false });
  const userIDs: string[] = [];
  t.after(async () => {
    if (userIDs.length) await database.db.deleteFrom("users").where("id", "in", userIDs).execute();
    await app.close();
    await database.close();
  });
  return {
    app,
    async account(suffix: string) {
      const account = await createAccount(app, suffix);
      userIDs.push(account.id);
      return account;
    },
  };
}

test("private accounts approve followers through requests", async (t) => {
  const { app, account } = setUp(t);
  await app.ready();
  const owner = await account("net_owner");
  const asker = await account("net_asker");
  const other = await account("net_other");

  const privacy = await call(app, owner.token, "PUT", "/me/privacy", { isPrivate: true });
  assert.equal(privacy.statusCode, 200, privacy.body);
  assert.equal(privacy.json().isPrivate, true);
  const ownerLog = await createLog(app, owner.token, "owner-public", "public");

  const search = await call(app, asker.token, "GET", `/users/search?username=${owner.username}`);
  assert.deepEqual(
    search.json().users.find((user: { id: string }) => user.id === owner.id),
    { id: owner.id, username: owner.username, displayName: "net_owner", isPrivate: true, isFollowing: false, isRequested: false },
  );

  // A private account's logs and profile log list are closed to people who don't follow it.
  const closedLogs = await call(app, asker.token, "GET", `/users/${owner.id}/logs`);
  assert.equal(closedLogs.statusCode, 403);
  assert.equal(closedLogs.json().error.code, "PROFILE_PRIVATE");
  const closedKudos = await call(app, asker.token, "POST", `/logs/${ownerLog.id}/kudos`);
  assert.equal(closedKudos.statusCode, 404);

  const request = await call(app, asker.token, "POST", "/follows", { userId: owner.id });
  assert.deepEqual(request.json(), { status: "requested" });
  const requestedProfile = await call(app, asker.token, "GET", `/users/${owner.id}`);
  assert.deepEqual(requestedProfile.json().user.relationship, { isFollowing: false, isRequested: true, followsYou: false });
  assert.equal(requestedProfile.json().user.canViewLogs, false);

  const summary = await call(app, owner.token, "GET", "/me/social");
  assert.deepEqual(summary.json(), { isPrivate: true, followerCount: 0, followingCount: 0, pendingRequestCount: 1 });
  const requests = await call(app, owner.token, "GET", "/follow-requests");
  assert.deepEqual(Object.keys(requests.json().requests[0]).sort(), ["avatarUrl", "displayName", "id", "requestedAt", "username"]);
  assert.equal(requests.json().requests[0].id, asker.id);

  // Withdrawing the request removes it from the owner's list.
  const withdraw = await call(app, asker.token, "DELETE", `/follows/${owner.id}`);
  assert.equal(withdraw.statusCode, 204);
  assert.deepEqual((await call(app, owner.token, "GET", "/follow-requests")).json().requests, []);

  await call(app, asker.token, "POST", "/follows", { userId: owner.id });
  const accept = await call(app, owner.token, "POST", `/follow-requests/${asker.id}/accept`);
  assert.equal(accept.statusCode, 204);
  // Answering a request that's already gone is a no-op rather than an error.
  const acceptAgain = await call(app, owner.token, "POST", `/follow-requests/${asker.id}/accept`);
  assert.equal(acceptAgain.statusCode, 204);

  const openLogs = await call(app, asker.token, "GET", `/users/${owner.id}/logs`);
  assert.deepEqual(openLogs.json().items.map((item: { id: string }) => item.id), [ownerLog.id]);
  const feed = await call(app, asker.token, "GET", "/feed");
  assert.ok(feed.json().items.some((item: { id: string }) => item.id === ownerLog.id));

  // Declining leaves no follow behind.
  await call(app, other.token, "POST", "/follows", { userId: owner.id });
  const decline = await call(app, owner.token, "DELETE", `/follow-requests/${other.id}`);
  assert.equal(decline.statusCode, 204);
  assert.equal((await call(app, other.token, "GET", `/users/${owner.id}`)).json().user.relationship.isRequested, false);

  // Going public accepts whatever is still pending.
  await call(app, other.token, "POST", "/follows", { userId: owner.id });
  const goPublic = await call(app, owner.token, "PUT", "/me/privacy", { isPrivate: false });
  assert.deepEqual(goPublic.json(), { isPrivate: false, followerCount: 2, followingCount: 0, pendingRequestCount: 0 });

  const followers = await call(app, owner.token, "GET", "/followers");
  assert.deepEqual(
    followers.json().followers.map((user: { id: string }) => user.id).sort(),
    [asker.id, other.id].sort(),
  );

  // A removed follower of a private account loses the owner's logs everywhere, but can still take
  // back their own comment.
  const comment = await call(app, asker.token, "POST", `/logs/${ownerLog.id}/comments`, { body: "Hi" });
  assert.equal(comment.statusCode, 201);
  await call(app, owner.token, "PUT", "/me/privacy", { isPrivate: true });
  const remove = await call(app, owner.token, "DELETE", `/followers/${asker.id}`);
  assert.equal(remove.statusCode, 204);
  const feedAfter = await call(app, asker.token, "GET", "/feed");
  assert.ok(!feedAfter.json().items.some((item: { id: string }) => item.id === ownerLog.id));
  assert.equal((await call(app, asker.token, "POST", `/logs/${ownerLog.id}/comments`, { body: "Again" })).statusCode, 404);
  assert.equal((await call(app, asker.token, "POST", `/logs/${ownerLog.id}/kudos`)).statusCode, 404);
  assert.equal((await call(app, asker.token, "DELETE", `/comments/${comment.json().comment.id}`)).statusCode, 204);
});

test("a private account's friends-only logs reach the people it follows", async (t) => {
  const { app, account } = setUp(t);
  await app.ready();
  const owner = await account("fo_owner");
  const friend = await account("fo_friend");

  await call(app, owner.token, "PUT", "/me/privacy", { isPrivate: true });
  const friendsLog = await createLog(app, owner.token, "friends", "friends_only");
  await createLog(app, owner.token, "public", "public");
  await call(app, owner.token, "POST", "/follows", { userId: friend.id });

  const profile = await call(app, friend.token, "GET", `/users/${owner.id}`);
  assert.equal(profile.json().user.canViewLogs, true);
  // Only the friends-only log: the public one still needs an accepted follow.
  const logs = await call(app, friend.token, "GET", `/users/${owner.id}/logs`);
  assert.deepEqual(logs.json().items.map((item: { id: string }) => item.id), [friendsLog.id]);
});

test("profiles show a public account's public logs to anyone", async (t) => {
  const { app, account } = setUp(t);
  await app.ready();
  const author = await account("prof_author");
  const stranger = await account("prof_stranger");
  const friend = await account("prof_friend");

  const publicLog = await createLog(app, author.token, "public", "public");
  const friendsLog = await createLog(app, author.token, "friends", "friends_only");
  await createLog(app, author.token, "private", "private");
  await call(app, author.token, "POST", "/follows", { userId: friend.id });

  const strangerLogs = await call(app, stranger.token, "GET", `/users/${author.id}/logs`);
  assert.deepEqual(strangerLogs.json().items.map((item: { id: string }) => item.id), [publicLog.id]);
  // The feed still only shows people the viewer follows.
  const strangerFeed = await call(app, stranger.token, "GET", "/feed");
  assert.ok(!strangerFeed.json().items.some((item: { id: string }) => item.id === publicLog.id));

  const friendLogs = await call(app, friend.token, "GET", `/users/${author.id}/logs`);
  assert.deepEqual(friendLogs.json().items.map((item: { id: string }) => item.id), [friendsLog.id, publicLog.id]);

  const profile = await call(app, friend.token, "GET", `/users/${author.id}`);
  assert.deepEqual(profile.json().user, {
    id: author.id,
    username: author.username,
    displayName: "prof_author",
    avatarUrl: null,
    isPrivate: false,
    followerCount: 0,
    followingCount: 1,
    relationship: { isFollowing: false, isRequested: false, followsYou: true },
    canViewLogs: true,
  });

  const missing = await call(app, friend.token, "GET", `/users/${crypto.randomUUID()}`);
  assert.equal(missing.statusCode, 404);
});

test("kudos and comments follow log visibility", async (t) => {
  const { app, account } = setUp(t);
  await app.ready();
  const author = await account("int_author");
  const fan = await account("int_fan");
  const stranger = await account("int_stranger");

  const publicLog = await createLog(app, author.token, "public", "public");
  const privateLog = await createLog(app, author.token, "private", "private");

  const selfKudos = await call(app, author.token, "POST", `/logs/${publicLog.id}/kudos`);
  assert.equal(selfKudos.statusCode, 400);
  const hiddenKudos = await call(app, fan.token, "POST", `/logs/${privateLog.id}/kudos`);
  assert.equal(hiddenKudos.statusCode, 404);

  const kudos = await call(app, fan.token, "POST", `/logs/${publicLog.id}/kudos`);
  assert.deepEqual(kudos.json(), { kudosCount: 1, viewerGaveKudos: true });
  const kudosAgain = await call(app, fan.token, "POST", `/logs/${publicLog.id}/kudos`);
  assert.deepEqual(kudosAgain.json(), { kudosCount: 1, viewerGaveKudos: true });
  await call(app, stranger.token, "POST", `/logs/${publicLog.id}/kudos`);

  const blank = await call(app, fan.token, "POST", `/logs/${publicLog.id}/comments`, { body: "   " });
  assert.equal(blank.statusCode, 400);
  const first = await call(app, fan.token, "POST", `/logs/${publicLog.id}/comments`, { body: " Nice work " });
  assert.equal(first.statusCode, 201, first.body);
  assert.equal(first.json().comment.body, "Nice work");
  assert.equal(first.json().comment.canDelete, true);
  const second = await call(app, stranger.token, "POST", `/logs/${publicLog.id}/comments`, { body: "Second" });
  const third = await call(app, author.token, "POST", `/logs/${publicLog.id}/comments`, { body: "Thanks" });

  const page = await call(app, fan.token, "GET", `/logs/${publicLog.id}/comments?limit=2`);
  assert.deepEqual(page.json().comments.map((comment: { body: string }) => comment.body), ["Nice work", "Second"]);
  assert.deepEqual(page.json().comments.map((comment: { canDelete: boolean }) => comment.canDelete), [true, false]);
  const rest = await call(app, fan.token, "GET", `/logs/${publicLog.id}/comments?limit=2&cursor=${page.json().nextCursor}`);
  assert.deepEqual(rest.json().comments.map((comment: { body: string }) => comment.body), ["Thanks"]);
  assert.equal(rest.json().nextCursor, null);

  // Only the commenter or the log's author may delete a comment.
  const forbidden = await call(app, fan.token, "DELETE", `/comments/${second.json().comment.id}`);
  assert.equal(forbidden.statusCode, 403);
  const byAuthor = await call(app, author.token, "DELETE", `/comments/${second.json().comment.id}`);
  assert.equal(byAuthor.statusCode, 204);
  const byCommenter = await call(app, fan.token, "DELETE", `/comments/${first.json().comment.id}`);
  assert.equal(byCommenter.statusCode, 204);
  assert.ok(third.json().comment.id);

  // The author sees the counts on their own feed entry.
  const feed = await call(app, author.token, "GET", "/feed");
  const entry = feed.json().items.find((item: { id: string }) => item.id === publicLog.id);
  assert.equal(entry.kudosCount, 2);
  assert.equal(entry.viewerGaveKudos, false);
  assert.equal(entry.commentCount, 1);

  const removed = await call(app, fan.token, "DELETE", `/logs/${publicLog.id}/kudos`);
  assert.deepEqual(removed.json(), { kudosCount: 1, viewerGaveKudos: false });

  const missingLog = await call(app, fan.token, "POST", `/logs/${crypto.randomUUID()}/comments`, { body: "Hi" });
  assert.equal(missingLog.statusCode, 404);
  const badCursor = await call(app, fan.token, "GET", `/logs/${publicLog.id}/comments?cursor=nope`);
  assert.equal(badCursor.statusCode, 400);

  // Going private takes the log out of a stranger's reach, comments included.
  await call(app, author.token, "PUT", "/me/privacy", { isPrivate: true });
  const closedComments = await call(app, stranger.token, "GET", `/logs/${publicLog.id}/comments`);
  assert.equal(closedComments.statusCode, 404);
});

async function call(app: App, token: string, method: "GET" | "POST" | "PUT" | "DELETE", path: string, payload?: object) {
  return app.inject({
    method,
    url: `/api/v1${path}`,
    headers: { authorization: `Bearer ${token}` },
    ...(payload && { payload }),
  });
}

async function createLog(app: App, token: string, title: string, visibility: string) {
  const response = await call(app, token, "POST", "/logs", {
    idempotencyKey: crypto.randomUUID(),
    title,
    startedAt: "2026-02-01T10:00:00.000Z",
    endedAt: "2026-02-01T10:20:00.000Z",
    categoryIds: [],
    visibility,
  });
  assert.equal(response.statusCode, 201);
  return response.json() as { id: string };
}

async function createAccount(app: App, suffix: string) {
  const username = `${suffix}_${crypto.randomUUID().slice(0, 8)}`;
  const password = "correct horse battery staple";
  const response = await app.inject({
    method: "POST",
    url: "/api/v1/auth/register",
    payload: { username, displayName: suffix, email: `${username}@example.test`, password },
  });
  assert.equal(response.statusCode, 201);
  const login = await app.inject({ method: "POST", url: "/api/v1/auth/login", payload: { username, password } });
  assert.equal(login.statusCode, 200);
  return { id: response.json().user.id as string, username, token: login.json().accessToken as string };
}
