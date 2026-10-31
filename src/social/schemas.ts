import { z } from "zod";

export const followUserSchema = z.object({
  userId: z.uuid(),
});

export const feedQuerySchema = z.object({
  cursor: z.string().max(1024).optional(),
  limit: z.coerce.number().int().min(1).max(100).default(20),
});

export type FeedQuery = z.infer<typeof feedQuerySchema>;

export const userParamsSchema = z.object({
  userId: z.uuid(),
});

export const idParamsSchema = z.object({
  id: z.uuid(),
});

export const privacySchema = z.object({
  isPrivate: z.boolean(),
});

export const commentBodySchema = z.object({
  body: z.string().trim().min(1).max(500),
});

export type FollowStatus = "following" | "requested";

export interface CommentResponse {
  id: string;
  body: string;
  createdAt: Date;
  author: {
    id: string;
    username: string;
    displayName: string;
  };
  /** The commenter and the log's author can delete a comment. */
  canDelete: boolean;
}

export interface CommentPage {
  comments: CommentResponse[];
  nextCursor: string | null;
}

export interface FeedEntry {
  id: string;
  title: string;
  notes: string | null;
  startedAt: Date;
  endedAt: Date;
  durationSeconds: number;
  visibility: "public" | "private" | "friends_only";
  createdAt: Date;
  /** Only on the viewer's own logs, so their device can match an entry to a log it is still syncing. */
  idempotencyKey?: string;
  author: {
    id: string;
    username: string;
    displayName: string;
    avatarUrl: string | null;
  };
  categories: Array<{
    id: string;
    name: string;
    colorHex: string;
  }>;
  kudosCount: number;
  viewerGaveKudos: boolean;
  commentCount: number;
}

export interface FeedPage {
  items: FeedEntry[];
  nextCursor: string | null;
}

export interface FeedCursor {
  createdAt: string;
  id: string;
}
