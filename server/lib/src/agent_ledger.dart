import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'agent_protocol.dart';

class AgentLedger {
  AgentLedger._(this._db, this._now, int Function()? elapsedMilliseconds) {
    final watch = Stopwatch()..start();
    _elapsed = elapsedMilliseconds ?? (() => watch.elapsedMilliseconds);
  }

  factory AgentLedger.open(
    String path, {
    DateTime Function()? now,
    int Function()? elapsedMilliseconds,
  }) {
    if (!File(path).isAbsolute ||
        !File(path).parent.existsSync() ||
        FileSystemEntity.typeSync(path, followLinks: false) ==
            FileSystemEntityType.link) {
      throw const FormatException('Agent ledger path');
    }
    final db = sqlite3.open(path);
    try {
      if (db.userVersion > 1 ||
          (db.userVersion == 1 &&
              db.select('PRAGMA application_id').single.values.single !=
                  1481064775) ||
          (db.userVersion == 0 &&
              db
                  .select("SELECT name FROM sqlite_schema WHERE type='table'")
                  .isNotEmpty)) {
        throw const FormatException('Unexpected agent ledger');
      }
      db.execute('PRAGMA busy_timeout=5000');
      db.execute('PRAGMA synchronous=FULL');
      db.execute('BEGIN IMMEDIATE');
      try {
        if (db.userVersion == 0) {
          db.execute(_schema);
          db.execute('PRAGMA application_id=1481064775');
          db.userVersion = 1;
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
      db.execute('PRAGMA secure_delete=ON');
      return AgentLedger._(db, now ?? DateTime.now, elapsedMilliseconds);
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  final Database _db;
  final DateTime Function() _now;
  late final int Function() _elapsed;
  final Map<String, _Run> _runs = {};
  bool _closed = false;

  T _transaction<T>(T Function() action) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final value = action();
      _db.execute('COMMIT');
      return value;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  AgentReservation reserve(String device, AgentRequest request, int bytes) {
    if (_closed) throw const AgentFailure(503, 'agent_unavailable');
    if (bytes >= agentBodyLimit) {
      throw const AgentFailure(413, 'model_request_too_large');
    }
    final now = _now().toUtc();
    final day = now.toIso8601String().substring(0, 10);
    final deviceHash = agentDigest(device);
    final requestHash = agentDigest(request.requestId);
    final elapsed = _elapsed();
    _runs.removeWhere(
      (_, run) => elapsed - run.start >= 600000 && !run.pending,
    );
    final newRun = request.runId == null;
    final run = newRun
        ? _Run(
            const Uuid().v4(),
            deviceHash,
            requestHash,
            elapsed,
            agentDigest(request.now.toJson()),
          )
        : _runs[request.runId];
    if (run == null || run.device != deviceHash || run.request != requestHash) {
      throw const AgentFailure(409, 'run_restart_required');
    }
    if (run.pending) throw const AgentFailure(409, 'run_busy');
    if (run.stopped) throw const AgentFailure(409, 'run_stopped');
    if (elapsed - run.start >= 60000) {
      _stop(run);
      throw const AgentFailure(409, 'run_deadline');
    }
    if (request.turn != run.calls + 1) {
      throw const AgentFailure(409, 'turn_replayed');
    }
    if (run.calls >= agentCallLimit) {
      _stop(run);
      throw const AgentFailure(429, 'run_call_limit');
    }
    if (agentDigest(request.now.toJson()) != run.clock) {
      throw const AgentFailure(400, 'history_mismatch');
    }
    if (!newRun) _history(run, request);
    final reservation = (bytes + 1) ~/ 2 + agentOutputLimit;
    if (run.tokens + reservation > agentTokenLimit) {
      if (!newRun) _stop(run);
      throw const AgentFailure(429, 'run_token_limit');
    }
    _transaction(() {
      final cutoff = now
          .subtract(const Duration(days: 2))
          .toIso8601String()
          .substring(0, 10);
      _db.execute('DELETE FROM agent_runs WHERE expires_at<=?', [
        now.millisecondsSinceEpoch,
      ]);
      _db.execute('DELETE FROM agent_starts WHERE day<?', [cutoff]);
      _db.execute('DELETE FROM agent_daily WHERE day<?', [cutoff]);
      final daily = _db.select(
        'SELECT runs,tokens FROM agent_daily WHERE device=? AND day=?',
        [deviceHash, day],
      );
      final runs = daily.isEmpty ? 0 : daily.single['runs'] as int;
      final tokens = daily.isEmpty ? 0 : daily.single['tokens'] as int;
      if (newRun &&
          _db.select(
            'SELECT 1 FROM agent_starts WHERE device=? AND request=?',
            [deviceHash, requestHash],
          ).isNotEmpty) {
        throw const AgentFailure(409, 'start_replayed');
      }
      if (newRun && runs >= 40) {
        throw const AgentFailure(429, 'daily_run_limit');
      }
      if (tokens + reservation > 400000) {
        throw const AgentFailure(429, 'daily_token_limit');
      }
      if (newRun) {
        _db.execute('INSERT INTO agent_starts VALUES (?,?,?)', [
          deviceHash,
          requestHash,
          day,
        ]);
        _db.execute('INSERT INTO agent_runs VALUES (?,?,?,?,?,?,?,?)', [
          run.id,
          deviceHash,
          now.millisecondsSinceEpoch + 60000,
          now.millisecondsSinceEpoch + 600000,
          0,
          0,
          0,
          0,
        ]);
      }
      _db.execute(
        '''INSERT INTO agent_daily(device,day,runs,tokens) VALUES (?,?,?,?)
        ON CONFLICT(device,day) DO UPDATE SET runs=runs+excluded.runs,tokens=tokens+excluded.tokens''',
        [deviceHash, day, newRun ? 1 : 0, reservation],
      );
      _db.execute(
        'UPDATE agent_runs SET calls=calls+1,tokens=tokens+?,pending=1 WHERE id=?',
        [reservation, run.id],
      );
    });
    run.calls++;
    run.tokens += reservation;
    run.pending = true;
    _runs[run.id] = run;
    return AgentReservation._(
      run,
      reservation,
      day,
      Duration(milliseconds: max(0, 60000 - (_elapsed() - run.start))),
    );
  }

  void _history(_Run run, AgentRequest request) {
    final prefix = request.messages.take(request.messages.length - 1).toList();
    if (agentDigest(prefix) != run.expectedPrefix) {
      throw const AgentFailure(400, 'history_mismatch');
    }
    final call = request.calls.last;
    final result = request.results.last;
    final fingerprint = call.fingerprint;
    final repeats = run.toolCounts[fingerprint] ?? 0;
    if (repeats == 2) {
      if (result['status'] != 'duplicate' ||
          agentDigest(result['result']) != run.resultHashes[fingerprint]) {
        throw const AgentFailure(400, 'duplicate_result_mismatch');
      }
    } else if (repeats != 1 || result['status'] == 'duplicate') {
      throw const AgentFailure(400, 'unexpected_duplicate');
    }
    final effective = result['status'] == 'duplicate'
        ? result['original_status']
        : result['status'];
    if (call.name == 'submit_plan_draft' && effective != 'invalid') {
      _stop(run);
      throw const AgentFailure(409, 'draft_validation_terminal');
    }
    // Retain only a digest of the first result; the next body carries its data.
    if (repeats == 1) run.resultHashes[fingerprint] = agentDigest(result);
  }

  AgentSettlement finish(
    AgentReservation reservation,
    AgentRequest request,
    AgentModelReply reply,
  ) {
    final run = reservation._run;
    if (_closed || !run.pending || reservation._settled) {
      throw const AgentFailure(503, 'ledger_unavailable');
    }
    final usage = reply.usage;
    final violation =
        !usage.valid ||
        usage.reported > reservation.tokens ||
        (usage.counts['completion_tokens'] ?? 0) > agentOutputLimit;
    final charge = violation
        ? max(reservation.tokens, usage.reported)
        : usage.reported;
    var outcome = reply.outcome;
    if (violation && outcome.kind != 'stopped') {
      outcome = AgentOutcome.stop(
        usage.valid ? 'usage_exceeds_reservation' : 'invalid_usage',
      );
    }
    if (_elapsed() - run.start >= 60000) {
      outcome = const AgentOutcome.stop('run_deadline');
    }
    final call = outcome.call;
    if (call != null) {
      if (run.modelCallIds.contains(call.id)) {
        outcome = const AgentOutcome.stop('reused_model_call_id');
      } else if ((run.toolCounts[call.fingerprint] ?? 0) >= 2) {
        outcome = const AgentOutcome.stop('repeated_tool_call');
      }
    }
    final stopped = outcome.kind != 'tool_call';
    final delta = charge - reservation.tokens;
    _transaction(() {
      _db.execute(
        'UPDATE agent_daily SET tokens=tokens+? WHERE device=? AND day=?',
        [delta, run.device, reservation.day],
      );
      _db.execute(
        'UPDATE agent_runs SET tokens=tokens+?,pending=0,stopped=? WHERE id=?',
        [delta, stopped ? 1 : 0, run.id],
      );
    });
    reservation._settled = true;
    run.tokens += delta;
    run.pending = false;
    run.stopped = stopped;
    if (!stopped) {
      final rawCall = outcome.call!;
      run.modelCallIds.add(rawCall.id);
      run.toolCounts.update(
        rawCall.fingerprint,
        (n) => n + 1,
        ifAbsent: () => 1,
      );
      final scoped = rawCall.scoped(run.id, run.calls);
      outcome = AgentOutcome.tool(scoped);
      run.expectedPrefix = agentDigest([...request.messages, scoped.message]);
    }
    return AgentSettlement(
      outcome,
      run.calls,
      run.tokens,
      violation,
      max(0, 60000 - (_elapsed() - run.start)),
    );
  }

  void _stop(_Run run) {
    _db.execute('UPDATE agent_runs SET stopped=1 WHERE id=?', [run.id]);
    run.stopped = true;
  }

  Map<String, int> dailyUsage(String device, DateTime day) {
    final rows = _db.select(
      'SELECT runs,tokens FROM agent_daily WHERE device=? AND day=?',
      [agentDigest(device), day.toUtc().toIso8601String().substring(0, 10)],
    );
    return rows.isEmpty
        ? {'runs': 0, 'tokens': 0}
        : {
            'runs': rows.single['runs'] as int,
            'tokens': rows.single['tokens'] as int,
          };
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _runs.clear();
    _db.close();
  }
}

class _Run {
  _Run(this.id, this.device, this.request, this.start, this.clock);
  final String id, device, request, clock;
  final int start;
  int calls = 0;
  int tokens = 0;
  bool pending = false;
  bool stopped = false;
  String? expectedPrefix;
  final Set<String> modelCallIds = {};
  final Map<String, int> toolCounts = {};
  final Map<String, String> resultHashes = {};
}

class AgentReservation {
  AgentReservation._(this._run, this.tokens, this.day, this.remaining);
  final _Run _run;
  final int tokens;
  final String day;
  final Duration remaining;
  bool _settled = false;
  String get runId => _run.id;
}

class AgentSettlement {
  AgentSettlement(
    this.outcome,
    this.calls,
    this.tokens,
    this.violation,
    this.remainingMs,
  );
  final AgentOutcome outcome;
  final int calls, tokens, remainingMs;
  final bool violation;
}

const _schema = '''
CREATE TABLE agent_daily (
  device TEXT NOT NULL, day TEXT NOT NULL,
  runs INTEGER NOT NULL CHECK(runs BETWEEN 0 AND 40),
  tokens INTEGER NOT NULL CHECK(tokens>=0), PRIMARY KEY(device,day)
);
CREATE TABLE agent_starts (
  device TEXT NOT NULL, request TEXT NOT NULL, day TEXT NOT NULL,
  PRIMARY KEY(device,request)
);
CREATE TABLE agent_runs (
  id TEXT PRIMARY KEY, device TEXT NOT NULL, deadline INTEGER NOT NULL,
  expires_at INTEGER NOT NULL, calls INTEGER NOT NULL CHECK(calls BETWEEN 0 AND 6),
  tokens INTEGER NOT NULL CHECK(tokens>=0), pending INTEGER NOT NULL,
  stopped INTEGER NOT NULL
);
''';
