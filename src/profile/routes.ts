import type { FastifyPluginAsync } from "fastify";
import type { Database } from "../db/client.js";
import { authenticate, authenticatedUserId, invalidRequest } from "../http.js";
import {
  categoryParamsSchema,
  createCategorySchema,
  updateCategorySchema,
  updateEmailSchema,
  updateProfileSchema,
} from "./schemas.js";
import { ProfileService } from "./service.js";

export interface ProfileRouteOptions {
  db: Database;
}

export const profileRoutes: FastifyPluginAsync<ProfileRouteOptions> = async (app, { db }) => {
  const profiles = new ProfileService(db);

  app.addHook("preHandler", authenticate);

  app.get("/me", async (request) => ({
    user: await profiles.getProfile(authenticatedUserId(request)),
  }));

  app.patch("/me", async (request, reply) => {
    const input = updateProfileSchema.safeParse(request.body);
    if (!input.success) return invalidRequest(reply, input.error.issues);

    return { user: await profiles.updateProfile(authenticatedUserId(request), input.data) };
  });

  app.patch("/me/email", async (request, reply) => {
    const input = updateEmailSchema.safeParse(request.body);
    if (!input.success) return invalidRequest(reply, input.error.issues);

    return { user: await profiles.updateEmail(authenticatedUserId(request), input.data) };
  });

  app.get("/categories", async (request) => ({
    categories: await profiles.listCategories(authenticatedUserId(request)),
  }));

  app.post("/categories", async (request, reply) => {
    const input = createCategorySchema.safeParse(request.body);
    if (!input.success) return invalidRequest(reply, input.error.issues);

    const category = await profiles.createCategory(authenticatedUserId(request), input.data);
    return reply.code(201).send({ category });
  });

  app.patch("/categories/:id", async (request, reply) => {
    const params = categoryParamsSchema.safeParse(request.params);
    if (!params.success) return invalidRequest(reply, params.error.issues);
    const input = updateCategorySchema.safeParse(request.body);
    if (!input.success) return invalidRequest(reply, input.error.issues);

    return { category: await profiles.updateCategory(authenticatedUserId(request), params.data.id, input.data) };
  });

  app.delete("/categories/:id", async (request, reply) => {
    const params = categoryParamsSchema.safeParse(request.params);
    if (!params.success) return invalidRequest(reply, params.error.issues);

    await profiles.deleteCategory(authenticatedUserId(request), params.data.id);
    return reply.code(204).send();
  });
};
