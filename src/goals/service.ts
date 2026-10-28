import type { Database } from "../db/client.js";
import { isUniqueViolation, toDate } from "../db/utils.js";
import { DomainError } from "../errors.js";
import type { CreateGoalInput, GoalPeriod, GoalResponse, UpdateGoalInput } from "./schemas.js";

export class GoalConflictError extends DomainError {
  constructor() {
    super(409, "GOAL_CONFLICT", "A goal for this category and period already exists");
  }
}

export class GoalNotFoundError extends DomainError {
  constructor() {
    super(404, "GOAL_NOT_FOUND", "Goal not found");
  }
}

export class GoalCategoryNotFoundError extends DomainError {
  constructor() {
    super(404, "CATEGORY_NOT_FOUND", "Category not found");
  }
}

const goalColumns = ["id", "category_id", "period", "target_seconds", "created_at"] as const;

export class GoalService {
  constructor(private readonly db: Database) {}

  async list(userId: string): Promise<GoalResponse[]> {
    const rows = await this.db
      .selectFrom("goals")
      .select(goalColumns)
      .where("user_id", "=", userId)
      .orderBy("created_at", "asc")
      .orderBy("id", "asc")
      .execute();

    return rows.map(toGoal);
  }

  async create(userId: string, input: CreateGoalInput): Promise<GoalResponse> {
    const category = await this.db
      .selectFrom("categories")
      .select("id")
      .where("id", "=", input.categoryId)
      .where("user_id", "=", userId)
      .executeTakeFirst();
    if (!category) throw new GoalCategoryNotFoundError();

    try {
      const row = await this.db
        .insertInto("goals")
        .values({
          user_id: userId,
          category_id: input.categoryId,
          period: input.period,
          target_seconds: input.targetSeconds,
        })
        .returning(goalColumns)
        .executeTakeFirstOrThrow();

      return toGoal(row);
    } catch (error) {
      if (isUniqueViolation(error)) throw new GoalConflictError();
      throw error;
    }
  }

  async update(userId: string, goalId: string, input: UpdateGoalInput): Promise<GoalResponse> {
    const row = await this.db
      .updateTable("goals")
      .set({ target_seconds: input.targetSeconds })
      .where("id", "=", goalId)
      .where("user_id", "=", userId)
      .returning(goalColumns)
      .executeTakeFirst();

    if (!row) throw new GoalNotFoundError();
    return toGoal(row);
  }

  async delete(userId: string, goalId: string): Promise<void> {
    const result = await this.db
      .deleteFrom("goals")
      .where("id", "=", goalId)
      .where("user_id", "=", userId)
      .executeTakeFirst();

    if (result.numDeletedRows === 0n) throw new GoalNotFoundError();
  }
}

function toGoal(row: {
  id: string;
  category_id: string;
  period: GoalPeriod;
  target_seconds: number;
  created_at: Date | string | object;
}): GoalResponse {
  return {
    id: row.id,
    categoryId: row.category_id,
    period: row.period,
    targetSeconds: row.target_seconds,
    createdAt: toDate(row.created_at),
  };
}
