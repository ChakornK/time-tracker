exports.up = (pgm) => {
  pgm.sql("DELETE FROM goals WHERE period = 'month'");
  pgm.dropConstraint("goals", "goals_period_check");
  pgm.addConstraint("goals", "goals_period_check", { check: "period IN ('day', 'week')" });
};

exports.down = (pgm) => {
  pgm.dropConstraint("goals", "goals_period_check");
  pgm.addConstraint("goals", "goals_period_check", { check: "period IN ('day', 'week', 'month')" });
};
