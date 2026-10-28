const assistantMigrationStatements = [
  "INSERT INTO goals VALUES (1, '11111111-1111-4111-8111-111111111111', 'guest', 0, '2026-10-01', 100, NULL, NULL)",
  "INSERT INTO goal_titles VALUES (1, '2026-10-01', 'TEST reading'), (1, '2026-10-05', 'TEST renamed')",
  "INSERT INTO goal_schedules VALUES (1, '2026-10-01', 127, NULL), (1, '2026-10-05', 21, NULL)",
  "INSERT INTO check_ins VALUES (1, 0, '2026-10-02', 1, '2026-10-02', 200, 'Asia/Shanghai', 'TEST reading', NULL), (1, 0, '2026-10-03', 0, '2026-10-03', 300, 'Asia/Shanghai', 'TEST reading', NULL)",
  "INSERT INTO goal_reminders VALUES (1, 1, 1200, 7, 1, 'pending')",
  "INSERT INTO reminder_occurrences VALUES (41, 1, 'guest', '2026-10-20', 2000, 'Asia/Shanghai', 1, 0)",
  "INSERT INTO sync_states VALUES (1, 2, 3, '{}', 1234)",
  "INSERT INTO sync_outbox VALUES (9, '22222222-2222-4222-8222-222222222222', 'guest', 1, 'edit', '{}', 3, 2, 'conflict', 1, 100, NULL, 'conflict', NULL)",
  "INSERT INTO sync_conflicts VALUES ('33333333-3333-4333-8333-333333333333', 'guest', 1, '22222222-2222-4222-8222-222222222222', 2, 3, '{}', '{}', 101, NULL, NULL)",
  "INSERT INTO identity_states VALUES (1, 'guest', 7, NULL)",
  "INSERT INTO guest_transfers VALUES ('44444444-4444-4444-8444-444444444444', 'user:55555555-5555-4555-8555-555555555555', '[1]', 102)",
  "INSERT INTO planning_profiles VALUES ('other-owner', 'TEST separate owner', 900), ('empty', '  ', 901)",
  "INSERT INTO planning_drafts VALUES ('old-draft', 'guest', '2026-10-20', 60, '[]', NULL, 1000), ('old-receipt', 'guest', '2026-10-19', 30, '[]', '[1]', 999)",
];

String assistantLongMigrationPreference() => List.generate(
  500,
  (index) => ['甲', ' ', '乙', '\n', '👨‍👩‍👧‍👦', 'e\u0301', '🇨🇳'][index % 7],
).join();
