import argon2 from "argon2";
import type { Database } from "../db/client.js";
import { isUniqueViolation, toDate } from "../db/utils.js";
import { DomainError } from "../errors.js";
import type { CreateCategoryInput, CategoryResponse, UpdateEmailInput, UpdateProfileInput } from "./schemas.js";
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
      const row = await this.db
        .insertInto("categories")
        .values({
          user_id: userId,
          name: input.name,
          ...(input.colorHex === undefined ? {} : { color_hex: input.colorHex }),
        })
        .returning(["id", "name", "color_hex", "created_at"])
        .executeTakeFirstOrThrow();

      return toCategory(row);
    } catch (error) {
      if (isUniqueViolation(error)) throw new CategoryConflictError();
      throw error;
    }
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
