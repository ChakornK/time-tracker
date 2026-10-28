import { z } from "zod";

const usernameSchema = z.string({ error: "Enter a username." })
  .trim()
  .min(1, "Enter a username.")
  .max(50, "Username must be 50 characters or fewer.");
const displayNameSchema = z.string().trim().max(100, "Display name must be 100 characters or fewer.");
// At least one character before the @ and a provider domain after it, such as name@gmail.com.
export const emailSchema = z.string({ error: "Enter an email address." })
  .trim()
  .max(255, "Email must be 255 characters or fewer.")
  .regex(/^[^\s@]+@[^\s@]+\.[^\s@]+$/, "Enter an email address like name@gmail.com.")
  .transform((email) => email.toLowerCase());
export const passwordSchema = z.string({ error: "Enter a password." })
  .min(1, "Enter a password.")
  .max(128, "Password must be 128 characters or fewer.");

export const registerSchema = z.object({
  username: usernameSchema,
  // Blank display names fall back to the username.
  displayName: displayNameSchema.optional(),
  email: emailSchema,
  password: passwordSchema,
}).transform((input) => ({ ...input, displayName: input.displayName || input.username }));

export const loginSchema = z.object({
  username: usernameSchema,
  password: passwordSchema,
});

export type RegisterInput = z.infer<typeof registerSchema>;
export type LoginInput = z.infer<typeof loginSchema>;

export interface PublicUser {
  id: string;
  username: string;
  displayName: string;
  email: string;
  avatarUrl: string | null;
  createdAt: Date;
}

export interface AuthTokens {
  accessToken: string;
  tokenType: "Bearer";
  expiresInSeconds: number;
}
