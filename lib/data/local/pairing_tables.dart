part of 'app_database.dart';

@DataClassName('StoredPairingState')
class PairingStates extends Table {
  TextColumn get owner => text()();
  TextColumn get credentialScope => text().withLength(min: 64, max: 64)();
  IntColumn get generation => integer().withDefault(const Constant(0))();
  TextColumn get stateJson => text().nullable()();
  IntColumn get stateRevision => integer().withDefault(const Constant(0))();
  IntColumn get refreshedAt => integer().nullable()();
  TextColumn get draftCode => text().withDefault(const Constant(''))();
  IntColumn get draftRevision => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {owner};
  @override
  List<String> get customConstraints => [
    'CHECK (generation >= 0 AND state_revision >= 0 AND draft_revision >= 0)',
    'CHECK ((state_json IS NULL) = (refreshed_at IS NULL))',
  ];
}

@DataClassName('StoredPairingCommand')
class PairingCommands extends Table {
  TextColumn get owner => text().references(PairingStates, #owner)();
  TextColumn get operationId => text().withLength(min: 36, max: 36).unique()();
  IntColumn get generation => integer()();
  TextColumn get kind => text()();
  TextColumn get requestJson => text()();
  TextColumn get status => text()();
  TextColumn get errorCode => text().nullable()();
  IntColumn get retryAfter => integer().nullable()();
  IntColumn get attempts => integer()();
  IntColumn get baseStateRevision => integer()();
  IntColumn get baseDraftRevision => integer()();
  IntColumn get startedAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {owner};
  @override
  List<String> get customConstraints => [
    "CHECK (kind IN ('createInvite','cancelInvite','join','leave'))",
    "CHECK (status IN ('sending','uncertain','failed'))",
    "CHECK ((status = 'sending') = (error_code IS NULL))",
    'CHECK (generation >= 0 AND attempts > 0 AND base_state_revision >= 0 AND base_draft_revision >= 0)',
    'CHECK (retry_after IS NULL OR retry_after >= 0)',
  ];
}
