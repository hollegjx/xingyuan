import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/local/app_database.dart';
import '../../../data/sync/identity_store.dart';
import '../../goals/domain/goal.dart';
import '../../journal/data/chat_diary_store.dart';
import '../data/assistant_conversation_runner.dart';
import '../data/assistant_service.dart';
import '../data/assistant_record_tools.dart';
import '../data/local_conversation_store.dart';
import '../domain/agent_run_metadata.dart';

String assistantErrorMessage(Object error) => switch (error) {
  AssistantFailure() => error.message,
  GoalRuleException() => error.message,
  StaleIdentity() => '身份已变化，请重新打开规划；原有记录未被清空。',
  _ => '操作未完成，未创建任何内容。原有记录仍保留，请重试。',
};

class AssistantConversationController extends ChangeNotifier {
  AssistantConversationController({required this.store, required this.service});

  final LocalConversationStore store;
  final AssistantService service;
  List<StoredAssistantSession> sessions = const [];
  StoredAssistantSession? session;
  List<StoredAssistantMessage> messages = const [];
  List<StoredPlanProposal> proposals = const [];
  List<StoredDiaryProposal> diaryProposals = const [];
  Map<String, List<StoredMemoryEvent>> events = const {};
  final Map<String, String> failures = {};
  final Map<String, PendingAssistantTurn> _failedTurns = {};
  String? error;
  AssistantRunStage? stage;
  AgentRunMetadata? agentProgress;
  bool busy = false;
  bool identityChanged = false;
  bool _foreground = true;
  bool _disposed = false;
  int _operation = 0;
  int _read = 0;
  String? _selected;
  PendingAssistantTurn? _turn;
  StreamSubscription<StoredIdentityState>? _identitySubscription;
  StreamSubscription<List<StoredAssistantSettings>>? _settingsSubscription;

  void setAgentForeground(bool foreground) {
    _foreground = foreground;
    if (!foreground &&
        service is AgentService &&
        (_turn?.settings.agentEnabled ?? true)) {
      cancel().ignore();
    }
  }

  Future<void> initialize() async {
    final lease = await IdentityStore(store.db).active();
    await store.recoverInterrupted();
    if (_disposed) return;
    _identitySubscription = store.db
        .select(store.db.identityStates)
        .watchSingle()
        .listen((state) {
          if (state.owner != lease.identity.owner ||
              state.generation != lease.generation ||
              state.targetOwner != null) {
            _hideStaleIdentity();
          }
        }, onError: (Object _) => _hideStaleIdentity());
    _settingsSubscription =
        (store.db.select(
          store.db.assistantSettings,
        )..where((row) => row.owner.equals(store.owner))).watch().listen((
          rows,
        ) {
          final turn = _turn;
          if (turn != null &&
              (rows.length != 1 || rows.single != turn.settings)) {
            cancel(configurationChanged: true).ignore();
          }
        }, onError: (Object _) => cancel(configurationChanged: true).ignore());
    await refresh();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _hideStaleIdentity() {
    if (_disposed || identityChanged) return;
    _operation++;
    _read++;
    _turn?.cancellation.cancel();
    _turn = null;
    busy = false;
    stage = null;
    identityChanged = true;
    agentProgress = null;
    sessions = const [];
    session = null;
    messages = const [];
    proposals = const [];
    diaryProposals = const [];
    events = const {};
    failures.clear();
    _failedTurns.clear();
    error = assistantErrorMessage(const StaleIdentity());
    _notify();
  }

  Future<void> refresh() async {
    if (_disposed || identityChanged) return;
    final operation = _operation;
    final read = ++_read;
    bool current() =>
        !_disposed &&
        !identityChanged &&
        operation == _operation &&
        read == _read;
    try {
      final result = await store.db.transaction(() async {
        final sessions = await store.sessions();
        final selected =
            sessions.where((row) => row.id == _selected).firstOrNull ??
            sessions.firstOrNull;
        final messages = selected == null
            ? <StoredAssistantMessage>[]
            : await store.messages(selected.id);
        final proposals = selected == null
            ? <StoredPlanProposal>[]
            : await store.sessionProposals(selected.id);
        final events = <String, List<StoredMemoryEvent>>{};
        for (final message in messages.where(
          (row) => row.role == 'assistant',
        )) {
          events[message.id] = await store.memories.events(message.id);
        }
        final diaries = selected == null
            ? <StoredDiaryProposal>[]
            : await ChatDiaryStore(store.goals).forSession(selected.id);
        return (sessions, selected, messages, proposals, events, diaries);
      });
      if (!current()) return;
      sessions = List.unmodifiable(result.$1);
      session = result.$2;
      _selected = session?.id;
      messages = List.unmodifiable(result.$3);
      proposals = List.unmodifiable(result.$4);
      events = Map.unmodifiable(result.$5);
      diaryProposals = List.unmodifiable(result.$6);
      _notify();
    } on StaleIdentity {
      if (current()) _hideStaleIdentity();
    } catch (failure) {
      if (current()) {
        error = assistantErrorMessage(failure);
        _notify();
      }
    }
  }

  Future<void> _change(Future<void> Function() action) async {
    if (_disposed || identityChanged) return;
    try {
      await action();
      error = null;
      await refresh();
    } catch (failure) {
      if (failure is StaleIdentity) {
        _hideStaleIdentity();
      } else {
        error = assistantErrorMessage(failure);
        _notify();
      }
    }
  }

  String? get memorySummary => session?.summary;

  Future<void> openContinuous() async {
    await cancel();
    await _change(() async => _selected = await store.openContinuous());
  }

  Future<void> clearMemorySummary() async {
    await cancel();
    final id = _selected;
    if (id != null) await _change(() => store.clearMemorySummary(id));
  }

  Future<void> create() async {
    await cancel();
    await _change(() async => _selected = await store.createSession());
  }

  Future<void> select(String id) async {
    if (id == _selected) return;
    await cancel();
    await _change(() async {
      await store.session(id);
      _selected = id;
    });
  }

  Future<void> rename(String id, String title) =>
      _change(() => store.renameSession(id, title));

  Future<void> delete(String id) async {
    if (id == _selected) await cancel();
    await _change(() => store.deleteSession(id));
  }

  Future<void> undoMemory(String id) => _change(() => store.memories.undo(id));

  Future<void> send(
    String text, {
    String? retryMessageId,
    ValueChanged<String>? onAccepted,
    ConfirmAssistantRead? confirmRead,
    AssistantRecordScope? recordScope,
  }) async {
    if (_disposed ||
        identityChanged ||
        busy ||
        (!_foreground && service is AgentService)) {
      return;
    }
    final operation = ++_operation;
    busy = true;
    agentProgress = null;
    error = null;
    stage = null;
    _notify();
    PendingAssistantTurn? turn;
    var ended = false;
    bool current() => !_disposed && operation == _operation && !ended;
    Future<void> perform() async {
      if (!service.configured) {
        throw const AssistantFailure(AssistantFailureKind.unconfigured);
      }
      final id = _selected ?? await store.createSession();
      if (!current()) return;
      _selected = id;
      if (_failedTurns[retryMessageId] case final failed?) {
        // Retry first resolves this exact local pending row, never a new run.
        await store.fail(failed);
        if (!current()) return;
      }
      final pending = await store.begin(
        id,
        text,
        retryMessageId: retryMessageId,
      );
      turn = pending;
      if (!current()) {
        pending.cancellation.cancel();
        if (!_disposed) await store.cancel(pending);
        return;
      }
      _turn = pending;
      _failedTurns.remove(retryMessageId);
      onAccepted?.call(id);
      await refresh();
      if (!current()) return;
      await AssistantConversationRunner(store: store, service: service).run(
        pending,
        confirmRead: confirmRead,
        recordScope: recordScope,
        onStage: (value) {
          if (current()) {
            stage = value;
            _notify();
          }
        },
        onProgress: (value) {
          if (current()) {
            agentProgress = value;
            _notify();
          }
        },
      );
    }

    try {
      await perform().timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          if (turn case final pending?) {
            pending.cancellation.cancel();
            store.fail(pending).ignore();
          }
          throw const AssistantFailure(AssistantFailureKind.timeout);
        },
      );
    } catch (failure) {
      if (!_disposed && operation == _operation) {
        error = assistantErrorMessage(failure);
        if (turn case final pending?) {
          failures[pending.messageId] = error!;
          _failedTurns[pending.messageId] = pending;
        }
      }
    } finally {
      ended = true;
      if (!_disposed && operation == _operation) {
        busy = false;
        stage = null;
        _turn = null;
        // Publish terminal state even while SQLite cannot finish a refresh.
        _notify();
        await refresh().timeout(const Duration(seconds: 5), onTimeout: () {});
      }
    }
  }

  Future<void> cancel({bool configurationChanged = false}) async {
    if (!busy || _disposed) return;
    final operation = ++_operation;
    bool current() => !_disposed && !identityChanged && operation == _operation;
    final turn = _turn;
    _turn = null;
    turn?.cancellation.cancel();
    busy = false;
    stage = null;
    error = AssistantFailure(
      configurationChanged
          ? AssistantFailureKind.discarded
          : AssistantFailureKind.cancelled,
    ).message;
    if (turn != null) {
      failures[turn.messageId] = error!;
      _failedTurns[turn.messageId] = turn;
    }
    _notify();
    try {
      if (turn != null) await store.cancel(turn);
      if (!current()) return;
      await refresh();
    } catch (failure) {
      if (!current()) return;
      error = assistantErrorMessage(failure);
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _operation++;
    _turn?.cancellation.cancel();
    _identitySubscription?.cancel().ignore();
    _settingsSubscription?.cancel().ignore();
    super.dispose();
  }
}
