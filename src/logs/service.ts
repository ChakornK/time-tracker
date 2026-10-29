import type { Database } from "../db/client.js";
import { isUniqueViolation, toDate } from "../db/utils.js";
import { DomainError } from "../errors.js";
import type { CreateLogInput, LogReceipt } from "./schemas.js";

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
