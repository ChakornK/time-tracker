exports.up = (pgm) => {
  // A private account approves each new follower through a follow request.
  pgm.addColumn("users", {
    is_private: { type: "boolean", notNull: true, default: false },
  });

  // Kept apart from `follows`, which only ever holds accepted follows, so visibility rules can keep
  // treating a row in `follows` as permission.
  pgm.createTable("follow_requests", {
    requester_id: { type: "uuid", notNull: true, references: '"users"', onDelete: "CASCADE" },
    target_id: { type: "uuid", notNull: true, references: '"users"', onDelete: "CASCADE" },
    created_at: { type: "timestamptz", notNull: true, default: pgm.func("current_timestamp") },
  });
  pgm.addConstraint("follow_requests", "follow_requests_pkey", { primaryKey: ["requester_id", "target_id"] });
  pgm.addConstraint("follow_requests", "follow_requests_distinct_users_check", {
    check: "requester_id <> target_id",
  });
  pgm.createIndex("follow_requests", ["target_id", "created_at"]);

  pgm.createTable("kudos", {
    log_id: { type: "uuid", notNull: true, references: '"logs"', onDelete: "CASCADE" },
    user_id: { type: "uuid", notNull: true, references: '"users"', onDelete: "CASCADE" },
    created_at: { type: "timestamptz", notNull: true, default: pgm.func("current_timestamp") },
  });
  pgm.addConstraint("kudos", "kudos_pkey", { primaryKey: ["log_id", "user_id"] });
  pgm.createIndex("kudos", ["user_id"]);

  pgm.createTable("comments", {
    id: { type: "uuid", primaryKey: true, default: pgm.func("gen_random_uuid()") },
    log_id: { type: "uuid", notNull: true, references: '"logs"', onDelete: "CASCADE" },
    user_id: { type: "uuid", notNull: true, references: '"users"', onDelete: "CASCADE" },
    body: { type: "varchar(500)", notNull: true },
    created_at: { type: "timestamptz", notNull: true, default: pgm.func("current_timestamp") },
  });
  pgm.addConstraint("comments", "comments_body_not_blank_check", { check: "length(btrim(body)) > 0" });
  pgm.createIndex("comments", ["log_id", "created_at", "id"]);
  pgm.createIndex("comments", ["user_id"]);
};

exports.down = (pgm) => {
  pgm.dropTable("comments");
  pgm.dropTable("kudos");
  pgm.dropTable("follow_requests");
  pgm.dropColumn("users", "is_private");
};
