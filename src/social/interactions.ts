import { sql } from "kysely";
import type { Database } from "../db/client.js";
import { toDate } from "../db/utils.js";
import { DomainError } from "../errors.js";
import { LogNotFoundError } from "../logs/service.js";
import type { CommentPage, CommentResponse, FeedCursor } from "./schemas.js";
import { visibleOutsideFeed } from "./visible-logs.js";

export class SelfKudosError extends DomainError {
  constructor() {
    super(400, "SELF_KUDOS_NOT_ALLOWED", "You can't give kudos to your own log");
  }
}

export class CommentNotFoundError extends DomainError {
  constructor() {
    super(404, "COMMENT_NOT_FOUND", "Comment not found");
  }
}

export class CommentDeleteForbiddenError extends DomainError {
  constructor() {
    super(403, "COMMENT_DELETE_FORBIDDEN", "Only the commenter or the log's author can delete a comment");
  }
}

export interface KudosState {
  kudosCount: number;
  viewerGaveKudos: boolean;
}

/** Kudos and comments, allowed only on logs the viewer can see. */
export class InteractionService {
  constructor(private readonly db: Database) {}

  async giveKudos(viewerId: string, logId: string): Promise<KudosState> {
    const log = await this.findVisibleLog(viewerId, logId);
    if (log.authorId === viewerId) throw new SelfKudosError();

    await this.db
      .insertInto("kudos")
      .values({ log_id: logId, user_id: viewerId })
      .onConflict((conflict) => conflict.columns(["log_id", "user_id"]).doNothing())
      .execute();
    return this.kudosState(viewerId, logId);
  }

  async removeKudos(viewerId: string, logId: string): Promise<KudosState> {
    await this.findVisibleLog(viewerId, logId);
    await this.db
      .deleteFrom("kudos")
      .where("log_id", "=", logId)
      .where("user_id", "=", viewerId)
      .execute();
    return this.kudosState(viewerId, logId);
  }

  /** Oldest first, so a conversation reads top to bottom. */
  async listComments(viewerId: string, logId: string, query: { cursor?: FeedCursor; limit: number }): Promise<CommentPage> {
    const log = await this.findVisibleLog(viewerId, logId);

    let commentQuery = this.db
      .selectFrom("comments")
      .innerJoin("users", "users.id", "comments.user_id")
      .select([
        "comments.id",
        "comments.body",
        "comments.created_at",
        "users.id as author_id",
        "users.username",
        "users.display_name",
      ])
      .where("comments.log_id", "=", logId);

    // Postgres keeps microseconds but the cursor carries a JavaScript Date's milliseconds, so both
    // the order and the comparison use milliseconds; otherwise a page's last comment sorts after
    // its own cursor and repeats on the next page.
    const createdAtMillis = sql<Date>`date_trunc('milliseconds', comments.created_at)`;
    const { cursor } = query;
    if (cursor) {
      const cursorCreatedAt = new Date(cursor.createdAt);
      commentQuery = commentQuery.where((expression) => expression.or([
        expression(createdAtMillis, ">", cursorCreatedAt),
        expression.and([
          expression(createdAtMillis, "=", cursorCreatedAt),
          expression("comments.id", ">", cursor.id),
        ]),
      ]));
    }

    const rows = await commentQuery
      .orderBy(createdAtMillis, "asc")
      .orderBy("comments.id", "asc")
      .limit(query.limit + 1)
      .execute();

    const hasMore = rows.length > query.limit;
    const comments = rows.slice(0, query.limit).map((row) => toComment(row, viewerId, log.authorId));
    const last = comments.at(-1);
    return {
      comments,
      nextCursor: hasMore && last
        ? Buffer.from(JSON.stringify({ createdAt: last.createdAt.toISOString(), id: last.id })).toString("base64url")
        : null,
    };
  }

  async addComment(viewerId: string, logId: string, body: string): Promise<CommentResponse> {
    const log = await this.findVisibleLog(viewerId, logId);

    const inserted = await this.db
      .insertInto("comments")
      .values({ log_id: logId, user_id: viewerId, body })
      .returning(["id", "body", "created_at"])
      .executeTakeFirstOrThrow();
    const author = await this.db
      .selectFrom("users")
      .select(["id as author_id", "username", "display_name"])
      .where("id", "=", viewerId)
      .executeTakeFirstOrThrow();
    return toComment({ ...inserted, ...author }, viewerId, log.authorId);
  }

  async deleteComment(viewerId: string, commentId: string): Promise<void> {
    const comment = await this.db
      .selectFrom("comments")
      .select(["log_id", "user_id"])
      .where("id", "=", commentId)
      .executeTakeFirst();
    if (!comment) throw new CommentNotFoundError();

    // Commenters can always take back their own words, even on a log they can no longer see.
    if (comment.user_id === viewerId) {
      await this.db.deleteFrom("comments").where("id", "=", commentId).execute();
      return;
    }

    // Someone else's comment on a log the viewer can't see is reported as missing, not forbidden.
    let log: { authorId: string };
    try {
      log = await this.findVisibleLog(viewerId, comment.log_id);
    } catch (error) {
      if (error instanceof LogNotFoundError) throw new CommentNotFoundError();
      throw error;
    }
    if (log.authorId !== viewerId) throw new CommentDeleteForbiddenError();

    await this.db.deleteFrom("comments").where("id", "=", commentId).execute();
  }

  private async findVisibleLog(viewerId: string, logId: string): Promise<{ authorId: string }> {
    const row = await this.db
      .selectFrom("logs")
      .innerJoin("users as author", "author.id", "logs.user_id")
      .leftJoin("follows as viewer_follow", (join) =>
        join.onRef("viewer_follow.following_id", "=", "logs.user_id")
          .on("viewer_follow.follower_id", "=", viewerId),
      )
      .leftJoin("follows as author_follow", (join) =>
        join.onRef("author_follow.follower_id", "=", "logs.user_id")
          .on("author_follow.following_id", "=", viewerId),
      )
      .select("logs.user_id")
      .where("logs.id", "=", logId)
      .where(visibleOutsideFeed(viewerId))
      .executeTakeFirst();
    // A log the viewer can't see is reported as missing, so its existence isn't revealed.
    if (!row) throw new LogNotFoundError();
    return { authorId: row.user_id };
  }

  private async kudosState(viewerId: string, logId: string): Promise<KudosState> {
    const row = await this.db
      .selectFrom("kudos")
      .select((expression) => [
        expression.fn.countAll<string>().as("count"),
        expression.fn.countAll<string>().filterWhere("user_id", "=", viewerId).as("mine"),
      ])
      .where("log_id", "=", logId)
      .executeTakeFirstOrThrow();
    return { kudosCount: Number(row.count), viewerGaveKudos: Number(row.mine) > 0 };
  }
}

function toComment(
  row: { id: string; body: string; created_at: Parameters<typeof toDate>[0]; author_id: string; username: string; display_name: string },
  viewerId: string,
  logAuthorId: string,
): CommentResponse {
  return {
    id: row.id,
    body: row.body,
    createdAt: toDate(row.created_at),
    author: { id: row.author_id, username: row.username, displayName: row.display_name },
    canDelete: row.author_id === viewerId || logAuthorId === viewerId,
  };
}
