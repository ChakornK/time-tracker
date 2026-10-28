import Fastify, { type FastifyInstance } from "fastify";
import jwtPlugin from "@fastify/jwt";
import type { AppConfig } from "./config.js";
import { createDatabase, type Database } from "./db/client.js";
import { createRedisClient, type RedisClient } from "./cache/redis.js";
import { DomainError } from "./errors.js";
import { authRoutes } from "./auth/routes.js";
import { profileRoutes } from "./profile/routes.js";
import { goalRoutes } from "./goals/routes.js";
import { logRoutes } from "./logs/routes.js";
import { socialRoutes } from "./social/routes.js";

export interface AppDependencies {
  logger?: boolean;
  config?: AppConfig;
  db?: Database;
  redis?: RedisClient;
}

export function buildApp({ logger = true, config, db, redis }: AppDependencies = {}): FastifyInstance {
  const app = Fastify({ logger });

  app.get("/health", async () => ({ status: "ok" }));

  if (config && db) {
    app.register(jwtPlugin, {
      secret: config.JWT_SECRET,
      sign: { expiresIn: config.JWT_EXPIRES_IN },
    });
    app.register(async (api) => {
      api.setErrorHandler((error, _request, reply) => {
        if (error instanceof DomainError) {
          return reply.code(error.statusCode).send({ error: { code: error.code, message: error.message } });
        }
        // Rethrowing defers to Fastify's default handler, which owns 401s from jwtVerify and 500s.
        throw error;
      });

      const feedCacheMaxAgeSeconds = config.FEED_CACHE_MAX_AGE_SECONDS;
      await api.register(authRoutes, { prefix: "/auth", config, db });
      await api.register(profileRoutes, { db });
      await api.register(goalRoutes, { db });
      await api.register(logRoutes, { db, redis, feedCacheMaxAgeSeconds });
      await api.register(socialRoutes, { db, redis, feedCacheMaxAgeSeconds });
    }, { prefix: "/api/v1" });
  }

  return app;
}

export async function buildConfiguredApp(config: AppConfig): Promise<FastifyInstance> {
  const database = createDatabase(config);
  const redis = await createRedisClient(config);
  const app = buildApp({ config, db: database.db, redis });

  app.addHook("onClose", async () => {
    await Promise.all([database.close(), redis.quit()]);
  });

  return app;
}
