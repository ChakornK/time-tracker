import { z } from "zod";

const environmentSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  HOST: z.string().default("0.0.0.0"),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  DATABASE_URL: z.string().url(),
  JWT_SECRET: z.string().min(32),
  JWT_EXPIRES_IN: z.string().default("15m"),
});

export type AppConfig = z.infer<typeof environmentSchema>;

export class ConfigurationError extends Error {
  constructor(issues: string[]) {
    super(`Invalid environment configuration: ${issues.join(", ")}`);
    this.name = "ConfigurationError";
  }
}

export function loadConfig(environment: NodeJS.ProcessEnv = process.env): AppConfig {
  const result = environmentSchema.safeParse(environment);

  if (!result.success) {
    const issues = result.error.issues.map((issue) => issue.path.join("."));
    throw new ConfigurationError(issues);
  }

  return result.data;
}
