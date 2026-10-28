exports.up = (pgm) => {
  pgm.createTable("goals", {
    id: { type: "uuid", primaryKey: true, default: pgm.func("gen_random_uuid()") },
    user_id: { type: "uuid", notNull: true, references: '"users"', onDelete: "CASCADE" },
    category_id: { type: "uuid", notNull: true, references: '"categories"', onDelete: "CASCADE" },
    period: { type: "varchar(5)", notNull: true },
    target_seconds: { type: "integer", notNull: true },
    created_at: { type: "timestamptz", notNull: true, default: pgm.func("current_timestamp") },
  });
  pgm.addConstraint("goals", "goals_user_category_period_unique", { unique: ["user_id", "category_id", "period"] });
  pgm.addConstraint("goals", "goals_period_check", { check: "period IN ('day', 'week', 'month')" });
  // A month goal can at most fill 31 days.
  pgm.addConstraint("goals", "goals_target_seconds_check", { check: "target_seconds > 0 AND target_seconds <= 2678400" });
};

exports.down = (pgm) => {
  pgm.dropTable("goals");
};
