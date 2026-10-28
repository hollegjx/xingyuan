part of 'app_database.dart';

@DataClassName('StoredDayRecord')
class DayRecords extends Table {
  TextColumn get id => text().withLength(min: 36, max: 36)();
  IntColumn get goalId => integer()();
  TextColumn get owner => text()();
  TextColumn get day => text().withLength(min: 10, max: 10)();
  TextColumn get zone => text().withDefault(const Constant('UTC'))();
  TextColumn get content => text().withDefault(const Constant(''))();
  BoolColumn get shareWithPartner =>
      boolean().withDefault(const Constant(false))();
  TextColumn get syncState => text().withDefault(const Constant('local'))();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  IntColumn get savedAt => integer().nullable()();
  IntColumn get deletedAt => integer().nullable()();
  TextColumn get lastOperationId => text().nullable()();
  // Unsaved edits never overwrite the content selected for analysis or sharing.
  TextColumn get draftText => text().nullable()();
  BoolColumn get draftShareWithPartner =>
      boolean().withDefault(const Constant(false))();
  IntColumn get draftRevision => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {goalId, owner, day},
    {id, owner},
  ];

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (goal_id, owner) REFERENCES goals (id, owner)',
    'CHECK (revision >= 0 AND draft_revision >= 0)',
    "CHECK (sync_state IN ('local', 'pending', 'confirmed', 'failed'))",
    'CHECK (last_operation_id IS NULL OR length(last_operation_id) = 36)',
  ];
}

@DataClassName('StoredRecordPhoto')
class RecordPhotos extends Table {
  TextColumn get id => text().withLength(min: 36, max: 36)();
  TextColumn get recordId => text()();
  TextColumn get owner => text()();
  TextColumn get filename => text()();
  IntColumn get width => integer()();
  IntColumn get height => integer()();
  IntColumn get byteCount => integer()();
  TextColumn get sha256 => text().withLength(min: 64, max: 64)();
  TextColumn get uploadState => text().withDefault(const Constant('local'))();
  // Both lists can reference the same immutable file while editing a record.
  // Unreferenced rows retain the filename until file cleanup succeeds.
  IntColumn get savedPosition => integer().nullable()();
  IntColumn get draftPosition => integer().nullable()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {owner, filename},
    {recordId, savedPosition},
    {recordId, draftPosition},
  ];

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (record_id, owner) REFERENCES day_records (id, owner)',
    'CHECK (width BETWEEN 1 AND 1600 AND height BETWEEN 1 AND 1600)',
    'CHECK (byte_count BETWEEN 1 AND 2097152)',
    "CHECK (filename = id || '.jpg' AND id NOT GLOB '*[^a-f0-9-]*')",
    "CHECK (sha256 NOT GLOB '*[^a-f0-9]*')",
    'CHECK (saved_position IS NULL OR saved_position BETWEEN 0 AND 2)',
    'CHECK (draft_position IS NULL OR draft_position BETWEEN 0 AND 2)',
    "CHECK (upload_state IN ('local', 'pending', 'uploaded', 'failed'))",
  ];
}
