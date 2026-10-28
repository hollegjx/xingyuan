part of 'app_database.dart';

@DataClassName('StoredSharingState')
class SharingStates extends Table {
  TextColumn get owner => text().references(PairingStates, #owner)();
  IntColumn get generation => integer()();
  TextColumn get sessionId => text().withLength(min: 36, max: 36)();
  TextColumn get groupId => text().withLength(min: 36, max: 36)();
  TextColumn get memberId => text().withLength(min: 36, max: 36)();
  TextColumn get partnerId => text().withLength(min: 36, max: 36)();
  IntColumn get cacheRevision => integer().withDefault(const Constant(0))();
  IntColumn get serverRevision => integer().nullable()();
  IntColumn get refreshedAt => integer().nullable()();
  @override
  Set<Column<Object>> get primaryKey => {owner};
  @override
  List<String> get customConstraints => [
    'CHECK (generation >= 0 AND cache_revision >= 0)',
    'CHECK (server_revision IS NULL OR server_revision >= 0)',
    'CHECK ((server_revision IS NULL) = (refreshed_at IS NULL))',
    'CHECK (member_id <> partner_id)',
  ];
}

@DataClassName('StoredSharingGrant')
class SharingGrantsCache extends Table {
  TextColumn get owner => text().references(SharingStates, #owner)();
  TextColumn get id => text().withLength(min: 36, max: 36)();
  TextColumn get goalId => text().withLength(min: 36, max: 36)();
  TextColumn get documentJson => text()();
  @override
  Set<Column<Object>> get primaryKey => {owner, id};
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {owner, goalId},
  ];
}

@DataClassName('StoredSharedRecord')
class SharedRecordsCache extends Table {
  TextColumn get owner => text().references(SharingStates, #owner)();
  TextColumn get id => text().withLength(min: 36, max: 36)();
  TextColumn get grantId => text().withLength(min: 36, max: 36)();
  TextColumn get authorId => text().withLength(min: 36, max: 36)();
  IntColumn get sequence => integer()();
  TextColumn get documentJson => text()();
  @override
  Set<Column<Object>> get primaryKey => {owner, id};
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {owner, sequence},
  ];
  @override
  List<String> get customConstraints => ['CHECK (sequence > 0)'];
}

@DataClassName('StoredSharedReply')
class SharedRepliesCache extends Table {
  TextColumn get owner => text()();
  TextColumn get id => text().withLength(min: 36, max: 36)();
  TextColumn get recordId => text().withLength(min: 36, max: 36)();
  TextColumn get authorId => text().withLength(min: 36, max: 36)();
  IntColumn get sequence => integer()();
  TextColumn get documentJson => text()();
  @override
  Set<Column<Object>> get primaryKey => {owner, id};
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {owner, sequence},
  ];
  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (owner, record_id) REFERENCES shared_records_cache(owner, id) ON DELETE CASCADE',
    'CHECK (sequence > 0)',
  ];
}

@DataClassName('StoredSharingDraft')
class SharingDrafts extends Table {
  TextColumn get owner => text()();
  TextColumn get recordId => text().withLength(min: 36, max: 36)();
  TextColumn get content => text().withDefault(const Constant(''))();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer()();
  @override
  Set<Column<Object>> get primaryKey => {owner, recordId};
  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (owner, record_id) REFERENCES shared_records_cache(owner, id) ON DELETE CASCADE',
    'CHECK (revision >= 0)',
  ];
}

@DataClassName('StoredSharingCommand')
class SharingCommands extends Table {
  IntColumn get sequence => integer().autoIncrement()();
  TextColumn get owner => text().references(SharingStates, #owner)();
  TextColumn get operationId => text().withLength(min: 36, max: 36).unique()();
  TextColumn get kind => text()();
  TextColumn get subject => text()();
  TextColumn get recordId => text().nullable()();
  TextColumn get requestJson => text()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  IntColumn get draftRevision => integer().nullable()();
  TextColumn get errorCode => text().nullable()();
  TextColumn get receiptJson => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  @override
  List<String> get customConstraints => [
    "CHECK (kind IN ('enable','stop','publish','remove','reply','deleteReply'))",
    "CHECK (status IN ('pending','sending','uncertain','failed','succeeded'))",
    "CHECK ((status IN ('failed','uncertain')) = (error_code IS NOT NULL))",
    "CHECK ((status = 'succeeded') = (receipt_json IS NOT NULL))",
    'CHECK (attempts >= 0 AND (draft_revision IS NULL OR draft_revision >= 0))',
  ];
}
