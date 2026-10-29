import type { FastifyPluginAsync } from "fastify";
import type { Database } from "../db/client.js";
import { authenticate, authenticatedUserId, invalidRequest } from "../http.js";
import { createLogSchema } from "./schemas.js";
import { LogService } from "./service.js";

export interface LogRouteOptions {
  db: Database;
}

export const logRoutes: FastifyPluginAsync<LogRouteOptions> = async (app, { db }) => {
  const logs = new LogService(db);

  app.addHook("preHandler", authenticate);

  app.post("/logs", async (request, reply) => {
    const input = createLogSchema.safeParse(request.body);
    if (!input.success) return invalidRequest(reply, input.error.issues);

    const receipt = await logs.create(authenticatedUserId(request), input.data);
    return reply.code(receipt.created ? 201 : 200).send(receipt);
  });
};
