import { z } from "zod";

export const createLogSchema = z.object({
  idempotencyKey: z.uuid(),
  title: z.string().trim().min(1).max(100),
  notes: z.string().max(10000).optional(),
  startedAt: z.iso.datetime({ offset: true }),
  endedAt: z.iso.datetime({ offset: true }),
  categoryIds: z.array(z.uuid()).max(100).default([]),
  visibility: z.enum(["public", "private", "friends_only"]),
}).superRefine((value, context) => {
  if (Date.parse(value.endedAt) < Date.parse(value.startedAt)) {
    context.addIssue({
      code: "custom",
      path: ["endedAt"],
      message: "End time must be at or after start time",
    });
  }

  if (new Set(value.categoryIds).size !== value.categoryIds.length) {
    context.addIssue({
      code: "custom",
      path: ["categoryIds"],
      message: "Category IDs must be unique",
    });
  }
});

export type CreateLogInput = z.infer<typeof createLogSchema>;

/** Every field is optional; times are checked against the stored log, since only one may change. */
export const updateLogSchema = z.object({
  title: z.string().trim().min(1).max(100).optional(),
  notes: z.string().max(10000).nullable().optional(),
  startedAt: z.iso.datetime({ offset: true }).optional(),
  endedAt: z.iso.datetime({ offset: true }).optional(),
  categoryIds: z.array(z.uuid()).max(100).optional(),
  visibility: z.enum(["public", "private", "friends_only"]).optional(),
}).superRefine((value, context) => {
  if (Object.values(value).every((field) => field === undefined)) {
    context.addIssue({ code: "custom", message: "Provide at least one field to change" });
  }
  if (value.categoryIds && new Set(value.categoryIds).size !== value.categoryIds.length) {
    context.addIssue({ code: "custom", path: ["categoryIds"], message: "Category IDs must be unique" });
  }
});

export type UpdateLogInput = z.infer<typeof updateLogSchema>;

export const logParamsSchema = z.object({
  id: z.uuid(),
});

export interface LogReceipt {
  id: string;
  idempotencyKey: string;
  created: boolean;
}
