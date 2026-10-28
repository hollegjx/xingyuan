import 'package:drift_flutter/drift_flutter.dart';

import 'app_database.dart';

AppDatabase openAppDatabase({String name = 'habit_checkin_guest'}) {
  return AppDatabase(driftDatabase(name: name));
}
