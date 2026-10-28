import type { FastifyPluginAsync } from "fastify";
import type { Database } from "../db/client.js";
import { authenticate, authenticatedUserId, invalidRequest } from "../http.js";
import { createGoalSchema, goalParamsSchema, updateGoalSchema } from "./schemas.js";
import { GoalService } from "./service.js";

export interface GoalRouteOptions {
  db: Database;
}

export const goalRoutes: FastifyPluginAsync<GoalRouteOptions> = async (app, { db }) => {
  const goals = new GoalService(db);

  app.addHook("preHandler", authenticate);

  app.get("/goals", async (request) => ({
    goals: await goals.list(authenticatedUserId(request)),
  }));

  app.post("/goals", async (request, reply) => {
    const input = createGoalSchema.safeParse(request.body);
    if (!input.success) return invalidRequest(reply, input.error.issues);

    const goal = await goals.create(authenticatedUserId(request), input.data);
    return reply.code(201).send({ goal });
  });

  app.patch("/goals/:id", async (request, reply) => {
    const params = goalParamsSchema.safeParse(request.params);
    if (!params.success) return invalidRequest(reply, params.error.issues);
    const input = updateGoalSchema.safeParse(request.body);
    if (!input.success) return invalidRequest(reply, input.error.issues);

    return { goal: await goals.update(authenticatedUserId(request), params.data.id, input.data) };
  });

  app.delete("/goals/:id", async (request, reply) => {
    const params = goalParamsSchema.safeParse(request.params);
    if (!params.success) return invalidRequest(reply, params.error.issues);

    await goals.delete(authenticatedUserId(request), params.data.id);
    return reply.code(204).send();
  });
};
