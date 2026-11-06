import { z } from "zod";

export const goalPeriods = ["day", "week"] as const;

const targetSecondsSchema = z.number().int().min(60).max(7 * 86400);

export const createGoalSchema = z.object({
  categoryId: z.uuid(),
  period: z.enum(goalPeriods),
  targetSeconds: targetSecondsSchema,
});

export const updateGoalSchema = z.object({
  targetSeconds: targetSecondsSchema,
});

export const goalParamsSchema = z.object({
  id: z.uuid(),
});

export type GoalPeriod = (typeof goalPeriods)[number];
export type CreateGoalInput = z.infer<typeof createGoalSchema>;
export type UpdateGoalInput = z.infer<typeof updateGoalSchema>;

export interface GoalResponse {
  id: string;
  categoryId: string;
  period: GoalPeriod;
  targetSeconds: number;
  createdAt: Date;
}
