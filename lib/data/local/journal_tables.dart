part of 'app_database.dart';

abstract class JournalEntries extends Table {
  TextColumn get id => text().withLength(min: 36, max: 36)();
  TextColumn get owner => text()();
  TextColumn get day => text().withLength(min: 10, max: 10)();
  TextColumn get zone => text()();
  TextColumn get content => text().withDefault(const Constant(''))();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  IntColumn get savedAt => integer().nullable()();
  IntColumn get deletedAt => integer().nullable()();
  TextColumn get lastOperationId => text().nullable()();
  IntColumn get lastOperationDraftRevision => integer().nullable()();
  TextColumn get draftText => text().nullable()();
  IntColumn get draftRevision => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {id, owner},
  ];

  @override
  List<String> get customConstraints => [
    'CHECK (revision >= 0 AND draft_revision >= 0)',
    'CHECK (last_operation_id IS NULL OR length(last_operation_id) = 36)',
    'CHECK ((last_operation_id IS NULL) = (last_operation_draft_revision IS NULL))',
    'CHECK (last_operation_draft_revision IS NULL OR last_operation_draft_revision >= 0)',
    'CHECK (deleted_at IS NULL OR saved_at IS NULL)',
  ];
}

@UseRowClass(JournalEntry)
@TableIndex(
  name: 'quick_notes_by_day',
  columns: {#owner, #day, #createdAt, #id},
)
class QuickNotes extends JournalEntries {}

@UseRowClass(JournalEntry)
class DiaryEntries extends JournalEntries {
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {id, owner},
    {owner, day},
  ];
}

abstract class JournalPhotos extends Table {
  TextColumn get id => text().withLength(min: 36, max: 36)();
  TextColumn get entryId => text()();
  TextColumn get owner => text()();
  TextColumn get filename => text()();
  IntColumn get width => integer()();
  IntColumn get height => integer()();
  IntColumn get byteCount => integer()();
  TextColumn get sha256 => text().withLength(min: 64, max: 64)();
  IntColumn get savedPosition => integer().nullable()();
  IntColumn get draftPosition => integer().nullable()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {owner, filename},
    {entryId, savedPosition},
    {entryId, draftPosition},
  ];
}

@UseRowClass(JournalPhoto)
class QuickNotePhotos extends JournalPhotos {
  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (entry_id, owner) REFERENCES quick_notes (id, owner)',
    'CHECK (width BETWEEN 1 AND 1600 AND height BETWEEN 1 AND 1600)',
    'CHECK (byte_count BETWEEN 1 AND 2097152)',
    "CHECK (filename = id || '.jpg' AND id NOT GLOB '*[^a-f0-9-]*')",
    "CHECK (sha256 NOT GLOB '*[^a-f0-9]*')",
    'CHECK (saved_position IS NULL OR saved_position BETWEEN 0 AND 2)',
    'CHECK (draft_position IS NULL OR draft_position BETWEEN 0 AND 2)',
  ];
}

@UseRowClass(JournalPhoto)
class DiaryPhotos extends JournalPhotos {
  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (entry_id, owner) REFERENCES diary_entries (id, owner)',
    'CHECK (width BETWEEN 1 AND 1600 AND height BETWEEN 1 AND 1600)',
    'CHECK (byte_count BETWEEN 1 AND 2097152)',
    "CHECK (filename = id || '.jpg' AND id NOT GLOB '*[^a-f0-9-]*')",
    "CHECK (sha256 NOT GLOB '*[^a-f0-9]*')",
    'CHECK (saved_position IS NULL OR saved_position BETWEEN 0 AND 2)',
    'CHECK (draft_position IS NULL OR draft_position BETWEEN 0 AND 2)',
  ];
}
