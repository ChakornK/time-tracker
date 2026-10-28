import { z } from "zod";
import { emailSchema, passwordSchema } from "../auth/schemas.js";

export const updateProfileSchema = z.object({
  displayName: z.string().trim().min(1).max(100).optional(),
  avatarUrl: z.union([z.url(), z.null()]).optional(),
}).refine((value) => Object.keys(value).length > 0);

export const updateEmailSchema = z.object({
  email: emailSchema,
  currentPassword: passwordSchema,
});

export const createCategorySchema = z.object({
  name: z.string().trim().min(1).max(50),
  colorHex: z.string().regex(/^#[0-9A-Fa-f]{6}$/).optional(),
});

export type UpdateProfileInput = z.infer<typeof updateProfileSchema>;
export type UpdateEmailInput = z.infer<typeof updateEmailSchema>;
export type CreateCategoryInput = z.infer<typeof createCategorySchema>;

export interface CategoryResponse {
  id: string;
  name: string;
  colorHex: string;
  createdAt: Date;
}
