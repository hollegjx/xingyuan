part of 'app_database.dart';

@DataClassName('StoredDayAnalysisSettings')
class DayAnalysisSettings extends Table {
  TextColumn get owner => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get consentVersion => integer().withDefault(const Constant(0))();
  IntColumn get consentedAt => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {owner};

  @override
  List<String> get customConstraints => [
    'CHECK (consent_version >= 0)',
    'CHECK ((consent_version = 0) = (consented_at IS NULL))',
  ];
}

@DataClassName('StoredDayAnalysis')
class DayAnalyses extends Table {
  TextColumn get id => text().withLength(min: 36, max: 36)();
  TextColumn get owner => text()();
  TextColumn get day => text().withLength(min: 10, max: 10)();
  TextColumn get zone => text()();
  TextColumn get requestJson => text()();
  TextColumn get responseJson => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get failureCode => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('pending', 'succeeded', 'failed', 'cancelled'))",
    "CHECK ((status = 'succeeded') = (response_json IS NOT NULL))",
    "CHECK ((status IN ('failed', 'cancelled')) = (failure_code IS NOT NULL))",
  ];
}
