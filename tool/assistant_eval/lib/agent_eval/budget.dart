import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Attempt reservations are durable before transport and never refunded.
/// A claimed evaluation cannot be resumed, including after a process crash.
class EvaluationBudget {
  EvaluationBudget._(this._db, this.limit);
  final Database _db;
  final int limit;

  static EvaluationBudget claim(String path, {int limit = 300}) {
    if (limit < 1 || limit > 300) throw const FormatException('Invalid quota');
    // This independent tombstone prevents a missing SQLite file reopening quota.
    File('$path.claim').createSync(exclusive: true);
    final db = sqlite3.open(path);
    try {
      db.execute('PRAGMA synchronous=FULL');
      db.execute('PRAGMA busy_timeout=1000');
      db.execute('''CREATE TABLE evaluation (
        id INTEGER PRIMARY KEY CHECK(id=1), quota INTEGER NOT NULL,
        closed INTEGER NOT NULL DEFAULT 0)''');
      db.execute('INSERT INTO evaluation(id,quota) VALUES(1,?)', [limit]);
      db.execute('''CREATE TABLE attempts (
        id INTEGER PRIMARY KEY, case_id TEXT NOT NULL, attempt INTEGER NOT NULL, turn INTEGER NOT NULL,
        bytes INTEGER NOT NULL, outcome TEXT,
        UNIQUE(case_id,attempt,turn))''');
      return EvaluationBudget._(db, limit);
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  int get used =>
      _db.select('SELECT count(*) AS n FROM attempts').single['n'] as int;

  int reserve(String caseId, int turn, int bytes, {int attempt = 1}) {
    if (!RegExp(r'^S(0[1-9]|1[0-9]|20)$').hasMatch(caseId) ||
        attempt < 1 ||
        attempt > 300 ||
        turn < 1 ||
        turn > 6 ||
        bytes < 0 ||
        bytes >= 64000) {
      throw const FormatException('Invalid attempt metadata');
    }
    _db.execute('BEGIN IMMEDIATE');
    try {
      final state = _db.select('SELECT * FROM evaluation').single;
      if (state['closed'] != 0 || used >= state['quota']) {
        throw StateError('Evaluation quota closed');
      }
      _db.execute(
        'INSERT INTO attempts(case_id,attempt,turn,bytes) VALUES(?,?,?,?)',
        [caseId, attempt, turn, bytes],
      );
      final id = _db.lastInsertRowId;
      _db.execute('COMMIT');
      return id;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void settle(int id, {required bool succeeded}) {
    _db.execute(
      'UPDATE attempts SET outcome=? WHERE id=? AND outcome IS NULL',
      [succeeded ? 'response' : 'failed', id],
    );
    if (_db.updatedRows != 1) throw StateError('Attempt already settled');
  }

  void close() {
    _db.execute('UPDATE evaluation SET closed=1');
    _db.close();
  }
}
