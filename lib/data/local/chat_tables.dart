part of 'app_database.dart';

@DataClassName('StoredChatState')
class ChatStates extends Table {
  TextColumn get owner => text().references(SharingStates, #owner)();
  TextColumn get sessionId => text().withLength(min: 36, max: 36)();
  IntColumn get cacheRevision => integer().withDefault(const Constant(0))();
  IntColumn get serverRevision => integer().nullable()();
  IntColumn get snapshotRevision => integer().nullable()();
  IntColumn get refreshedAt => integer().nullable()();
  IntColumn get readSequence => integer().withDefault(const Constant(0))();
  TextColumn get draftText => text().withDefault(const Constant(''))();
  TextColumn get draftPhotoId => text().nullable()();
  IntColumn get draftRevision => integer().withDefault(const Constant(0))();
  @override
  Set<Column<Object>> get primaryKey => {owner};
  @override
  List<String> get customConstraints => [
    'CHECK (cache_revision >= 0 AND read_sequence >= 0 AND draft_revision >= 0)',
    'CHECK (server_revision IS NULL OR server_revision >= 0)',
    'CHECK (snapshot_revision IS NULL OR (snapshot_revision >= 0 AND snapshot_revision <= server_revision))',
    'CHECK (refreshed_at IS NULL OR server_revision IS NOT NULL)',
  ];
}

@DataClassName('StoredChatMessage')
class ChatMessagesCache extends Table {
  TextColumn get owner => text().references(ChatStates, #owner)();
  TextColumn get id => text().withLength(min: 36, max: 36)();
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

// Retired metadata survives scope clearing until its sandbox file is removed.
@DataClassName('StoredChatPhoto')
class ChatPhotos extends Table {
  TextColumn get id => text().withLength(min: 36, max: 36)();
  TextColumn get owner => text()();
  TextColumn get sessionId => text().withLength(min: 36, max: 36)();
  IntColumn get width => integer()();
  IntColumn get height => integer()();
  IntColumn get byteCount => integer()();
  TextColumn get sha256 => text().withLength(min: 64, max: 64)();
  BoolColumn get retired => boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer()();
  @override
  Set<Column<Object>> get primaryKey => {id};
  @override
  List<String> get customConstraints => [
    'CHECK (width BETWEEN 1 AND 1600 AND height BETWEEN 1 AND 1600)',
    'CHECK (byte_count BETWEEN 1 AND 2097152)',
  ];
}

@DataClassName('StoredChatCommand')
class ChatCommands extends Table {
  IntColumn get sequence => integer().autoIncrement()();
  TextColumn get owner => text().references(ChatStates, #owner)();
  TextColumn get operationId => text().withLength(min: 36, max: 36).unique()();
  TextColumn get kind => text()();
  TextColumn get content => text().withDefault(const Constant(''))();
  TextColumn get localPhotoId => text().nullable()();
  TextColumn get uploadOperationId => text().nullable()();
  TextColumn get photoReceiptJson => text().nullable()();
  TextColumn get messageId => text().nullable()();
  TextColumn get requestJson => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  IntColumn get draftRevision => integer().nullable()();
  TextColumn get errorCode => text().nullable()();
  TextColumn get receiptJson => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  @override
  List<String> get customConstraints => [
    "CHECK (kind IN ('send','remove'))",
    "CHECK (status IN ('pending','sending','uncertain','failed','succeeded'))",
    "CHECK ((status IN ('failed','uncertain')) = (error_code IS NOT NULL))",
    "CHECK ((status = 'succeeded') = (receipt_json IS NOT NULL))",
    "CHECK (kind <> 'remove' OR (message_id IS NOT NULL AND local_photo_id IS NULL))",
    'CHECK (attempts >= 0)',
    'CHECK (local_photo_id IS NULL OR upload_operation_id IS NOT NULL)',
  ];
}
