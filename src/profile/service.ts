import argon2 from "argon2";
import { sql } from "kysely";
import type { Database } from "../db/client.js";
import { isUniqueViolation, toDate } from "../db/utils.js";
import { DomainError } from "../errors.js";
import { nextCategoryColor } from "./palette.js";
import type {
  CreateCategoryInput,
  CategoryResponse,
  UpdateCategoryInput,
  UpdateEmailInput,
  UpdateProfileInput,
} from "./schemas.js";
import type { PublicUser } from "../auth/schemas.js";

export class ProfileNotFoundError extends DomainError {
  constructor() {
    super(404, "PROFILE_NOT_FOUND", "Profile not found");
  }
}

export class CategoryConflictError extends DomainError {
  constructor() {
    super(409, "CATEGORY_CONFLICT", "Category name already exists");
  }
}

export class CategoryNotFoundError extends DomainError {
  constructor() {
    super(404, "CATEGORY_NOT_FOUND", "Category not found");
  }
}

export class EmailConflictError extends DomainError {
  constructor() {
    super(409, "EMAIL_CONFLICT", "Email is already in use");
  }
}

export class IncorrectPasswordError extends DomainError {
  constructor() {
    super(403, "INCORRECT_PASSWORD", "Current password is incorrect");
  }
}

export interface ProfileServiceOptions {
  passwordHasher?: Pick<typeof argon2, "verify">;
}

export class ProfileService {
  private readonly passwordHasher: Pick<typeof argon2, "verify">;

  constructor(
    private readonly db: Database,
    options: ProfileServiceOptions = {},
  ) {
    this.passwordHasher = options.passwordHasher ?? argon2;
  }

  async getProfile(userId: string): Promise<PublicUser> {
    const row = await this.db
      .selectFrom("users")
      .select(["id", "username", "display_name", "email", "avatar_url", "created_at"])
      .where("id", "=", userId)
      .executeTakeFirst();

    if (!row) throw new ProfileNotFoundError();
    return toPublicUser(row);
  }

  async updateProfile(userId: string, input: UpdateProfileInput): Promise<PublicUser> {
    const changes: { display_name?: string; avatar_url?: string | null } = {};
    if (input.displayName !== undefined) changes.display_name = input.displayName;
    if (input.avatarUrl !== undefined) changes.avatar_url = input.avatarUrl;

    const row = await this.db
      .updateTable("users")
      .set(changes)
      .where("id", "=", userId)
      .returning(["id", "username", "display_name", "email", "avatar_url", "created_at"])
      .executeTakeFirst();

    if (!row) throw new ProfileNotFoundError();
    return toPublicUser(row);
  }

  async updateEmail(userId: string, input: UpdateEmailInput): Promise<PublicUser> {
    const credentials = await this.db
      .selectFrom("users")
      .select("password_hash")
      .where("id", "=", userId)
      .executeTakeFirst();
    if (!credentials) throw new ProfileNotFoundError();
    if (!(await this.passwordHasher.verify(credentials.password_hash, input.currentPassword))) {
      throw new IncorrectPasswordError();
    }

    try {
      const row = await this.db
        .updateTable("users")
        .set({ email: input.email })
        .where("id", "=", userId)
        .returning(["id", "username", "display_name", "email", "avatar_url", "created_at"])
        .executeTakeFirst();

      if (!row) throw new ProfileNotFoundError();
      return toPublicUser(row);
    } catch (error) {
      if (isUniqueViolation(error)) throw new EmailConflictError();
      throw error;
    }
  }

  async createCategory(userId: string, input: CreateCategoryInput): Promise<CategoryResponse> {
    try {
      // The lock serializes one account's creates so two at once can't both claim the same free color.
      const row = await this.db.transaction().execute(async (trx) => {
        await sql`SELECT pg_advisory_xact_lock(hashtext(${userId}))`.execute(trx);
        const colorHex = input.colorHex ?? nextCategoryColor(
          (await trx.selectFrom("categories").select("color_hex").where("user_id", "=", userId).execute())
            .map((existing) => existing.color_hex),
        );
        return trx
          .insertInto("categories")
          .values({ user_id: userId, name: input.name, color_hex: colorHex })
          .returning(["id", "name", "color_hex", "created_at"])
          .executeTakeFirstOrThrow();
      });

      return toCategory(row);
    } catch (error) {
      if (isUniqueViolation(error)) throw new CategoryConflictError();
      throw error;
    }
  }

  async updateCategory(userId: string, categoryId: string, input: UpdateCategoryInput): Promise<CategoryResponse> {
    const changes: { name?: string; color_hex?: string } = {};
    if (input.name !== undefined) changes.name = input.name;
    if (input.colorHex !== undefined) changes.color_hex = input.colorHex;

    try {
      const row = await this.db
        .updateTable("categories")
        .set(changes)
        .where("id", "=", categoryId)
        .where("user_id", "=", userId)
        .returning(["id", "name", "color_hex", "created_at"])
        .executeTakeFirst();

      if (!row) throw new CategoryNotFoundError();
      return toCategory(row);
    } catch (error) {
      if (isUniqueViolation(error)) throw new CategoryConflictError();
      throw error;
    }
  }

  /** Logs keep their time but lose the link to this category; goals for it are deleted with it. */
  async deleteCategory(userId: string, categoryId: string): Promise<void> {
    const result = await this.db
      .deleteFrom("categories")
      .where("id", "=", categoryId)
      .where("user_id", "=", userId)
      .executeTakeFirst();

    if (result.numDeletedRows === 0n) throw new CategoryNotFoundError();
  }

  async listCategories(userId: string): Promise<CategoryResponse[]> {
    const rows = await this.db
      .selectFrom("categories")
      .select(["id", "name", "color_hex", "created_at"])
      .where("user_id", "=", userId)
      .orderBy("created_at", "asc")
      .orderBy("id", "asc")
      .execute();

    return rows.map(toCategory);
  }
}

function toPublicUser(row: {
  id: string;
  username: string;
  display_name: string;
  email: string;
  avatar_url: string | null;
  created_at: Date | string | object;
}): PublicUser {
  return {
    id: row.id,
    username: row.username,
    displayName: row.display_name,
    email: row.email,
    avatarUrl: row.avatar_url,
    createdAt: toDate(row.created_at),
  };
}

function toCategory(row: {
  id: string;
  name: string;
  color_hex: string;
  created_at: Date | string | object;
}): CategoryResponse {
  return {
    id: row.id,
    name: row.name,
    colorHex: row.color_hex,
    createdAt: toDate(row.created_at),
  };
}
