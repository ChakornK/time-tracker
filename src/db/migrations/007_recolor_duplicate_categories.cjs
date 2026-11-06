// Mirrors src/profile/palette.ts at the time of this migration.
const palette = ["#2A78D6", "#EB6834", "#1BAF7A", "#EDA100", "#E87BA4", "#008300", "#6250D6", "#E34948"];
const overflowColor = "#8E8E93";

// Within each account the oldest category keeps its palette color. Later ones that repeat a color (or
// hold a non-palette color) take the first palette color nobody in the account uses, or grey once
// all eight are taken. Grey is shared on purpose, so it never counts as a duplicate.
exports.up = async (pgm) => {
  const rows = await pgm.db.select(
    "SELECT id, user_id, color_hex FROM categories ORDER BY user_id, created_at, id",
  );
  const byUser = new Map();
  for (const row of rows) {
    if (!byUser.has(row.user_id)) byUser.set(row.user_id, []);
    byUser.get(row.user_id).push(row);
  }

  for (const categories of byUser.values()) {
    const used = new Set();
    const needsColor = [];
    for (const category of categories) {
      const color = category.color_hex.toUpperCase();
      if (color === overflowColor) continue;
      if (palette.includes(color) && !used.has(color)) used.add(color);
      else needsColor.push(category);
    }
    for (const category of needsColor) {
      const color = palette.find((candidate) => !used.has(candidate)) ?? overflowColor;
      used.add(color);
      pgm.sql(`UPDATE categories SET color_hex = '${color}' WHERE id = '${category.id}'`);
    }
  }
};

// The original colors aren't recorded, so there is nothing to restore.
exports.down = () => {};
