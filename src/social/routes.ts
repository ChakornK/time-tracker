import type { FastifyPluginAsync, FastifyReply } from "fastify";
import type { Database } from "../db/client.js";
import { authenticate, authenticatedUserId, invalidRequest } from "../http.js";
import { InteractionService } from "./interactions.js";
import {
  commentBodySchema,
  feedQuerySchema,
  followUserSchema,
  idParamsSchema,
  privacySchema,
  userParamsSchema,
} from "./schemas.js";
import { decodeCursor, SocialService } from "./service.js";

export interface SocialRouteOptions {
  db: Database;
}

export const socialRoutes: FastifyPluginAsync<SocialRouteOptions> = async (app, { db }) => {
  const social = new SocialService(db);
  const interactions = new InteractionService(db);

  app.addHook("preHandler", authenticate);

  app.post("/follows", async (request, reply) => {
    const input = followUserSchema.safeParse(request.body);
    if (!input.success) return invalidRequest(reply, input.error.issues);

    return { status: await social.follow(authenticatedUserId(request), input.data.userId) };
  });

  app.delete("/follows/:userId", async (request, reply) => {
    const target = followUserSchema.safeParse(request.params);
    if (!target.success) return invalidRequest(reply, target.error.issues);

    await social.unfollow(authenticatedUserId(request), target.data.userId);
    return reply.code(204).send();
  });

  app.get("/follows", async (request) => ({
    following: await social.listFollowing(authenticatedUserId(request)),
  }));

  app.get("/followers", async (request) => ({
    followers: await social.listFollowers(authenticatedUserId(request)),
  }));

  app.delete("/followers/:userId", async (request, reply) => {
    const params = userParamsSchema.safeParse(request.params);
    if (!params.success) return invalidRequest(reply, params.error.issues);

    await social.removeFollower(authenticatedUserId(request), params.data.userId);
    return reply.code(204).send();
  });

  app.get("/follow-requests", async (request) => ({
    requests: await social.listFollowRequests(authenticatedUserId(request)),
  }));

  app.post("/follow-requests/:userId/accept", async (request, reply) => {
    const params = userParamsSchema.safeParse(request.params);
    if (!params.success) return invalidRequest(reply, params.error.issues);

    await social.acceptFollowRequest(authenticatedUserId(request), params.data.userId);
    return reply.code(204).send();
  });

  app.delete("/follow-requests/:userId", async (request, reply) => {
    const params = userParamsSchema.safeParse(request.params);
    if (!params.success) return invalidRequest(reply, params.error.issues);

    await social.declineFollowRequest(authenticatedUserId(request), params.data.userId);
    return reply.code(204).send();
  });

  app.get("/me/social", async (request) => social.getSocialSummary(authenticatedUserId(request)));

  app.put("/me/privacy", async (request, reply) => {
    const input = privacySchema.safeParse(request.body);
    if (!input.success) return invalidRequest(reply, input.error.issues);

    return social.setPrivacy(authenticatedUserId(request), input.data.isPrivate);
  });

  app.get("/users/:userId", async (request, reply) => {
    const params = userParamsSchema.safeParse(request.params);
    if (!params.success) return invalidRequest(reply, params.error.issues);

    return { user: await social.getUserProfile(authenticatedUserId(request), params.data.userId) };
  });

  app.get("/users/:userId/logs", async (request, reply) => {
    const params = userParamsSchema.safeParse(request.params);
    if (!params.success) return invalidRequest(reply, params.error.issues);
    const query = feedQuerySchema.safeParse(request.query);
    if (!query.success) return invalidRequest(reply, query.error.issues);
    if (query.data.cursor && !isValidCursor(query.data.cursor)) return invalidCursor(reply);

    return social.getUserLogs(authenticatedUserId(request), params.data.userId, query.data);
  });

  app.post("/logs/:id/kudos", async (request, reply) => {
    const params = idParamsSchema.safeParse(request.params);
    if (!params.success) return invalidRequest(reply, params.error.issues);

    return interactions.giveKudos(authenticatedUserId(request), params.data.id);
  });

  app.delete("/logs/:id/kudos", async (request, reply) => {
    const params = idParamsSchema.safeParse(request.params);
    if (!params.success) return invalidRequest(reply, params.error.issues);

    return interactions.removeKudos(authenticatedUserId(request), params.data.id);
  });

  app.get("/logs/:id/comments", async (request, reply) => {
    const params = idParamsSchema.safeParse(request.params);
    if (!params.success) return invalidRequest(reply, params.error.issues);
    const query = feedQuerySchema.safeParse(request.query);
    if (!query.success) return invalidRequest(reply, query.error.issues);
    if (query.data.cursor && !isValidCursor(query.data.cursor)) return invalidCursor(reply);

    return interactions.listComments(authenticatedUserId(request), params.data.id, {
      cursor: query.data.cursor ? decodeCursor(query.data.cursor) : undefined,
      limit: query.data.limit,
    });
  });

  app.post("/logs/:id/comments", async (request, reply) => {
    const params = idParamsSchema.safeParse(request.params);
    if (!params.success) return invalidRequest(reply, params.error.issues);
    const input = commentBodySchema.safeParse(request.body);
    if (!input.success) return invalidRequest(reply, input.error.issues);

    const comment = await interactions.addComment(authenticatedUserId(request), params.data.id, input.data.body);
    return reply.code(201).send({ comment });
  });

  app.delete("/comments/:id", async (request, reply) => {
    const params = idParamsSchema.safeParse(request.params);
    if (!params.success) return invalidRequest(reply, params.error.issues);

    await interactions.deleteComment(authenticatedUserId(request), params.data.id);
    return reply.code(204).send();
  });

  app.get<{ Querystring: { username?: string } }>("/users/search", async (request, reply) => {
    const username = typeof request.query.username === "string" ? request.query.username.trim() : "";
    if (username.length < 3 || username.length > 50) {
      return reply.code(400).send({ error: { code: "INVALID_SEARCH", message: "Enter at least three username characters" } });
    }
    return { users: await social.searchUsers(authenticatedUserId(request), username) };
  });

  app.get("/feed", async (request, reply) => {
    const query = feedQuerySchema.safeParse(request.query);
    if (!query.success) return invalidRequest(reply, query.error.issues);
    if (query.data.cursor && !isValidCursor(query.data.cursor)) return invalidCursor(reply);

    return social.getFeedPage(authenticatedUserId(request), query.data);
  });
};

function isValidCursor(cursor: string): boolean {
  try {
    decodeCursor(cursor);
    return true;
  } catch {
    return false;
  }
}

function invalidCursor(reply: FastifyReply) {
  return reply.code(400).send({ error: { code: "INVALID_CURSOR", message: "Invalid cursor" } });
}
