import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_identity_boundary.dart';
import 'package:habit_checkin/shared/local_identity_boundary.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'chat_diary_initial_read_recovery_test.dart' show readState;
import 'support/sync_fixtures.dart' show accountA;
import 'support/test_clock.dart';

class _BoundaryHarness {
  _BoundaryHarness(this.store);

  Future<LocalConversationStore> store;
  String label = 'Synthetic private child';
  int generation = 0;
  int childBuilds = 0;
  VoidCallback? onReopen;
  late StateSetter _setState;

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) {
          _setState = setState;
          return AssistantIdentityBoundary(
            key: ValueKey(generation),
            store: store,
            onReopen: onReopen,
            child: Builder(
              builder: (_) {
                childBuilds++;
                return Text(label);
              },
            ),
          );
        },
      ),
    ),
  );

  void refresh() => _setState(() {});

  Future<void> rebuild(WidgetTester tester) async {
    refresh();
    await tester.pump();
  }

  Future<LocalGoalRepository> mapped(WidgetTester tester) => tester
      .widget<LocalIdentityBoundary>(find.byType(LocalIdentityBoundary))
      .repository;
}

Future<LocalConversationStore> _store(AppDatabase db) async {
  final lease = await IdentityStore(db).active();
  return LocalConversationStore(
    LocalGoalRepository(
      db,
      TestClock(),
      owner: lease.identity.owner,
      identityLease: lease,
    ),
  );
}

void _expectUnavailable(WidgetTester tester, _BoundaryHarness app) {
  expect(find.text('身份已变化或不可用。'), findsOneWidget);
  expect(find.text(app.label), findsNothing);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('R8 pending and failed rebuilds retain one mapped future', (
    tester,
  ) async {
    final pending = Completer<LocalConversationStore>();
    final app = _BoundaryHarness(pending.future);
    await app.mount(tester);
    final mapped = app.mapped(tester);
    for (var i = 0; i < 4; i++) {
      await app.rebuild(tester);
      expect(app.mapped(tester), same(mapped));
      expect(find.text('正在核对当前身份'), findsOneWidget);
      expect(app.childBuilds, 0);
    }
    pending.completeError(StateError('R8 synthetic initialization failure'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      await app.rebuild(tester);
      await tester.pumpAndSettle();
      expect(app.mapped(tester), same(mapped));
      expect(app.childBuilds, 0);
      _expectUnavailable(tester, app);
    }
  });

  for (final failure in [false, true]) {
    testWidgets('R8 disposed pending ${failure ? 'failure' : 'success'}', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = await _store(db);
      final before = await readState(db);
      final pending = Completer<LocalConversationStore>();
      final app = _BoundaryHarness(pending.future);
      await app.mount(tester);
      await app.rebuild(tester);
      expect(app.childBuilds, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      if (failure) {
        pending.completeError(StateError('R8 failure after disposal'));
      } else {
        pending.complete(store);
      }
      await tester.pumpAndSettle();
      expect(app.childBuilds, 0);
      expect(find.byType(AssistantIdentityBoundary), findsNothing);
      expect(await readState(db), before);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('R8 successful rebuild updates child but not route lease', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = await _store(db);
    final before = await readState(db);
    final app = _BoundaryHarness(Future.value(store));
    await app.mount(tester);
    await tester.pumpAndSettle();
    final mapped = app.mapped(tester);
    for (var i = 0; i < 6; i++) {
      // Sessions supplies a fresh Future.value on every parent rebuild.
      app.store = Future.value(store);
      app.label = 'Synthetic private child $i';
      await app.rebuild(tester);
      await tester.pumpAndSettle();
      expect(app.mapped(tester), same(mapped));
      expect(find.text(app.label), findsOneWidget);
      expect(await readState(db), before);
    }

    final identities = IdentityStore(db);
    await identities.finish(await identities.begin(accountA));
    app.store = Future.value(await _store(db));
    final away = await readState(db);
    await app.rebuild(tester);
    await tester.pumpAndSettle();
    _expectUnavailable(tester, app);
    expect(app.mapped(tester), same(mapped));
    expect(await readState(db), away);

    await identities.finish(await identities.begin(SyncIdentity.guest));
    app.store = Future.value(await _store(db));
    final back = await readState(db);
    await app.rebuild(tester);
    await tester.pumpAndSettle();
    _expectUnavailable(tester, app);
    expect(app.mapped(tester), same(mapped));
    expect(await readState(db), back);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  });

  testWidgets('R8 pending identity switch blocks late initial success', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final original = await _store(db);
    final pending = Completer<LocalConversationStore>();
    final app = _BoundaryHarness(pending.future);
    await app.mount(tester);
    final transition = await IdentityStore(db).begin(accountA);
    final during = await readState(db);
    await app.rebuild(tester);
    pending.complete(original);
    await tester.pumpAndSettle();
    _expectUnavailable(tester, app);
    expect(app.childBuilds, 0);
    expect(await readState(db), during);

    await IdentityStore(db).finish(transition);
    final after = await readState(db);
    app.store = Future.value(await _store(db));
    await app.rebuild(tester);
    await tester.pumpAndSettle();
    _expectUnavailable(tester, app);
    expect(app.childBuilds, 0);
    expect(await readState(db), after);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  });

  testWidgets('R8 failed lease requires explicit reopen with a new boundary', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final healthy = await _store(db);
    final before = await readState(db);
    final pending = Completer<LocalConversationStore>();
    final app = _BoundaryHarness(pending.future);
    var staleReopenCalls = 0;
    var currentReopenCalls = 0;
    app.onReopen = () => staleReopenCalls++;
    await app.mount(tester);
    final mapped = app.mapped(tester);
    pending.completeError(StateError('R8 synthetic unavailable lease'));
    await tester.pumpAndSettle();
    app.store = Future.value(healthy);
    app.onReopen = () {
      currentReopenCalls++;
      app.generation++;
      app.refresh();
    };
    await app.rebuild(tester);
    await tester.pumpAndSettle();
    _expectUnavailable(tester, app);
    expect(app.mapped(tester), same(mapped));
    expect(app.childBuilds, 0);
    expect(await readState(db), before);
    await tester.tap(find.widgetWithText(OutlinedButton, '重新打开'));
    await tester.pumpAndSettle();
    expect(staleReopenCalls, 0);
    expect(currentReopenCalls, 1);
    expect(app.mapped(tester), isNot(same(mapped)));
    expect(find.text(app.label), findsOneWidget);
    expect(await readState(db), before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  });
}
