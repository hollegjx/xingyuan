part of 'app_database.dart';

@DataClassName('StoredRecordSharingConsent')
class RecordSharingConsents extends Table {
  TextColumn get owner => text()();
  TextColumn get recordId => text()();
  TextColumn get stage => text()();
  TextColumn get sessionId => text().withLength(min: 36, max: 36)();
  TextColumn get grantId => text()();
  @override
  Set<Column<Object>> get primaryKey => {owner, recordId, stage};
  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (record_id, owner) REFERENCES day_records(id, owner)',
    'FOREIGN KEY (owner, grant_id) REFERENCES sharing_grants_cache(owner, id) ON DELETE CASCADE',
    "CHECK (stage IN ('created','draft','saved'))",
  ];
}

@DataClassName('StoredPublicationSource')
class SharingPublicationSources extends Table {
  TextColumn get id => text().withLength(min: 36, max: 36)();
  TextColumn get owner => text()();
  IntColumn get goalId => integer()();
  TextColumn get day => text().withLength(min: 10, max: 10)();
  TextColumn get sessionId => text().withLength(min: 36, max: 36)();
  TextColumn get grantId => text()();
  TextColumn get remoteId => text().nullable()();
  IntColumn get remoteRevision => integer().withDefault(const Constant(0))();
  @override
  Set<Column<Object>> get primaryKey => {owner, id};
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {owner, grantId, goalId, day},
  ];
  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (goal_id, owner) REFERENCES goals(id, owner)',
    'FOREIGN KEY (owner, grant_id) REFERENCES sharing_grants_cache(owner, id) ON DELETE CASCADE',
    'CHECK (remote_revision >= 0)',
    'CHECK ((remote_id IS NULL) = (remote_revision = 0))',
    'CHECK (remote_id IS NULL OR length(remote_id) = 36)',
  ];
}

@DataClassName('StoredPublication')
class SharingPublications extends Table {
  IntColumn get sequence => integer().autoIncrement()();
  TextColumn get owner => text()();
  TextColumn get operationId => text().withLength(min: 36, max: 36).unique()();
  TextColumn get sourceId => text()();
  TextColumn get recordId => text().nullable()();
  IntColumn get recordRevision => integer().nullable()();
  TextColumn get kind => text()();
  TextColumn get title => text()();
  IntColumn get occurredAt => integer()();
  IntColumn get completedAt => integer().nullable()();
  BoolColumn get shareDetails => boolean()();
  TextColumn get content => text()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get requestJson => text().nullable()();
  TextColumn get receiptJson => text().nullable()();
  TextColumn get errorCode => text().nullable()();
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {owner, operationId},
  ];
  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (owner, source_id) REFERENCES sharing_publication_sources(owner, id) ON DELETE CASCADE',
    'FOREIGN KEY (record_id, owner) REFERENCES day_records(id, owner)',
    "CHECK (kind IN ('publish','remove'))",
    "CHECK (status IN ('pending','sending','uncertain','failed','succeeded'))",
    "CHECK ((status IN ('failed','uncertain')) = (error_code IS NOT NULL))",
    "CHECK ((status = 'succeeded') = (receipt_json IS NOT NULL))",
    "CHECK (share_details OR content = '')",
    'CHECK (attempts >= 0 AND (record_revision IS NULL OR record_revision >= 0))',
    'CHECK ((record_id IS NULL) = (record_revision IS NULL))',
  ];
}

@DataClassName('StoredPublicationPhoto')
class SharingPublicationPhotos extends Table {
  TextColumn get owner => text()();
  TextColumn get operationId => text()();
  TextColumn get photoId => text().references(RecordPhotos, #id)();
  IntColumn get position => integer()();
  TextColumn get uploadOperationId =>
      text().withLength(min: 36, max: 36).unique()();
  TextColumn get receiptJson => text().nullable()();
  @override
  Set<Column<Object>> get primaryKey => {owner, operationId, photoId};
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {owner, operationId, position},
  ];
  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (owner, operation_id) REFERENCES sharing_publications(owner, operation_id) ON DELETE CASCADE',
    'CHECK (position BETWEEN 0 AND 2)',
  ];
}
