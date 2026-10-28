import 'dart:async';

import '../data/local_publication_outbox.dart';
import '../data/publication_runner.dart';
import 'pairing_controller.dart';
import 'sharing_controller.dart';
import 'chat_controller.dart';

/// Foreground-only scheduling. Queue status writes are observed but are not
/// triggers: only new intent sequences may start another drain.
class CompanionForeground {
  CompanionForeground({
    required this.pairing,
    required this.loadSharing,
    required this.loadRunner,
    required this.groupChanged,
    this.loadChat,
  }) {
    _group = pairing.snapshot?.state?.group?.id;
    pairing.addListener(_pairChanged);
  }

  final PairingController pairing;
  final Future<SharingController> Function() loadSharing;
  final Future<PublicationRunner> Function() loadRunner;
  final void Function() groupChanged;
  final Future<ChatController> Function()? loadChat;
  ChatController? _chat;
  SharingController? _sharing;
  PublicationRunner? _runner;
  StreamSubscription<List<PublicationAttempt>>? _queue;
  String? _group;
  int _generation = 0;
  int _sequence = 0;
  bool _foreground = false;
  bool _disposed = false;
  bool _pending = false;
  bool _refresh = false;
  Future<void>? _working;

  Future<void> get idle async {
    while (_working != null) {
      await _working;
    }
  }

  void setForeground(bool value) {
    if (_disposed || value == _foreground) return;
    _foreground = value;
    _chat?.setForeground(value);
    if (value) {
      _request(refresh: true);
    } else {
      _runner?.cancelWaiting();
      _sharing?.cancelWaiting();
      pairing.cancelWaiting();
    }
  }

  void _pairChanged() {
    final group = pairing.snapshot?.state?.group?.id;
    if (_disposed || group == _group) return;
    _group = group;
    _generation++;
    _detachSession();
    groupChanged();
    _request(refresh: true);
  }

  void _detachSession() {
    unawaited(_queue?.cancel());
    _queue = null;
    _runner?.cancelWaiting();
    _runner = null;
    _sharing = null;
    _chat?.setForeground(false);
    _chat = null;
    _sequence = 0;
  }

  void _request({bool refresh = false}) {
    if (_disposed) return;
    _pending = true;
    _refresh |= refresh;
    _schedule();
  }

  void _schedule() {
    if (_disposed || !_foreground || _working != null) return;
    _working = _drain().whenComplete(() {
      _working = null;
      if (_pending && _foreground && !_disposed) _schedule();
    });
  }

  bool _current(int generation) =>
      !_disposed && _foreground && generation == _generation;

  Future<void> _drain() async {
    while (_pending && _foreground && !_disposed) {
      final refresh = _refresh;
      _pending = false;
      _refresh = false;
      final generation = _generation;
      try {
        if (refresh) await pairing.refresh();
        if (!_current(generation) || _group == null) continue;
        if (_sharing?.available == false || _runner?.available == false) {
          _detachSession();
        }
        final sharing = _sharing ?? await loadSharing();
        if (!_current(generation) || !sharing.available) continue;
        _sharing = sharing;
        if (refresh) await sharing.refresh();
        if (!_current(generation) || !sharing.available) continue;
        final runner = _runner ?? await loadRunner();
        if (!_current(generation) || !runner.available) continue;
        _runner = runner;
        if (_queue == null) {
          _sequence = runner.pending.isEmpty
              ? 0
              : runner.pending.last.row.sequence;
          _queue = runner.outbox.watchPending().listen(
            (rows) {
              if (_disposed ||
                  generation != _generation ||
                  !identical(runner, _runner)) {
                return;
              }
              final latest = rows.isEmpty ? _sequence : rows.last.row.sequence;
              if (latest > _sequence) {
                _sequence = latest;
                _request();
              }
            },
            onError: (Object _) {
              // Scope invalidation is handled by the owned controllers. Do not
              // turn a failed local read into a self-repeating network request.
            },
          );
        }
        final before = await runner.outbox.sharing.currentState();
        if (!_current(generation)) continue;
        await runner.run();
        if (!_current(generation) || !sharing.available) continue;
        final after = await runner.outbox.sharing.currentState();
        if (after.cacheRevision != before.cacheRevision) {
          await sharing.refresh();
        }
      } catch (_) {
        // The optional companion service must not block personal tracking.
        // Explicit page actions and the next resume can retry their reads.
      } finally {
        // Sharing failures must not disable an independent private conversation.
        if (refresh && _current(generation) && _group != null) {
          await _refreshChat(generation);
        }
      }
    }
  }

  Future<void> _refreshChat(int generation) async {
    final load = loadChat;
    if (load == null) return;
    try {
      if (_chat?.available == false) _chat = null;
      final chat = _chat ?? await load();
      if (!_current(generation) || !chat.available) {
        chat.setForeground(false);
        return;
      }
      _chat = chat;
      chat.setForeground(true);
      await chat.runPending();
    } catch (_) {
      // Local tracking remains available when optional chat cannot be loaded.
    }
  }

  void dispose() {
    if (_disposed) return;
    setForeground(false);
    _disposed = true;
    pairing.removeListener(_pairChanged);
    unawaited(_queue?.cancel());
  }
}
