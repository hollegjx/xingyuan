const migrationTables = [
  'goals',
  'goal_titles',
  'goal_schedules',
  'check_ins',
  'goal_reminders',
  'reminder_occurrences',
];

const migrationSeedStatements = [
  "INSERT INTO goals (id, owner, kind, created_day, created_at, "
      "archived_day, archived_at) VALUES "
      "(1, 'guest', 0, '2026-10-01', 1001, NULL, NULL), "
      "(2, 'guest', 1, '2026-10-02', 2002, '2026-10-08', 8002), "
      "(3, 'user:11111111-1111-4111-8111-111111111111', 0, "
      "'2026-10-03', 3003, NULL, NULL)",
  "INSERT INTO goal_titles VALUES "
      "(1, '2026-10-01', 'TEST original'), "
      "(1, '2026-10-05', 'TEST renamed'), "
      "(2, '2026-10-02', 'TEST archived single'), "
      "(3, '2026-10-03', 'TEST separate owner')",
  "INSERT INTO goal_schedules VALUES "
      "(1, '2026-10-01', 127, NULL), "
      "(1, '2026-10-06', 21, NULL), "
      "(2, '2026-10-02', 0, '2026-10-04'), "
      "(3, '2026-10-03', 64, NULL)",
  "INSERT INTO check_ins VALUES "
      "(1, 0, '2026-10-01', 1, '2026-10-01', 1234, 'Asia/Shanghai', "
      "'TEST original', NULL), "
      "(1, 0, '2026-10-05', 0, '2026-10-05', 5234, 'America/New_York', "
      "'TEST renamed', NULL), "
      "(2, 1, 'once', 1, '2026-10-07', 7234, 'Asia/Tokyo', "
      "'TEST archived single', '2026-10-04')",
  "INSERT INTO goal_reminders VALUES "
      "(1, 1, 1200, 7, 1, 'error'), "
      "(2, 0, 480, 9, 0, 'disabled'), "
      "(3, 1, 720, 3, 1, 'pending')",
  "INSERT INTO reminder_occurrences VALUES "
      "(41, 1, '2026-10-11', 11001, 'Asia/Shanghai', 1, 0), "
      "(99, 2, '2026-10-04', 4002, 'Asia/Tokyo', 1, 1), "
      "(100, 3, '2026-10-11', 11003, 'Asia/Shanghai', 0, 0)",
  "INSERT INTO goals (id, kind, created_day, created_at) "
      "VALUES (900, 0, '2026-10-10', 9000)",
  'DELETE FROM goals WHERE id = 900',
];
