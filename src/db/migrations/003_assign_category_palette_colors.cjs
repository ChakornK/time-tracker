// Mirrors src/profile/palette.ts at the time of this migration.
const palette = ["#2A78D6", "#EB6834", "#1BAF7A", "#EDA100", "#E87BA4", "#008300", "#6250D6", "#E34948"];

// Categories created before colors were assigned all hold the column default. Give them the palette
// slot the app already showed them in: their creation order within each account.
exports.up = (pgm) => {
  const paletteArray = `ARRAY[${palette.map((color) => `'${color}'`).join(", ")}]`;
  pgm.sql(`
    UPDATE categories
    SET color_hex = (${paletteArray})[((ranked.position - 1) % ${palette.length}) + 1]
    FROM (
      SELECT id, row_number() OVER (PARTITION BY user_id ORDER BY created_at, id) AS position
      FROM categories
    ) AS ranked
    WHERE categories.id = ranked.id AND categories.color_hex = '#3B82F6'
  `);
};

// The original colors aren't recorded, so there is nothing to restore.
exports.down = () => {};
