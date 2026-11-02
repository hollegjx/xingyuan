// Preserve every old value, checking new v13 columns against their defaults.
List<Map<String, Object?>> withAgentMigrationDefaults(
  String table,
  List<Map<String, Object?>> rows,
) => [
  for (final row in rows)
    {
      if (table == 'assistant_settings') ...{
        'agent_enabled': 1,
        'read_journal_on_request': 1,
        'settings_revision': 0,
      },
      if (table == 'assistant_messages' || table == 'plan_proposals')
        'agent_metadata': null,
      ...row,
    },
];
