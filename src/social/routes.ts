import type { FastifyPluginAsync } from "fastify";
import type { Database } from "../db/client.js";
import { authenticate, authenticatedUserId, invalidRequest } from "../http.js";
import { feedQuerySchema, followUserSchema } from "./schemas.js";
import { decodeCursor, SocialService } from "./service.js";

export interface SocialRouteOptions {
  db: Database;
}

export const socialRoutes: FastifyPluginAsync<SocialRouteOptions> = async (app, { db }) => {
  const social = new SocialService(db);

  app.addHook("preHandler", authenticate);

  app.post("/follows", async (request, reply) => {
    const input = followUserSchema.safeParse(request.body);
    if (!input.success) return invalidRequest(reply, input.error.issues);

    await social.follow(authenticatedUserId(request), input.data.userId);
    return reply.code(204).send();
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
    if (query.data.cursor) {
      try {
        decodeCursor(query.data.cursor);
      } catch {
        return reply.code(400).send({ error: { code: "INVALID_CURSOR", message: "Invalid feed cursor" } });
      }
    }

    return social.getFeedPage(authenticatedUserId(request), query.data);
  });
};
