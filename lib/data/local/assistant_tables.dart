part of 'app_database.dart';

@DataClassName('StoredDiaryProposal')
class AssistantDiaryProposals extends Table {
  TextColumn get id => text()();
  TextColumn get owner => text()();
  TextColumn get sessionId => text()();
  TextColumn get messageId => text()();
  TextColumn get suggestedDay => text().nullable()();
  TextColumn get content => text()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get targetDay => text().nullable()();
  TextColumn get entryId => text().nullable()();
  TextColumn get beforeJson => text().nullable()();
  IntColumn get appliedRevision => integer().nullable()();
  IntColumn get appliedDraftRevision => integer().nullable()();
  IntColumn get appliedAt => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {messageId, owner},
  ];
  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (message_id, session_id, owner) REFERENCES assistant_messages (id, session_id, owner) ON DELETE CASCADE',
    "CHECK (status IN ('pending', 'cancelled', 'applied', 'undone'))",
    "CHECK ((status IN ('applied', 'undone')) = (entry_id IS NOT NULL AND target_day IS NOT NULL AND applied_revision IS NOT NULL AND applied_draft_revision IS NOT NULL AND applied_at IS NOT NULL))",
  ];
}

@DataClassName('StoredAssistantSettings')
class AssistantSettings extends Table {
  TextColumn get owner => text()();
  IntColumn get consentVersion => integer().withDefault(const Constant(0))();
  IntColumn get consentedAt => integer().nullable()();
  BoolColumn get sendMemories => boolean().withDefault(const Constant(true))();
  BoolColumn get sendSchedule => boolean().withDefault(const Constant(true))();
  BoolColumn get sendStats => boolean().withDefault(const Constant(true))();
  BoolColumn get autoMemory => boolean().withDefault(const Constant(true))();
  BoolColumn get agentEnabled => boolean().withDefault(const Constant(true))();
  @override
  Set<Column<Object>> get primaryKey => {owner};
  @override
  List<String> get customConstraints => [
    'CHECK ((consent_version = 0 AND consented_at IS NULL) OR '
        '(consent_version > 0 AND consented_at IS NOT NULL))',
  ];
}

@DataClassName('StoredAssistantSession')
class AssistantSessions extends Table {
  TextColumn get id => text()();
  TextColumn get owner => text()();
  TextColumn get title => text()();
  TextColumn get summary => text().nullable()();
  TextColumn get summaryThrough => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  @override
  Set<Column<Object>> get primaryKey => {id};
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {id, owner},
  ];
}

@DataClassName('StoredAssistantMessage')
class AssistantMessages extends Table {
  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get owner => text()();
  TextColumn get role => text()();
  TextColumn get content => text()();
  TextColumn get status => text()();
  TextColumn get requestId => text().nullable()();
  TextColumn get sentPayload => text().nullable()();
  TextColumn get agentMetadata => text().nullable()();
  IntColumn get createdAt => integer()();
  @override
  Set<Column<Object>> get primaryKey => {id};
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {id, owner},
    {id, sessionId, owner},
  ];
  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (session_id, owner) REFERENCES assistant_sessions (id, owner) ON DELETE CASCADE',
    "CHECK (role IN ('user', 'assistant'))",
    "CHECK (status IN ('pending', 'sent', 'failed', 'discarded'))",
  ];
}

@DataClassName('StoredAssistantMemory')
class AssistantMemories extends Table {
  TextColumn get id => text()();
  TextColumn get owner => text()();
  TextColumn get category => text()();
  TextColumn get content => text()();
  // Source IDs are provenance, not live FKs: deleting a chat preserves memory.
  TextColumn get sourceSessionId => text().nullable()();
  TextColumn get sourceMessageId => text().nullable()();
  TextColumn get sourceLabel => text().nullable()();
  TextColumn get expiresOn => text().nullable()();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  @override
  Set<Column<Object>> get primaryKey => {id};
  @override
  List<String> get customConstraints => [
    "CHECK (category IN ('作息', '偏好', '目标与背景', '近期约束', '其他'))",
    'CHECK (length(content) > 0)',
  ];
}

@DataClassName('StoredMemoryEvent')
class MemoryEvents extends Table {
  TextColumn get id => text()();
  TextColumn get owner => text()();
  TextColumn get messageId => text()();
  TextColumn get op => text()();
  TextColumn get memoryId => text()();
  TextColumn get beforeJson => text().nullable()();
  TextColumn get afterJson => text().nullable()();
  BoolColumn get reverted => boolean().withDefault(const Constant(false))();
  @override
  Set<Column<Object>> get primaryKey => {id};
  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (message_id, owner) REFERENCES assistant_messages (id, owner) ON DELETE CASCADE',
    "CHECK (op IN ('add', 'update', 'delete'))",
  ];
}

@DataClassName('StoredPlanProposal')
class PlanProposals extends Table {
  TextColumn get id => text()();
  TextColumn get owner => text()();
  // Applied receipts can be detached when their conversation is deleted.
  TextColumn get sessionId => text().nullable()();
  TextColumn get messageId => text().nullable()();
  TextColumn get itemsJson => text()();
  TextColumn get agentMetadata => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('draft'))();
  TextColumn get appliedItemsJson => text().nullable()();
  TextColumn get appliedGoalIdsJson => text().nullable()();
  IntColumn get appliedAt => integer().nullable()();
  IntColumn get undoneAt => integer().nullable()();
  TextColumn get undoResultJson => text().nullable()();
  @override
  Set<Column<Object>> get primaryKey => {id};
  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (session_id, owner) REFERENCES assistant_sessions (id, owner)',
    'FOREIGN KEY (message_id, session_id, owner) REFERENCES assistant_messages (id, session_id, owner)',
    "CHECK (status IN ('draft', 'applied', 'undone'))",
    "CHECK (status != 'draft' OR (session_id IS NOT NULL AND message_id IS NOT NULL))",
    "CHECK (status = 'draft' OR (applied_items_json IS NOT NULL AND applied_goal_ids_json IS NOT NULL AND applied_at IS NOT NULL))",
    "CHECK (status != 'undone' OR (undone_at IS NOT NULL AND undo_result_json IS NOT NULL))",
  ];
}

@DataClassName('StoredReminderCancellation')
class ReminderCancellations extends Table {
  IntColumn get notificationId => integer()();
  TextColumn get owner => text()();
  TextColumn get payload => text()();
  @override
  Set<Column<Object>> get primaryKey => {notificationId};
}
