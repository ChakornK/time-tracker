import type { ColumnType, Generated } from "kysely";

export type Timestamp = ColumnType<Date, Date | string, Date | string>;

export interface UsersTable {
  id: string;
  username: string;
  display_name: string;
  email: string;
  password_hash: string;
  avatar_url: string | null;
  is_private: Generated<boolean>;
  created_at: Generated<Timestamp>;
}

export interface CategoriesTable {
  id: Generated<string>;
  user_id: string;
  name: string;
  color_hex: Generated<string>;
  created_at: Generated<Timestamp>;
}

export interface LogsTable {
  id: Generated<string>;
  user_id: string;
  title: string;
  notes: string | null;
  started_at: Timestamp;
  ended_at: Timestamp;
  duration_seconds: Generated<number>;
  visibility: Generated<"public" | "private" | "friends_only">;
  idempotency_key: string;
  created_at: Generated<Timestamp>;
}

export interface LogCategoriesTable {
  log_id: string;
  category_id: string;
}

export interface FollowsTable {
  follower_id: string;
  following_id: string;
  created_at: Generated<Timestamp>;
}

/** A follow of a private account that its owner hasn't accepted yet. */
export interface FollowRequestsTable {
  requester_id: string;
  target_id: string;
  created_at: Generated<Timestamp>;
}

export interface KudosTable {
  log_id: string;
  user_id: string;
  created_at: Generated<Timestamp>;
}

export interface CommentsTable {
  id: Generated<string>;
  log_id: string;
  user_id: string;
  body: string;
  created_at: Generated<Timestamp>;
}

export interface GoalsTable {
  id: Generated<string>;
  user_id: string;
  category_id: string;
  period: "day" | "week" | "month";
  target_seconds: number;
  created_at: Generated<Timestamp>;
}

export interface DatabaseSchema {
  users: UsersTable;
  categories: CategoriesTable;
  logs: LogsTable;
  log_categories: LogCategoriesTable;
  follows: FollowsTable;
  follow_requests: FollowRequestsTable;
  kudos: KudosTable;
  comments: CommentsTable;
  goals: GoalsTable;
}
