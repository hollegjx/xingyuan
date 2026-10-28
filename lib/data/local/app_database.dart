import 'package:characters/characters.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../features/journal/domain/journal_entry.dart';

part 'app_database.g.dart';
part 'assistant_tables.dart';
part 'day_record_tables.dart';
part 'day_analysis_tables.dart';
part 'pairing_tables.dart';
part 'sharing_tables.dart';
part 'publication_tables.dart';
part 'chat_tables.dart';
part 'journal_tables.dart';

@DataClassName('StoredGoal')
class Goals extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get globalId => text()
      .withLength(min: 36, max: 36)
      .clientDefault(() => const Uuid().v4())
      .unique()();
  TextColumn get owner => text().withDefault(const Constant('guest'))();
  // Drift resolves column references when generating table implementations.
  // ignore: recursive_getters
  IntColumn get kind => integer().check(kind.isBetweenValues(0, 1))();
  TextColumn get createdDay => text().withLength(min: 10, max: 10)();
  IntColumn get createdAt => integer()();
  TextColumn get archivedDay => text().nullable()();
  IntColumn get archivedAt => integer().nullable()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {id, kind},
    {id, owner},
  ];
}

@DataClassName('StoredTitle')
class GoalTitles extends Table {
  IntColumn get goalId => integer().references(Goals, #id)();
  TextColumn get effectiveDay => text().withLength(min: 10, max: 10)();
  TextColumn get title => text().check(title.length.isBiggerThanValue(0))();

  @override
  Set<Column<Object>> get primaryKey => {goalId, effectiveDay};
}

@DataClassName('StoredSchedule')
class GoalSchedules extends Table {
  IntColumn get goalId => integer().references(Goals, #id)();
  TextColumn get effectiveDay => text().withLength(min: 10, max: 10)();
  // ignore: recursive_getters
  IntColumn get weekdays => integer().check(weekdays.isBetweenValues(0, 127))();
  TextColumn get plannedDay => text().nullable()();
  IntColumn get startMinute =>
      // ignore: recursive_getters
      integer().nullable().check(startMinute.isBetweenValues(0, 1439))();
  IntColumn get durationMinutes => integer().nullable().check(
    // ignore: recursive_getters
    durationMinutes.isBetweenValues(5, 480) &
        (startMinute.isNull() |
            // ignore: recursive_getters
            (startMinute + durationMinutes).isSmallerOrEqualValue(1440)),
  )();

  @override
  Set<Column<Object>> get primaryKey => {goalId, effectiveDay};
}

@DataClassName('StoredCheckIn')
class CheckIns extends Table {
  IntColumn get goalId => integer().references(Goals, #id)();
  IntColumn get goalKind => integer()();
  TextColumn get occurrenceKey => text()();
  BoolColumn get completed => boolean()();
  TextColumn get completedDay => text().withLength(min: 10, max: 10)();
  IntColumn get completedAt => integer()();
  TextColumn get zone => text()();
  TextColumn get titleSnapshot => text()();
  TextColumn get plannedDay => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {goalId, occurrenceKey};

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (goal_id, goal_kind) REFERENCES goals (id, kind)',
    "CHECK ((goal_kind = 1 AND occurrence_key = 'once') OR "
        '(goal_kind = 0 AND occurrence_key = completed_day))',
  ];
}

@DataClassName('StoredReminder')
class GoalReminders extends Table {
  IntColumn get goalId => integer().references(Goals, #id)();
  BoolColumn get enabled => boolean().withDefault(const Constant(false))();
  IntColumn get minuteOfDay => integer()
      .withDefault(const Constant(1200))
      // ignore: recursive_getters
      .check(minuteOfDay.isBetweenValues(0, 1439))();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  BoolColumn get needsReconcile =>
      boolean().withDefault(const Constant(true))();
  TextColumn get status => text().withDefault(const Constant('disabled'))();

  @override
  Set<Column<Object>> get primaryKey => {goalId};
}

@DataClassName('StoredReminderOccurrence')
class ReminderOccurrences extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get goalId => integer().references(Goals, #id)();
  TextColumn get owner => text().withDefault(const Constant('guest'))();
  TextColumn get day => text().withLength(min: 10, max: 10)();
  IntColumn get fireAt => integer()();
  TextColumn get zone => text()();
  // Written before calling iOS, including calls with an unknown outcome.
  BoolColumn get armed => boolean().withDefault(const Constant(false))();
  BoolColumn get ended => boolean().withDefault(const Constant(false))();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {goalId, day},
  ];
}

@DataClassName('StoredSyncState')
class SyncStates extends Table {
  IntColumn get goalId => integer().references(Goals, #id)();
  IntColumn get serverRevision => integer().withDefault(const Constant(0))();
  IntColumn get localRevision => integer().withDefault(const Constant(0))();
  TextColumn get confirmedJson => text().nullable()();
  IntColumn get lastSyncedAt => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {goalId};

  @override
  List<String> get customConstraints => [
    'CHECK (server_revision >= 0 AND local_revision >= 0)',
  ];
}

@DataClassName('StoredSyncOperation')
class SyncOutbox extends Table {
  IntColumn get sequence => integer().autoIncrement()();
  TextColumn get operationId => text().withLength(min: 36, max: 36)();
  TextColumn get owner => text()();
  IntColumn get goalId => integer().references(Goals, #id)();
  TextColumn get kind => text()();
  TextColumn get documentJson => text()();
  IntColumn get localRevision => integer()();
  IntColumn get baseRevision => integer().nullable()();
  TextColumn get state => text().withDefault(const Constant('pending'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer()();
  IntColumn get retryAfter => integer().nullable()();
  TextColumn get lastError => text().nullable()();
  TextColumn get supersededBy => text().nullable()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {operationId},
    {operationId, goalId, owner},
  ];

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (goal_id, owner) REFERENCES goals (id, owner) '
        'DEFERRABLE INITIALLY DEFERRED',
    'CHECK (local_revision > 0 AND attempts >= 0)',
    'CHECK (base_revision IS NULL OR base_revision >= 0)',
    "CHECK (state IN ('pending', 'in_flight', 'conflict', 'superseded'))",
    "CHECK (state != 'in_flight' OR base_revision IS NOT NULL)",
    "CHECK (kind IN ('create', 'edit', 'set_completed', 'set_uncompleted', "
        "'archive', 'import_guest', 'resolve_conflict'))",
  ];
}

@DataClassName('StoredSyncConflict')
class SyncConflicts extends Table {
  TextColumn get id => text()
      .withLength(min: 36, max: 36)
      .clientDefault(() => const Uuid().v4())();
  TextColumn get owner => text()();
  IntColumn get goalId => integer().references(Goals, #id)();
  TextColumn get operationId => text().references(SyncOutbox, #operationId)();
  IntColumn get baseRevision => integer()();
  IntColumn get remoteRevision => integer()();
  TextColumn get localJson => text()();
  TextColumn get remoteJson => text()();
  IntColumn get createdAt => integer()();
  IntColumn get resolvedAt => integer().nullable()();
  TextColumn get resolution => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {operationId},
  ];

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (goal_id, owner) REFERENCES goals (id, owner) '
        'DEFERRABLE INITIALLY DEFERRED',
    'CHECK (base_revision >= 0 AND remote_revision >= 0)',
    'FOREIGN KEY (operation_id, goal_id, owner) '
        'REFERENCES sync_outbox (operation_id, goal_id, owner)',
    "CHECK (resolution IS NULL OR resolution IN ('local', 'remote'))",
    'CHECK ((resolved_at IS NULL) = (resolution IS NULL))',
  ];
}

@DataClassName('StoredIdentityState')
class IdentityStates extends Table {
  IntColumn get singleton => integer().withDefault(const Constant(1))();
  TextColumn get owner => text().withDefault(const Constant('guest'))();
  IntColumn get generation => integer().withDefault(const Constant(0))();
  TextColumn get targetOwner => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {singleton};

  @override
  List<String> get customConstraints => [
    'CHECK (singleton = 1 AND generation >= 0)',
  ];
}

@DataClassName('StoredGuestTransfer')
class GuestTransfers extends Table {
  TextColumn get id => text().withLength(min: 36, max: 36)();
  TextColumn get targetOwner => text()();
  TextColumn get goalIdsJson => text()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('StoredPlanningProfile')
class PlanningProfiles extends Table {
  TextColumn get owner => text()();
  TextColumn get preferences => text()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {owner};
}

@DataClassName('StoredPlanningDraft')
class PlanningDrafts extends Table {
  TextColumn get id => text()();
  TextColumn get owner => text()();
  TextColumn get day => text()();
  IntColumn get budget => integer()();
  TextColumn get tasksJson => text()();
  TextColumn get appliedGoalIdsJson => text().nullable()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DriftDatabase(
  tables: [
    Goals,
    GoalTitles,
    GoalSchedules,
    CheckIns,
    GoalReminders,
    ReminderOccurrences,
    SyncStates,
    SyncOutbox,
    SyncConflicts,
    IdentityStates,
    GuestTransfers,
    PlanningProfiles,
    PlanningDrafts,
    AssistantSettings,
    AssistantSessions,
    AssistantMessages,
    AssistantMemories,
    MemoryEvents,
    PlanProposals,
    ReminderCancellations,
    DayRecords,
    RecordPhotos,
    DayAnalysisSettings,
    DayAnalyses,
    PairingStates,
    PairingCommands,
    SharingStates,
    SharingGrantsCache,
    SharedRecordsCache,
    SharedRepliesCache,
    SharingDrafts,
    SharingCommands,
    RecordSharingConsents,
    SharingPublicationSources,
    SharingPublications,
    SharingPublicationPhotos,
    ChatStates,
    ChatMessagesCache,
    ChatPhotos,
    ChatCommands,
    QuickNotes,
    DiaryEntries,
    QuickNotePhotos,
    DiaryPhotos,
    AssistantDiaryProposals,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(QueryExecutor executor) : super(_guardOpening(executor));

  @override
  int get schemaVersion => 13;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await migrator.createAll();
      await into(identityStates).insert(const IdentityStatesCompanion());
    },
    onUpgrade: (migrator, from, to) async {
      if (from < 1 || from > 12 || to != 13) {
        throw StateError('No migration registered from $from to $to');
      }
      if (from >= 3) {
        await transaction(() async {
          if ((await customSelect(
            'PRAGMA foreign_key_check',
          ).get()).isNotEmpty) {
            throw StateError('Migration found invalid local references');
          }
          if (from == 3) await _createPlanningTables(migrator);
          if (from < 5) await _upgradeAssistant(migrator);
          if (from < 6) await _createDayRecordTables(migrator);
          if (from < 7) await _createPairingTables(migrator);
          if (from < 8) await _createSharingTables(migrator);
          if (from < 9) await _createPublicationTables(migrator);
          if (from < 10) await _createChatTables(migrator);
          if (from < 11) await _createJournalTables(migrator);
          if (from < 12) await _createDiaryProposalTable(migrator);
          if (from >= 5) {
            await migrator.addColumn(
              assistantSettings,
              assistantSettings.agentEnabled,
            );
            await migrator.addColumn(
              assistantMessages,
              assistantMessages.agentMetadata,
            );
            await migrator.addColumn(
              planProposals,
              planProposals.agentMetadata,
            );
          }
          if ((await customSelect(
            'PRAGMA foreign_key_check',
          ).get()).isNotEmpty) {
            throw StateError('Migration found invalid local references');
          }
        });
        return;
      }
      // Rebuilding a referenced table requires FK checks outside the
      // transaction, then an explicit integrity check before committing.
      final foreignKeys = (await customSelect(
        'PRAGMA foreign_keys',
      ).getSingle()).read<int>('foreign_keys');
      await customStatement('PRAGMA foreign_keys = OFF');
      try {
        await transaction(() async {
          final sequence = await customSelect(
            "SELECT seq FROM sqlite_sequence WHERE name = 'goals'",
          ).getSingleOrNull();
          final goalsBefore = await customSelect('SELECT id FROM goals').get();
          await customStatement(
            'CREATE TEMP TABLE migration_goal_ids '
            '(id INTEGER PRIMARY KEY, global_id TEXT NOT NULL UNIQUE)',
          );
          for (final row in goalsBefore) {
            await customStatement(
              'INSERT INTO migration_goal_ids (id, global_id) VALUES (?, ?)',
              [row.read<int>('id'), const Uuid().v4()],
            );
          }
          await migrator.alterTable(
            TableMigration(
              goals,
              newColumns: [goals.globalId],
              columnTransformer: {
                goals.globalId: const CustomExpression<String>(
                  '(SELECT global_id FROM migration_goal_ids '
                  'WHERE id = goals.id)',
                ),
              },
            ),
          );
          if (sequence != null) {
            await customStatement(
              "UPDATE sqlite_sequence SET seq = ? WHERE name = 'goals'",
              [sequence.read<int>('seq')],
            );
          }
          await customStatement('DROP TABLE migration_goal_ids');
          if (from == 1) {
            await migrator.createTable(reminderOccurrences);
          } else {
            await migrator.addColumn(
              reminderOccurrences,
              reminderOccurrences.owner,
            );
            await customStatement(
              'UPDATE reminder_occurrences SET owner = '
              '(SELECT owner FROM goals WHERE goals.id = '
              'reminder_occurrences.goal_id)',
            );
          }
          await migrator.createTable(syncStates);
          await migrator.createTable(syncOutbox);
          await migrator.createTable(syncConflicts);
          await migrator.createTable(identityStates);
          await migrator.createTable(guestTransfers);
          await customStatement(
            'INSERT INTO sync_states (goal_id) SELECT id FROM goals',
          );
          await into(identityStates).insert(const IdentityStatesCompanion());
          await _createPlanningTables(migrator);
          await _upgradeAssistant(migrator);
          await _createDayRecordTables(migrator);
          await _createPairingTables(migrator);
          await _createSharingTables(migrator);
          await _createPublicationTables(migrator);
          await _createChatTables(migrator);
          await _createJournalTables(migrator);
          await _createDiaryProposalTable(migrator);
          if ((await customSelect(
            'PRAGMA foreign_key_check',
          ).get()).isNotEmpty) {
            throw StateError('Migration found invalid local references');
          }
        });
      } finally {
        await customStatement('PRAGMA foreign_keys = $foreignKeys');
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      final violations = await customSelect('PRAGMA foreign_key_check').get();
      if (violations.isNotEmpty) {
        throw StateError('Local database has invalid references');
      }
    },
  );

  Future<void> _createDiaryProposalTable(Migrator migrator) async {
    final existing = await customSelect(
      "SELECT name FROM sqlite_schema WHERE name='assistant_diary_proposals'",
    ).get();
    if (existing.isNotEmpty) {
      throw StateError('Unexpected diary proposal table');
    }
    await migrator.createTable(assistantDiaryProposals);
  }

  Future<void> _createJournalTables(Migrator migrator) async {
    final existing = await customSelect(
      'SELECT name FROM sqlite_schema WHERE name IN '
      "('quick_notes', 'diary_entries', 'quick_note_photos', 'diary_photos', "
      "'quick_notes_by_day')",
    ).get();
    if (existing.isNotEmpty) {
      throw StateError('Unexpected journal tables in an older database');
    }
    await migrator.createTable(quickNotes);
    await migrator.createTable(diaryEntries);
    await migrator.createTable(quickNotePhotos);
    await migrator.createTable(diaryPhotos);
    await migrator.createIndex(quickNotesByDay);
  }

  Future<void> _createPlanningTables(Migrator migrator) async {
    await migrator.createTable(planningProfiles);
    await migrator.createTable(planningDrafts);
  }

  Future<void> _createPairingTables(Migrator migrator) async {
    final existing = await customSelect(
      "SELECT name FROM sqlite_schema WHERE name IN ('pairing_states','pairing_commands')",
    ).get();
    if (existing.isNotEmpty) {
      throw StateError('Unexpected pairing tables in an older database');
    }
    await migrator.createTable(pairingStates);
    await migrator.createTable(pairingCommands);
  }

  Future<void> _createSharingTables(Migrator migrator) async {
    final existing = await customSelect(
      "SELECT name FROM sqlite_schema WHERE name IN ('sharing_states','sharing_grants_cache','shared_records_cache','shared_replies_cache','sharing_drafts','sharing_commands')",
    ).get();
    if (existing.isNotEmpty) {
      throw StateError('Unexpected sharing tables in an older database');
    }
    await migrator.createTable(sharingStates);
    await migrator.createTable(sharingGrantsCache);
    await migrator.createTable(sharedRecordsCache);
    await migrator.createTable(sharedRepliesCache);
    await migrator.createTable(sharingDrafts);
    await migrator.createTable(sharingCommands);
  }

  Future<void> clearSharingContent(String owner) => transaction(() async {
    await clearChatContent(owner);
    await clearPublicationIndicators(owner);
    await (delete(sharingCommands)..where((r) => r.owner.equals(owner))).go();
    await (delete(sharingDrafts)..where((r) => r.owner.equals(owner))).go();
    await (delete(
      sharedRepliesCache,
    )..where((r) => r.owner.equals(owner))).go();
    await (delete(
      sharedRecordsCache,
    )..where((r) => r.owner.equals(owner))).go();
    await (delete(
      sharingGrantsCache,
    )..where((r) => r.owner.equals(owner))).go();
    await (delete(sharingStates)..where((r) => r.owner.equals(owner))).go();
  });

  Future<void> _createChatTables(Migrator migrator) async {
    final existing = await customSelect(
      "SELECT name FROM sqlite_schema WHERE name IN "
      "('chat_states','chat_messages_cache','chat_photos','chat_commands')",
    ).get();
    if (existing.isNotEmpty) {
      throw StateError('Unexpected chat tables in an older database');
    }
    await migrator.createTable(chatStates);
    await migrator.createTable(chatMessagesCache);
    await migrator.createTable(chatPhotos);
    await migrator.createTable(chatCommands);
  }

  Future<void> clearChatContent(String owner) => transaction(() async {
    await (update(chatPhotos)..where((r) => r.owner.equals(owner))).write(
      const ChatPhotosCompanion(retired: Value(true)),
    );
    await (delete(chatCommands)..where((r) => r.owner.equals(owner))).go();
    await (delete(chatMessagesCache)..where((r) => r.owner.equals(owner))).go();
    await (delete(chatStates)..where((r) => r.owner.equals(owner))).go();
  });

  Future<void> clearPublicationIndicators(
    String owner, {
    String? grantId,
  }) async {
    final ids = <String>{};
    if (grantId != null) {
      final consent = await (select(
        recordSharingConsents,
      )..where((r) => r.owner.equals(owner) & r.grantId.equals(grantId))).get();
      ids.addAll(consent.map((r) => r.recordId));
      final sources = await (select(
        sharingPublicationSources,
      )..where((r) => r.owner.equals(owner) & r.grantId.equals(grantId))).get();
      for (final source in sources) {
        final records =
            await (select(dayRecords)..where(
                  (r) =>
                      r.owner.equals(owner) &
                      r.goalId.equals(source.goalId) &
                      r.day.equals(source.day),
                ))
                .get();
        ids.addAll(records.map((r) => r.id));
      }
    }
    await (update(dayRecords)..where(
          (r) =>
              r.owner.equals(owner) &
              (grantId == null ? const Constant(true) : r.id.isIn(ids)),
        ))
        .write(
          const DayRecordsCompanion(
            shareWithPartner: Value(false),
            draftShareWithPartner: Value(false),
            syncState: Value('local'),
          ),
        );
  }

  Future<void> _createPublicationTables(Migrator migrator) async {
    final existing = await customSelect(
      "SELECT name FROM sqlite_schema WHERE name IN "
      "('record_sharing_consents','sharing_publication_sources',"
      "'sharing_publications','sharing_publication_photos')",
    ).get();
    if (existing.isNotEmpty) {
      throw StateError('Unexpected publication tables in an older database');
    }
    await migrator.createTable(recordSharingConsents);
    await migrator.createTable(sharingPublicationSources);
    await migrator.createTable(sharingPublications);
    await migrator.createTable(sharingPublicationPhotos);
  }

  Future<void> _createDayRecordTables(Migrator migrator) async {
    final existing = await customSelect(
      "SELECT name FROM sqlite_schema WHERE name IN "
      "('day_records', 'record_photos', 'day_analysis_settings', 'day_analyses')",
    ).get();
    if (existing.isNotEmpty) {
      throw StateError('Unexpected record tables in an older database');
    }
    await migrator.createTable(dayRecords);
    await migrator.createTable(recordPhotos);
    await migrator.createTable(dayAnalysisSettings);
    await migrator.createTable(dayAnalyses);
    if ((await customSelect('PRAGMA foreign_key_check').get()).isNotEmpty) {
      throw StateError('Record migration found invalid local references');
    }
  }

  Future<void> _upgradeAssistant(Migrator migrator) async {
    final profiles = await select(planningProfiles).get();
    await migrator.addColumn(goalSchedules, goalSchedules.startMinute);
    await migrator.addColumn(goalSchedules, goalSchedules.durationMinutes);
    for (final table in <TableInfo<Table, dynamic>>[
      assistantSettings,
      assistantSessions,
      assistantMessages,
      assistantMemories,
      memoryEvents,
      planProposals,
      reminderCancellations,
    ]) {
      await migrator.createTable(table);
    }
    for (final profile in profiles) {
      if (profile.preferences.trim().isEmpty) continue;
      final characters = profile.preferences.characters;
      final group = const Uuid().v4();
      for (var start = 0; start < characters.length; start += 200) {
        // Equal timestamps use ID ordering in both the memory page and payload.
        final index = (start ~/ 200).toString().padLeft(4, '0');
        await into(assistantMemories).insert(
          AssistantMemoriesCompanion.insert(
            id: '$group-$index',
            owner: profile.owner,
            category: '偏好',
            content: characters.skip(start).take(200).toString(),
            sourceLabel: const Value('旧版偏好'),
            createdAt: profile.updatedAt,
            updatedAt: profile.updatedAt,
          ),
        );
      }
    }
  }
}

QueryExecutor _guardOpening(QueryExecutor executor) {
  final guard = _OpeningFailureGuard();
  // Keep the shared stream store when wrapping a DatabaseConnection.
  if (executor is DatabaseConnection) return executor.interceptWith(guard);
  return executor.interceptWith(guard);
}

class _OpeningFailureGuard extends QueryInterceptor {
  Object? _openingError;
  bool _hasOpened = false;

  @override
  Future<bool> ensureOpen(
    QueryExecutor executor,
    QueryExecutorUser user,
  ) async {
    try {
      final opened = await executor.ensureOpen(user);
      _hasOpened |= opened;
      return opened;
    } catch (error) {
      _openingError = error;
      rethrow;
    }
  }

  @override
  Future<void> close(QueryExecutor inner) async {
    try {
      await inner.close();
    } catch (error) {
      // A failed lazy opener has no connection to close, but Drift still needs
      // to finish disposing the database's streams and lifecycle registration.
      if (_hasOpened || !identical(error, _openingError)) rethrow;
    }
  }
}
