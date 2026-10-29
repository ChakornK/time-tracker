import type { Database } from "../db/client.js";
import { isUniqueViolation, toDate } from "../db/utils.js";
import { DomainError } from "../errors.js";
import type { CreateLogInput, LogReceipt, UpdateLogInput } from "./schemas.js";

export class CategoryOwnershipError extends DomainError {
  constructor() {
    super(400, "INVALID_CATEGORIES", "One or more categories are unavailable to this account");
  }
}

export class LogConflictError extends DomainError {
  constructor() {
    super(409, "IDEMPOTENCY_CONFLICT", "Idempotency key is already associated with another log request");
  }
}

export class LogNotFoundError extends DomainError {
  constructor() {
    super(404, "LOG_NOT_FOUND", "Log not found");
  }
}

export class InvalidLogTimesError extends DomainError {
  constructor() {
    super(400, "INVALID_LOG_TIMES", "End time must be at or after start time");
  }
}

interface ExistingLog {
  id: string;
  user_id: string;
  title: string;
  notes: string | null;
  started_at: Date | string | object;
  ended_at: Date | string | object;
  visibility: string;
}

export class LogService {
  constructor(private readonly db: Database) {}

  async create(userId: string, input: CreateLogInput): Promise<LogReceipt> {
    try {
      const result = await this.db.transaction().execute(async (transaction) => {
        const existing = await findLogByIdempotencyKey(transaction, input.idempotencyKey);
        if (existing) return replayExistingLog(transaction, userId, existing, input);

        if (input.categoryIds.length > 0) {
          const ownedCategories = await transaction
            .selectFrom("categories")
            .select("id")
            .where("user_id", "=", userId)
            .where("id", "in", input.categoryIds)
            .execute();

          if (ownedCategories.length !== new Set(input.categoryIds).size) {
            throw new CategoryOwnershipError();
          }
        }

        const log = await transaction
          .insertInto("logs")
          .values({
            user_id: userId,
            title: input.title,
            notes: input.notes ?? null,
            started_at: new Date(input.startedAt),
            ended_at: new Date(input.endedAt),
            visibility: input.visibility,
            idempotency_key: input.idempotencyKey,
          })
          .returning(["id"])
          .executeTakeFirstOrThrow();

        if (input.categoryIds.length > 0) {
          await transaction
            .insertInto("log_categories")
            .values(input.categoryIds.map((categoryId) => ({
              log_id: log.id,
              category_id: categoryId,
            })))
            .execute();
        }

        return { id: log.id, idempotencyKey: input.idempotencyKey, created: true };
      });
      return result;
    } catch (error) {
      if (!isUniqueViolation(error)) throw error;

      // A concurrent request with the same idempotency key committed first.
      const existing = await findLogByIdempotencyKey(this.db, input.idempotencyKey);
      if (!existing) throw error;
      return replayExistingLog(this.db, userId, existing, input);
    }
  }

  /** Changes a log the user owns. Another user's log reads as not found, so IDs can't be probed. */
  async update(userId: string, logId: string, input: UpdateLogInput): Promise<void> {
    await this.db.transaction().execute(async (transaction) => {
      const existing = await transaction
        .selectFrom("logs")
        .select(["id", "started_at", "ended_at"])
        .where("id", "=", logId)
        .where("user_id", "=", userId)
        .forUpdate()
        .executeTakeFirst();
      if (!existing) throw new LogNotFoundError();

      const startedAt = input.startedAt ? new Date(input.startedAt) : toDate(existing.started_at);
      const endedAt = input.endedAt ? new Date(input.endedAt) : toDate(existing.ended_at);
      if (endedAt < startedAt) throw new InvalidLogTimesError();

      if (input.categoryIds && input.categoryIds.length > 0) {
        const owned = await transaction
          .selectFrom("categories")
          .select("id")
          .where("user_id", "=", userId)
          .where("id", "in", input.categoryIds)
          .execute();
        if (owned.length !== input.categoryIds.length) throw new CategoryOwnershipError();
      }

      const columns = {
        ...(input.title !== undefined && { title: input.title }),
        ...(input.notes !== undefined && { notes: input.notes }),
        ...(input.startedAt !== undefined && { started_at: startedAt }),
        ...(input.endedAt !== undefined && { ended_at: endedAt }),
        ...(input.visibility !== undefined && { visibility: input.visibility }),
      };
      // A categories-only edit changes no log columns, and an empty SET is invalid SQL.
      if (Object.keys(columns).length > 0) {
        await transaction.updateTable("logs").set(columns).where("id", "=", logId).execute();
      }

      if (input.categoryIds) {
        await transaction.deleteFrom("log_categories").where("log_id", "=", logId).execute();
        if (input.categoryIds.length > 0) {
          await transaction
            .insertInto("log_categories")
            .values(input.categoryIds.map((categoryId) => ({ log_id: logId, category_id: categoryId })))
            .execute();
        }
      }
    });
  }

  async delete(userId: string, logId: string): Promise<void> {
    const deleted = await this.db
      .deleteFrom("logs")
      .where("id", "=", logId)
      .where("user_id", "=", userId)
      .executeTakeFirst();
    if (deleted.numDeletedRows === 0n) throw new LogNotFoundError();
  }
}

function findLogByIdempotencyKey(db: Database, idempotencyKey: string): Promise<ExistingLog | undefined> {
  return db
    .selectFrom("logs")
    .select(["id", "user_id", "title", "notes", "started_at", "ended_at", "visibility"])
    .where("idempotency_key", "=", idempotencyKey)
    .executeTakeFirst();
}

/** Returns the stored receipt when a retry repeats the original request exactly. */
async function replayExistingLog(
  db: Database,
  userId: string,
  existing: ExistingLog,
  input: CreateLogInput,
): Promise<LogReceipt> {
  const links = await db
    .selectFrom("log_categories")
    .select("category_id")
    .where("log_id", "=", existing.id)
    .execute();
  const existingCategoryIds = links.map((link) => link.category_id).sort();
  const requestedCategoryIds = [...input.categoryIds].sort();

  const matches = existing.user_id === userId &&
    existing.title === input.title &&
    existing.notes === (input.notes ?? null) &&
    toDate(existing.started_at).getTime() === Date.parse(input.startedAt) &&
    toDate(existing.ended_at).getTime() === Date.parse(input.endedAt) &&
    existing.visibility === input.visibility &&
    sameStrings(existingCategoryIds, requestedCategoryIds);

  if (!matches) throw new LogConflictError();
  return { id: existing.id, idempotencyKey: input.idempotencyKey, created: false };
}

function sameStrings(left: string[], right: string[]): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}
