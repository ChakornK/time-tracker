// The feed reads straight from Postgres in (created_at, id) order across many authors, so an index
// in that order lets each page stop after `limit` visible rows instead of sorting every log.
exports.up = (pgm) => {
  pgm.createIndex("logs", [{ name: "created_at", sort: "DESC" }, { name: "id", sort: "DESC" }], {
    name: "logs_feed_order_index",
  });
};

exports.down = (pgm) => {
  pgm.dropIndex("logs", [], { name: "logs_feed_order_index" });
};
